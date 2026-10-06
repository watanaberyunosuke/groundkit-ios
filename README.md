# Ramp Ops (iOS)

An iPhone and iPad app for apron, ramp and cargo staff at the airports covered by [motherduck-aviation-data-analysis](../motherduck-aviation-data-analysis): Sydney, Melbourne, Brisbane, Singapore, Hong Kong, Amsterdam and Anchorage. It uses the same backend as the web dashboard, the Vercel API over the MotherDuck warehouse, with a front end built for working outside: large type, 60 pt buttons for gloved hands, and status shown by symbol and words as well as colour.

SwiftUI, SwiftData with CloudKit sync, HealthKit and Swift Charts. iOS 18 or later.

## What it does

| Tab | For |
|---|---|
| **Now** | A compact ramp status banner (Normal ops / Caution / Warning; tap for details, warnings open expanded) from the latest METAR, TAF and NOTAMs: thunderstorms and lightning risk, wind and gust limits, ice and snow, heat stress (heat index), wind chill, low visibility, stale weather, runway closures and apron or taxiway NOTAMs. Then the airspace map, wind, temperature (feels like), weather in plain words, visibility, the next arrivals and departures, 24 hours of wind and gusts, NOTAMs in force (apron and taxiway first) and the raw METAR and TAF. Local and UTC clocks. |
| **Map** | From the Now screen. Live aircraft within 500 NM, pointing along their track and coloured by delay status like the boards, parked aircraft, observed arrival and departure paths of the last 3 days, the 50 NM terminal area and the wind. Zoom to the airport (satellite imagery, flight numbers on parked aircraft), 50 NM or 500 NM; tap an aircraft for its details. |
| **Arrivals** | Inbound now (live positions within 500 NM with ETA, minutes to landing and distance), on the ground, expected in the next 6 hours, and the last 3 hours. |
| **Departures** | On the ground (late once past the flight's usual time), just departed, expected, and the last 3 hours. |
| **Turnarounds** | A checklist per flight: chocks, cones, GPU, holds, bags and cargo off, fuelling, catering, cleaning, water, bags and cargo loaded, NOTOC (with dangerous goods), loadsheet, holds closed, GPU off, chocks off, pushback. One tap stamps the time. Bag and ULD counters, stand, registration, notes, and a countdown to the target off-block time. Start one from any flight on a board. |
| **Shift** | Time on shift, water logged against a target that rises with the heat, and from Health: steps, distance, active energy, heart rate and (with an Apple Watch) average and peak noise, with a hearing-protection warning at 85 dB. Handover notes for the next crew. |

Settings: airport, glove mode (larger text and controls), keep screen on (for a tablet in a tug or the ops room), wind limits to match the airline's door, stairs, high-loader and jet bridge limits, and the API address.

The app is advisory only. Ramp closures, lightning alerts and wind limits are the airport's and airline's call.

## Backend

The app reads two endpoints of the aviation project's Vercel API (`api/index.py`):

- `GET /api/snapshot/<icao>`: the airport list, current conditions, 24 hours of hourly weather, NOTAMs in force, median terminal times and the 30-day callsign history, as JSON (about 20 KB gzipped). Added for this app; the web dashboard reads Parquet instead. **Deploy the aviation repo before using the production URL.**
- `GET /api/tracks/<icao>`: observed arrival and departure paths of the last 3 days, for the map. Also added for this app.
- `GET /api/live/<icao>`: aircraft within 500 NM from OpenSky or adsb.lol, edge-cached for 2 minutes. Each aircraft's `dir` (inbound, outbound, ground or other) is the server's answer for that fix; the app keeps an airborne aircraft's earlier direction until it lands (`DirectionMemory`), so an arrival on downwind or in a hold stays inbound.

There is no live timetable. As in the Dive, the boards come from each callsign's usual time at the airport over the last 30 days, and the delay is the estimated arrival (or take-off) against that usual time: green under 15 minutes late, amber 15 to 44, red 45 or more. `RampOps/Logic/BoardBuilder.swift` is a line-for-line port of the Dive's logic, so the app and the dashboard agree.

The app refreshes every 2 minutes while open (the live feed's cache time), fetches the snapshot at most every 5 minutes, and keeps the last snapshot on disk so it opens with data in a dead spot.

## Records and sync (CloudKit)

Turnarounds, shifts and handover notes are SwiftData models (`RampOps/Models/RampRecords.swift`) stored with `cloudKitDatabase: .automatic`, so they sync through the iCloud private database to every device signed in to the same Apple Account. Without the entitlement or an iCloud account they stay on the device. The models follow CloudKit's rules: defaults on every attribute, no unique constraints, optional relationships with inverses.

The private database is per Apple Account, so it suits one person's devices or a shared crew iPad. Sharing between colleagues' own phones would need `CKShare` or the public database (see Next steps).

## Setup

1. Open `RampOps.xcodeproj` in Xcode 26 or later.
2. In Signing & Capabilities for the RampOps target, choose your team. Change the bundle identifier (`io.github.watanaberyunosuke.RampOps`) if it is taken, and the iCloud container (`iCloud.io.github.watanaberyunosuke.RampOps` in `Config/RampOps.entitlements`) to match.
3. Check the iCloud (CloudKit) and HealthKit capabilities are on. Xcode creates the container on first run. Before a release, deploy the CloudKit schema to production in the CloudKit Console.
4. Run on a device or simulator. Health data is richer on a device paired with an Apple Watch.

To run against a local API instead of production (from the aviation repo, with its local warehouse):

```bash
WAREHOUSE=data/aviation.duckdb uvicorn api.index:app --port 8000
```

then set the API address in Settings to `http://localhost:8000`, or launch with `-apiBaseURL http://localhost:8000`. `NSAllowsLocalNetworking` permits plain HTTP to local addresses only.

## Tests

```bash
xcodebuild test -scheme RampOps -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

Swift Testing covers the board logic (placement, ETA, delay, on-stand lateness, predicted flights, landings remembered across fixes, coverage gaps), the ramp advisories (thunderstorms, storm clouds, TAF validity, wind limits, heat index, wind chill, ice, low visibility, stale weather, NOTAM relevance), METAR wording, and decoding the API's JSON.

## Layout

```
RampOps/
  App/          entry point, tabs, cross-tab navigation
  Models/       API types (Snapshot.swift), SwiftData records (RampRecords.swift)
  Services/     API client and on-disk cache, AirportStore (refresh, boards), HealthService
  Logic/        BoardBuilder (from the Dive), RampAdvisor, WeatherText, Geo and local time
  Design/       shared components: cards, tiles, status pills, big buttons, clocks
  Features/     Now, Map, Boards, Turnarounds, Shift, Settings
RampOpsTests/   Swift Testing
Config/         Info.plist additions and entitlements
```

## Next steps

1. Crew sharing: share a turnaround or the handover notes with colleagues via `CKShare` (SwiftData does not share yet, so this needs Core Data with `NSPersistentCloudKitContainer`, or the public database).
2. Widgets and a Live Activity for the next arrival and the ramp status on the Lock Screen and Dynamic Island.
3. Notifications when the ramp status rises to Caution or Warning (a server push, since the app only refreshes while open).
4. A watchOS companion for steps on the wrist: the turnaround checklist and water logging.
