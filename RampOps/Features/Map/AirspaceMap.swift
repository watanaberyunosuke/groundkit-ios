import MapKit
import SwiftUI

// The airspace map, as in the Dive: live aircraft coloured by delay status, the observed
// arrival and departure paths of the last 3 days (which trace the procedures in use), the
// 50 NM terminal area and the wind.

enum MapZoom: String, CaseIterable, Identifiable {
    case airport = "Airport"
    case terminal = "50 NM"
    case wide = "500 NM"

    var id: String { rawValue }

    /// Height of the region shown, metres.
    var span: CLLocationDistance {
        switch self {
        case .airport: 7_000
        case .terminal: 2.4 * Geo.terminalKm * 1000
        case .wide: 2 * 926_000
        }
    }

    func position(_ center: CLLocationCoordinate2D) -> MapCameraPosition {
        .region(MKCoordinateRegion(center: center, latitudinalMeters: span, longitudinalMeters: span))
    }
}

struct AirspaceMap: View {
    @Environment(AirportStore.self) private var store
    @Binding var position: MapCameraPosition
    var interactive: Bool
    /// Parked and taxiing aircraft; left out of the small preview, where they hide the airport.
    var showGround = true
    /// Flight numbers on parked aircraft and satellite imagery, for the close-in view.
    var airportView = false
    var onSelect: (PlacedAircraft) -> Void = { _ in }

    var body: some View {
        let airport = store.airport
        let center = CLLocationCoordinate2D(latitude: airport.lat, longitude: airport.lon)
        Map(position: $position, interactionModes: interactive ? .all : []) {
            MapCircle(center: center, radius: Geo.terminalKm * 1000)
                .foregroundStyle(.blue.opacity(0.05))
                .stroke(.blue.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            ForEach(Array(store.tracks.enumerated()), id: \.offset) { _, track in
                MapPolyline(coordinates: track.points.compactMap { p in
                    p.count == 2 ? CLLocationCoordinate2D(latitude: p[0], longitude: p[1]) : nil
                })
                .stroke(track.role == "arrival" ? Color.blue.opacity(0.35) : Color.purple.opacity(0.35), lineWidth: 1.5)
            }
            Annotation(airport.iata, coordinate: center, anchor: .center) {
                Image(systemName: "airplane.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.black, .yellow)
            }
            ForEach(store.placed.filter { showGround || $0.kind != .ground }.sorted { $0.kind.drawOrder < $1.kind.drawOrder }) { p in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: p.aircraft.lat, longitude: p.aircraft.lon),
                           anchor: .center) {
                    AircraftMarker(placed: p, showLabel: interactive && (p.kind != .ground || airportView))
                        .onTapGesture { onSelect(p) }
                }
            }
        }
        .mapStyle(airportView ? .hybrid(elevation: .flat, pointsOfInterest: .excludingAll)
                  : .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls {
            if interactive {
                MapCompass()
                MapScaleView()
            }
        }
        .overlay(alignment: .topLeading) {
            if let c = store.conditions { WindBadge(c: c).padding(8) }
        }
    }
}

private extension PlacedAircraft.Kind {
    /// Background traffic first, so the airport's own flights draw on top.
    var drawOrder: Int {
        switch self {
        case .other: 0
        case .ground: 1
        case .outbound: 2
        case .inbound: 3
        }
    }
}

struct AircraftMarker: View {
    var placed: PlacedAircraft
    var showLabel: Bool

    var body: some View {
        let p = placed
        let ours = p.kind == .inbound || p.kind == .outbound
        let labelled = showLabel && (ours || p.kind == .ground)
        VStack(spacing: 1) {
            // The symbol points east, so turn it by the track less 90°.
            Image(systemName: "airplane")
                .font(.system(size: ours ? 20 : p.kind == .ground ? 13 : 12, weight: .bold))
                .rotationEffect(.degrees((p.aircraft.trackDeg ?? 90) - 90))
                .foregroundStyle(color)
                .shadow(color: .black.opacity(0.5), radius: 1)
            if labelled {
                Text(p.label)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 4)
                    .background(.regularMaterial, in: .capsule)
            }
        }
        .frame(minWidth: 32, minHeight: 32) // tap target
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(.isButton)
    }

