# GroundKit (iOS)

An iPhone and iPad app for apron, ramp and cargo staff at the airports covered by [groundkit-dashboard](https://github.com/watanaberyunosuke/groundkit-dashboard): Sydney, Melbourne, Brisbane, Singapore, Hong Kong, Amsterdam and Anchorage. It uses the same backend as the web dashboard, the Vercel API over the MotherDuck warehouse, with a front end built for working outside: large type, 60 pt buttons for gloved hands, and status shown by symbol and words as well as colour.

SwiftUI, SwiftData with CloudKit sync, HealthKit and Swift Charts. iOS 18 or later.

## What it does

| Tab | For |
|---|---|
| **Now** | A compact ramp status banner (Normal ops / Caution / Warning; tap for details, warnings open expanded) from the latest METAR, TAF and NOTAMs: thunderstorms and lightning risk, wind and gust limits, ice and snow, heat stress (heat index), wind chill, low visibility, stale weather, runway closures and apron or taxiway NOTAMs. Then the airspace map (tap to enlarge), wind, temperature (feels like), weather in plain words, visibility, the next arrivals and departures (*All arrivals* or *All departures* enlarges the board), 24 hours of wind and gusts, NOTAMs in force (apron and taxiway first) and the raw METAR and TAF. Local and UTC clocks. |
| **Map** | The map button in every tab's toolbar, or the map on Now. *Airport*: the layout from OpenStreetMap (runways, taxiways with their letters, stands, gates, holding points, aprons, terminals, cargo buildings, service roads), your position, search for a gate, stand, taxiway or building, and a route there by road. *Airspace*: live aircraft within 500 NM, pointing along their track and coloured by delay status like the boards, parked aircraft, observed arrival and departure paths of the last 3 days, the 50 NM terminal area, the wind and your position. Zoom close-in (satellite imagery, flight numbers on parked aircraft), 50 NM or 500 NM; tap an aircraft for its details. |
| **Flights** | *Arrivals*: inbound now (live positions within 500 NM with ETA, minutes to landing and distance), on the ground, expected in the next 6 hours, and the last 3 hours. *Departures*: on the ground (late once past the flight's usual time), just departed, expected, and the last 3 hours. The tab's badge counts arrivals in the air. |
| **Turnarounds** | A checklist per flight: chocks, cones, GPU, holds, bags and cargo off, fuelling, catering, cleaning, water, bags and cargo loaded, NOTOC (with dangerous goods), loadsheet, holds closed, GPU off, chocks off, pushback. One tap stamps the time, tap again to undo. Bag and ULD counters, stand, registration, notes, and a countdown to the target off-block time, entered as airport local time (tomorrow when that is more than 12 h ago). Start one from any flight, or add one; delete one by swiping it away or from its screen. |
| **Shift** | Time on shift and since the last logged break, water logged against a target that rises with the heat, fatigue (sleep before the shift, rest, hours this week), heat-strain warnings from heart rate, and from Health: steps, distance, active energy, heart rate and (with an Apple Watch) average and peak noise, with a hearing-protection warning at 85 dB. A summary when the shift ends. Handover notes for the next crew. |

Settings: airport, glove mode (larger text and controls), keep screen on (for a tablet in a tug or the ops room), appearance, age (for the heat-strain limit), wind limits to match the airline's door, stairs, high-loader and jet bridge limits, and the API address.

Appearance: *Auto* (the default) follows the phone. *Sunset* is dark from sunset to sunrise at the selected airport, whatever the phone is set to, so a night shift goes dark on its own; sun times use the Astronomical Almanac's low-precision formulae (`Logic/Solar.swift`, within a minute or two). *Light* and *Dark* are fixed.

The app is advisory only. Ramp closures, lightning alerts and wind limits are the airport's and airline's call.

## Backend

The app reads two endpoints of the aviation project's Vercel API (`api/index.py`):

- `GET /api/snapshot/<icao>`: the airport list, current conditions, 24 hours of hourly weather, NOTAMs in force, median terminal times and the 30-day callsign history, as JSON (about 20 KB gzipped). Added for this app; the web dashboard reads Parquet instead. **Deploy the aviation repo before using the production URL.**
- `GET /api/tracks/<icao>`: observed arrival and departure paths of the last 3 days, for the map. Also added for this app.
- `GET /api/live/<icao>`: aircraft within 500 NM from OpenSky or adsb.lol, edge-cached for 2 minutes. Each aircraft's `dir` (inbound, outbound, ground or other) is the server's answer for that fix; the app keeps an airborne aircraft's earlier direction until it lands (`DirectionMemory`), so an arrival on downwind or in a hold stays inbound.

There is no live timetable. As in the Dive, the boards come from each callsign's usual time at the airport over the last 30 days, and the delay is the estimated arrival (or take-off) against that usual time: green under 15 minutes late, amber 15 to 44, red 45 or more. `GroundKit/Logic/BoardBuilder.swift` is a line-for-line port of the Dive's logic, so the app and the dashboard agree. Flights the backend tags as freighters (`is_freighter` in the snapshot history and on `/api/live`, from its list of all-cargo operators) carry a *Freighter* tag; nothing is filtered out, since passenger flights carry belly cargo too.

The app refreshes every 2 minutes while open (the live feed's cache time), fetches the snapshot at most every 5 minutes, and keeps the last snapshot on disk so it opens with data in a dead spot.

## Airport map and location

- The layout comes from the [Overpass API](https://wiki.openstreetmap.org/wiki/Overpass_API) (OpenStreetMap, no key), not from the warehouse: first the aerodrome's outline for a box, then everything mapped in it. It is downloaded once per airport (HKG is about 2.7 MB), kept in Application Support (excluded from backup), and refreshed after 30 days; tap the attribution line to refresh it sooner. When the main server is busy the app tries two mirrors.
- Cargo buildings are those tagged as warehouses or named for cargo, freight, logistics, express, mail or the big integrators. Service roads (where tugs, dollies and other GSE drive) are drawn in orange.
- Routes are the shortest path along the mapped roads (`RoadGraph` in `Logic/AirportLayout.swift`), keeping to one-way roads where it can, with an estimate at 25 km/h. They never use taxiways or runways. OSM is mapped by volunteers, so the app says to follow the airport's charts, markings and airside driving rules.
- Your position (when in use only) is used while a map is on screen, after you allow it from the map. It is not stored or sent anywhere.

## Fatigue and heat strain

- **Sleep** is read from Health for the 48 h before the shift (or before now, off shift): the asleep stages only, not time in bed or awake. The checks are the prior sleep/wake model from ICAO's FRMS manual (Dawson and McCulloch): at least 5 h sleep in the 24 h before duty, 12 h in the 48 h before, and no longer awake than the sleep in those 48 h. No sleep recorded is unknown, not zero.
- **Rest and hours** come from the shifts in the app: under 11 h between shifts, or over 48 h worked in 7 days, gets a caution (the EU Working Time Directive's figures).
- **Heat strain**: when it feels like 27 °C or more, a heart rate staying over 180 minus your age for 5 minutes is a warning, and within 15 bpm of that a caution (NIOSH, 2016). Age is optional in Settings; without it, 40 is assumed. The lowest reading in the 5 minutes decides, so one spike does not count.
- **Breaks** are logged with a button; the break prompt shows after 2 hours without one. **Ending a shift** keeps a summary with it: time, breaks and the longest stretch without one, water against the target, steps, distance, active energy, average and peak heart rate, and sleep before it.
- All guidance, not medical advice: rosters, the employer's fatigue and heat procedures, and supervisors decide.

## Records and sync (CloudKit)

Turnarounds, shifts (with their breaks and summary) and handover notes are SwiftData models (`GroundKit/Models/RampRecords.swift`) stored with `cloudKitDatabase: .automatic`, so they sync through the iCloud private database to every device signed in to the same Apple Account. Without the entitlement or an iCloud account they stay on the device. The models follow CloudKit's rules: defaults on every attribute, no unique constraints, optional relationships with inverses.

The private database is per Apple Account, so it suits one person's devices or a shared crew iPad. Sharing between colleagues' own phones would need `CKShare` or the public database (see Next steps).

## Account (optional)

Settings > Account signs in with an email and password or with Google (`ASWebAuthenticationSession`, PKCE), through Supabase Auth. Signed in, the airport, glove mode, keep screen on, appearance and wind limits sync with the Android app and the web dashboard. Age and the API address stay on the device. Account > Delete account removes the account and its synced settings. Without a Supabase URL and key the section is hidden.

- `Services/SupabaseClient.swift`: the Auth and REST calls over URLSession (no SDK).
- `Services/AccountService.swift`: session (Keychain, this device only), token refresh and sync. It watches the app's settings through `UserDefaults` and `AirportStore`.
- `Logic/SyncedSettings.swift`: the shared settings contract and its per-key merge.

The contract, the Supabase setup and known gaps are in the aviation repo's [docs/accounts.md](https://github.com/watanaberyunosuke/groundkit-dashboard/blob/main/docs/accounts.md).

## Setup

1. Open `GroundKit.xcodeproj` in Xcode 26 or later.
2. In Signing & Capabilities for the GroundKit target, choose your team. Change the bundle identifier (`com.harrydatahub.GroundKit`) if it is taken, and the iCloud container (`iCloud.com.harrydatahub.GroundKit` in `Config/GroundKit.entitlements`) to match.
3. Check the iCloud (CloudKit) and HealthKit capabilities are on. The new `Shift` fields (`breaks`, `summaryData`) are additive, so existing stores migrate on their own; deploy the CloudKit schema again before a release. Xcode creates the container on first run. Before a release, deploy the CloudKit schema to production in the CloudKit Console.
4. Accounts (optional): set `GKSupabaseURL` and `GKSupabaseKey` (the project's publishable key) in `Config/Info.plist`. Sign in with Apple and Microsoft are off: Sign in with Apple needs a paid Apple Developer Program membership.
5. Run on a device or simulator. Health data is richer on a device paired with an Apple Watch.

The app was called Ramp Ops until October 2026. The bundle identifier and iCloud container changed with the name, so GroundKit installs as a new app and starts with an empty iCloud store; turnarounds, shifts and notes saved by Ramp Ops are not carried over.

To run against a local API instead of production (from the aviation repo, with its local warehouse):

```bash
WAREHOUSE=data/aviation.duckdb uvicorn api.index:app --port 8000
```

then set the API address in Settings to `http://localhost:8000`, or launch with `-apiBaseURL http://localhost:8000`. `NSAllowsLocalNetworking` permits plain HTTP to local addresses only.

## Tests

```bash
xcodebuild test -scheme GroundKit -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

Swift Testing covers the board logic (placement, ETA, delay, on-stand lateness, predicted flights, landings remembered across fixes, coverage gaps), the ramp advisories (thunderstorms, storm clouds, TAF validity, wind limits, heat index, wind chill, ice, low visibility, stale weather, NOTAM relevance), METAR wording, decoding the API's JSON, sunrise and sunset (HKG and LHR, polar night), the fatigue, rest, weekly-hours, heat-strain and break rules, the OpenStreetMap layout parser, place search and road routes (including one-way roads), and the account sync (settings merge, PKCE, session and error parsing). The same cases as the Android app's tests.

## Layout

```
GroundKit/
  App/          entry point, tabs, cross-tab navigation
  Models/       API types (Snapshot.swift), SwiftData records (RampRecords.swift)
  Services/     API client and on-disk cache, AirportStore (refresh, boards), HealthService,
                OpenStreetMap layouts (Overpass), LocationTracker
  Logic/        BoardBuilder (from the Dive), RampAdvisor, WeatherText, Geo and local time,
                AirportLayout and RoadGraph, Wellbeing (fatigue, heat strain), Solar
  Design/       shared components: cards, tiles, status pills, big buttons, clocks
  Features/     Now, Map, Boards, Turnarounds, Shift, Settings
GroundKitTests/   Swift Testing
Config/         Info.plist additions and entitlements
```

## Next steps

1. Crew sharing: share a turnaround or the handover notes with colleagues via `CKShare` (SwiftData does not share yet, so this needs Core Data with `NSPersistentCloudKitContainer`, or the public database).
2. Widgets and a Live Activity for the next arrival and the ramp status on the Lock Screen and Dynamic Island.
3. Notifications when the ramp status rises to Caution or Warning (a server push, since the app only refreshes while open).
4. A watchOS companion for steps on the wrist: the turnaround checklist and water logging.