    private var color: Color {
        switch placed.kind {
        case .inbound, .outbound: placed.rag == .unknown ? .blue : placed.rag.color
        case .ground: .brown
        case .other: .gray.opacity(0.7)
        }
    }

    private var accessibility: String {
        let p = placed
        switch p.kind {
        case .inbound: return "\(p.label) inbound, \(Rag.text(delay: p.delayMin)), \(Int(p.distNm)) nautical miles"
        case .outbound: return "\(p.label) outbound, \(Int(p.distNm)) nautical miles"
        case .ground: return "\(p.label) on the ground"
        case .other: return "\(p.label), other traffic"
        }
    }
}

/// Wind on the map: the arrow points where the wind blows to.
struct WindBadge: View {
    var c: Conditions

    var body: some View {
        HStack(spacing: 6) {
            if let dir = c.windDirDeg, c.windVariable != true, (c.windSpeedKt ?? 0) > 0 {
                Image(systemName: "location.north.fill")
                    .rotationEffect(.degrees(Double(dir) + 180))
                    .foregroundStyle(.blue)
            }
            Text(WeatherText.wind(dir: c.windDirDeg, variable: c.windVariable, speed: c.windSpeedKt, gust: c.windGustKt))
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Wind \(WeatherText.wind(dir: c.windDirDeg, variable: c.windVariable, speed: c.windSpeedKt, gust: c.windGustKt))")
    }
}

/// The map on the Now screen: a still preview of the terminal area; tap for the full map.
struct MapCard: View {
    @Environment(AirportStore.self) private var store
    @State private var position: MapCameraPosition = .automatic
    @State private var showFull = false

    var body: some View {
        let inbound = store.placed.filter { $0.kind == .inbound }.count
        let outbound = store.placed.filter { $0.kind == .outbound }.count
        VStack(alignment: .leading, spacing: 8) {
            AirspaceMap(position: $position, interactive: false, showGround: false)
                .frame(height: 240)
                .clipShape(.rect(cornerRadius: 16))
                .overlay(alignment: .bottomTrailing) {
                    Label("Full map", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.regularMaterial, in: .capsule)
                        .padding(8)
                }
                .contentShape(.rect)
                .onTapGesture { showFull = true }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Airspace map, \(inbound) inbound and \(outbound) outbound. Opens the full map")
            Text("\(inbound) inbound · \(outbound) outbound within 500 NM")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .onAppear { position = MapZoom.terminal.position(center) }
        .onChange(of: store.icao) { position = MapZoom.terminal.position(center) }
        .fullScreenCover(isPresented: $showFull) { MapScreen() }
    }

    private var center: CLLocationCoordinate2D { .init(latitude: store.airport.lat, longitude: store.airport.lon) }
}

struct MapScreen: View {
    @Environment(AirportStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var zoom = MapZoom.terminal
    @State private var position: MapCameraPosition = .automatic
    @State private var selected: BoardEntry?

    var body: some View {
        NavigationStack {
            AirspaceMap(position: $position, interactive: true, airportView: zoom == .airport) { selected = store.entry(for: $0) }
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .bottom) { legend }
                .navigationTitle("\(store.airport.iata) airspace")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .principal) {
                        Picker("Zoom", selection: $zoom) {
                            ForEach(MapZoom.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                    }
                }
                .onAppear { position = zoom.position(center) }
                .onChange(of: zoom) { withAnimation { position = zoom.position(center) } }
                .sheet(item: $selected) { FlightDetailView(entry: $0) }
        }
    }

    private var center: CLLocationCoordinate2D { .init(latitude: store.airport.lat, longitude: store.airport.lon) }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 4) {
                legendItem("On time", .green)
                legendItem("15–44 min late", .orange)
                legendItem("45+ min late", .red)
                legendItem("No usual time", .blue)
                legendItem("On the ground", .brown)
                legendItem("Other traffic", .gray)
                Label("Arrival paths", systemImage: "line.diagonal").foregroundStyle(.blue)
                Label("Departure paths", systemImage: "line.diagonal").foregroundStyle(.purple)
            }
            if let live = store.live {
                Text("Live: \(live.source), \(live.at, format: .relative(presentation: .named)). Paths: last 3 days of tracked flights.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    private func legendItem(_ text: String, _ color: Color) -> some View {
        Label { Text(text) } icon: { Image(systemName: "airplane").foregroundStyle(color) }
    }
}
