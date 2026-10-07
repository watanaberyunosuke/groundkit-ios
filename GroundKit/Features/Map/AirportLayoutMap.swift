import MapKit
import SwiftUI

// The airport's layout as a ramp worker's navigation map: runways, taxiways and stands,
// aprons, terminals, cargo sheds and other buildings, gates, and the service roads tugs and
// cargo dollies use, from OpenStreetMap. Shows where you are, finds a gate, stand, taxiway
// or building, and routes to it by road. Drawn with MKMapView overlays, one per kind, since
// a big airport has thousands of shapes.

/// Airside driving speed for the time estimate; local limits vary (often 15–30 km/h).
private let driveKmh = 25.0
/// Zoom levels as in the Android app: log2 of the world's width over 128 points.
private let minZoom = 11.0
private let maxZoom = 19.5
private let fallbackZoom = 14.5

private func labelZoom(_ kind: PlaceKind) -> Double {
    switch kind {
    case .cargo, .terminal: 14.5
    case .taxiway: 15
    case .hangar: 15.5
    case .gate: 16
    case .stand, .building: 16.5
    }
}

private func labelRank(_ kind: PlaceKind) -> Int {
    switch kind {
    case .cargo: 0
    case .terminal: 1
    case .taxiway: 2
    case .hangar: 3
    case .gate: 4
    case .stand: 5
    case .building: 6
    }
}

// MARK: - Screen

struct AirportLayoutScreen: View {
    @Environment(AirportStore.self) private var store
    @Environment(LayoutStore.self) private var layouts
    @Environment(LocationTracker.self) private var location
    @Environment(\.colorScheme) private var colorScheme
    @State private var controller = LayoutMapController()
    @State private var selected: Place?
    @State private var routeTo: Place?
    @State private var route: Route?
    @State private var routing = false
    @State private var searching = false
    @State private var showLegend = false

    private struct RouteKey: Hashable {
        var target: String?
        var lat: Int?
        var lon: Int?
        var layout: Date?
    }

    var body: some View {
        let airport = store.airport
        let layout = layouts.layout.flatMap { $0.icao == airport.icao ? $0 : nil }
        let style = LayoutStyle(dark: colorScheme == .dark)
        AirportLayoutMap(airport: airport, layout: layout, route: route, selected: selected, style: style,
                         showsUser: location.isAllowed, controller: controller) { place in
            selected = place
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .topLeading) { controls(airport) }
        .overlay(alignment: .top) { searchButton(layout) }
        .overlay(alignment: .topTrailing) { legend(style) }
        .safeAreaInset(edge: .bottom) { bottom(airport, layout) }
        .task(id: airport.icao) {
            selected = nil
            routeTo = nil
            layouts.show(airport)
        }
        // The route, again as I move (about every 20 m).
        .task(id: RouteKey(target: routeTo?.id, lat: location.fix.map { Int(($0.lat * 5_000).rounded()) },
                           lon: location.fix.map { Int(($0.lon * 5_000).rounded()) }, layout: layout?.fetchedAt)) {
            guard let target = routeTo, let fix = location.fix, let layout else {
                route = nil
                return
            }
            routing = route == nil
            let found = await Task.detached(priority: .userInitiated) {
                layout.route(fromLat: fix.lat, fromLon: fix.lon, toLat: target.lat, toLon: target.lon)
            }.value
            if !Task.isCancelled { route = found }
            routing = false
        }
        .sheet(isPresented: $searching) {
            if let layout {
                PlaceSearchSheet(layout: layout, me: location.fix) { place in
                    searching = false
                    selected = place
                    controller.centre(lat: place.lat, lon: place.lon, atLeast: place.kind == .taxiway ? 16 : 17)
                }
            }
        }
    }

    private func controls(_ airport: Airport) -> some View {
        VStack(spacing: 8) {
            MapControlButton(systemImage: "plus", label: "Zoom in") { controller.zoom(by: 1) }
            MapControlButton(systemImage: "minus", label: "Zoom out") { controller.zoom(by: -1) }
            MapControlButton(systemImage: "arrow.up.left.and.arrow.down.right", label: "Show all of \(airport.iata)") {
                controller.fitLayout()
            }
            MapControlButton(systemImage: controller.isFollowing ? "location.fill" : "location",
                             label: controller.isFollowing ? "Following your position" : "Show my position") {
                if location.isAllowed { controller.follow() } else { location.request() }
            }
        }
        .padding(12)
    }

    private func searchButton(_ layout: AirportLayout?) -> some View {
        Button { searching = true } label: {
            Label("Find gate, stand, building…", systemImage: "magnifyingglass")
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .padding(.horizontal, 16)
                .background(.regularMaterial, in: .capsule)
        }
        .disabled(layout == nil)
        .padding(.horizontal, 76)
        .padding(.top, 12)
    }

    private func legend(_ style: LayoutStyle) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            MapControlButton(systemImage: "square.3.layers.3d", label: "Map key") { showLegend.toggle() }
            if showLegend {
                VStack(alignment: .leading, spacing: 3) {
                    legendItem(style.runway, "Runway")
                    legendItem(style.taxiLine, "Taxiway")
                    legendItem(style.holding, "Holding point")
                    legendItem(style.serviceRoad, "Service road (GSE, cargo)")
                    legendItem(style.road, "Public road")
                    legendItem(style.terminalEdge, "Terminal")
                    legendItem(style.cargoEdge, "Cargo building")
                    legendItem(style.gate, "Gate")
                    legendItem(style.route, "Your route")
                }
                .font(.caption)
                .padding(10)
                .background(.regularMaterial, in: .rect(cornerRadius: 10))
            }
        }
        .padding(12)
    }

    private func legendItem(_ color: UIColor, _ text: String) -> some View {
        Label { Text(text) } icon: { Circle().fill(Color(uiColor: color)).frame(width: 10, height: 10) }
    }

    @ViewBuilder
    private func bottom(_ airport: Airport, _ layout: AirportLayout?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if layout == nil && layouts.isLoading {
                note {
                    ProgressView()
                    Text("Downloading the \(airport.iata) layout from OpenStreetMap. Once only; it can take a minute.")
                }
            } else if layout == nil, let error = layouts.error {
                note {
                    Text("Couldn't load the layout: \(error)")
                    Spacer()
                    Button("Retry") { layouts.retry(airport) }.buttonStyle(.bordered).controlSize(.large)
                }
            } else if let fix = location.fix, selected == nil,
                      Geo.metres(fix.lat, fix.lon, airport.lat, airport.lon) > 20_000 {
                note { Text("You're \(Int(Geo.metres(fix.lat, fix.lon, airport.lat, airport.lon) / 1000).formatted()) km from \(airport.iata).") }
            }
            if let place = selected {
                PlaceCard(place: place, me: location.fix, route: routeTo == place ? route : nil,
                          routing: routing && routeTo == place,
                          onRoute: {
                              if !location.isAllowed { location.request() }
                              routeTo = place
                          },
                          onClose: {
                              selected = nil
                              routeTo = nil
                          })
            } else {
                Button { layouts.retry(airport) } label: {
                    Text("Layout © OpenStreetMap contributors (ODbL)"
                         + (layout.map { " · \($0.fetchedAt.formatted(date: .abbreviated, time: .omitted))" } ?? "")
                         + ". Check against airport charts and markings.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .disabled(layout == nil || layouts.isLoading)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityHint("Downloads the layout again")
            }
        }
        .padding(12)
    }

    private func note<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: .rect(cornerRadius: 10))
    }
}

/// A large, thumb-sized round button over a map.
struct MapControlButton: View {
    var systemImage: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(width: 52, height: 52)
                .background(.regularMaterial, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Distance and compass direction from me, as "1.2 km NE".
private func fromMe(_ me: LocationTracker.Fix?, _ p: Place) -> String? {
    guard let me else { return nil }
    let d = Geo.metres(me.lat, me.lon, p.lat, p.lon)
    let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    let dir = dirs[Int((Geo.bearingDeg(me.lat, me.lon, p.lat, p.lon) + 22.5) / 45) % 8]
    return "\(distance(d)) \(dir)"
}

private func distance(_ m: Double) -> String {
    m < 1000 ? "\(Int((m / 10).rounded()) * 10) m" : String(format: "%.1f km", m / 1000)
}

private struct PlaceCard: View {
    var place: Place
    var me: LocationTracker.Fix?
    var route: Route?
    var routing: Bool
    var onRoute: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.title).font(.title2.weight(.bold)).lineLimit(2)
                    Text(subtitle).font(.body).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 48, height: 48)
            }
            if let route {
                let minutes = max(1, Int((route.distanceM / 1000 / driveKmh * 60).rounded()))
                Text("\(distance(route.distanceM)) by road · about \(minutes) min at \(Int(driveKmh)) km/h")
                    .font(.headline)
                    .foregroundStyle(.blue)
                Text((route.ignoresOneWay ? "No route keeps to the one-way roads mapped; this one doesn't. " : "")
                     + "From OpenStreetMap: follow airside driving rules, markings and marshallers, and never cross a runway or taxiway without clearance.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if routing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finding a route…")
                }
            } else {
                Button(me == nil ? "Route from my position" : "Route by road", systemImage: "arrow.triangle.turn.up.right.diamond.fill",
                       action: onRoute)
                    .buttonStyle(BigButtonStyle(tint: .blue))
            }
        }
        .padding(16)
        .background(.background, in: .rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }

    private var subtitle: String {
        let parts = [place.title == "\(place.kind.label) \(place.label)" ? nil : place.kind.label,
                     fromMe(me, place).map { "\($0) from you" }].compactMap(\.self)
        return parts.isEmpty ? place.kind.label : parts.joined(separator: " · ")
    }
}

private struct PlaceSearchSheet: View {
    var layout: AirportLayout
    var me: LocationTracker.Fix?
    var onPick: (Place) -> Void
    @State private var query = ""

    var body: some View {
        let results = layout.search(query, limit: 60)
        NavigationStack {
            List(results) { p in
                Button { onPick(p) } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(p.title).font(.headline).lineLimit(1)
                            Text(p.kind.label).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let d = fromMe(me, p) { Text(d).font(.subheadline).foregroundStyle(.secondary) }
                    }
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView(layout.places.isEmpty ? "Nothing named here" : "No matches",
                                           systemImage: "magnifyingglass",
                                           description: Text(layout.places.isEmpty
                                                             ? "No gates, stands or buildings are named in the OpenStreetMap layout here."
                                                             : "Nothing matches \"\(query)\"."))
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Gate 23, stand N5, taxiway K, cargo…")
            .navigationTitle("Find")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
    }
}

// MARK: - Colours

/// Colours for the layout, light and dark.
struct LayoutStyle: Equatable {
    var apron, apronEdge, terminal, terminalEdge, cargo, cargoEdge: UIColor
    var hangar, building, buildingEdge, runway, runwayMark: UIColor
    var taxiPavement, taxiLine, taxiSign, holding, jetBridge, gate: UIColor
    var serviceRoad, road, route, routeHalo, selected, label, labelHalo: UIColor
    var dark: Bool

    init(dark: Bool) {
        self.dark = dark
        if dark {
            apron = .rgb(0x2B2F36); apronEdge = .rgb(0x3B414A)
            terminal = .rgb(0x1E3A5F); terminalEdge = .rgb(0x93C5FD)
            cargo = .rgb(0x3B2763); cargoEdge = .rgb(0xC4B5FD)
            hangar = .rgb(0x334155); building = .rgb(0x30353D); buildingEdge = .rgb(0x4B525C)
            runway = .rgb(0x4B5058); runwayMark = .rgb(0xE5E7EB)
            taxiPavement = .rgb(0x383D45); taxiLine = .rgb(0xFFC72C); taxiSign = .rgb(0xFFC72C)
            holding = .rgb(0xF87171); jetBridge = .rgb(0x6B7280); gate = .rgb(0x93C5FD)
            serviceRoad = .rgb(0xFB923C); road = .rgb(0x6B7280)
            route = .rgb(0x60A5FA); routeHalo = .rgb(0x0E1013); selected = .rgb(0xF87171)
            label = .rgb(0xE5E7EB); labelHalo = .rgb(0x0E1013, alpha: 0.8)
        } else {
            apron = .rgb(0xDDE1E6); apronEdge = .rgb(0xC3C8CF)
            terminal = .rgb(0xBFDBFE); terminalEdge = .rgb(0x1D4ED8)
            cargo = .rgb(0xDDD6FE); cargoEdge = .rgb(0x6D28D9)
            hangar = .rgb(0xCBD5E1); building = .rgb(0xE7E9EC); buildingEdge = .rgb(0xB8BEC6)
            runway = .rgb(0x5B6270); runwayMark = .white
            taxiPavement = .rgb(0xC9CED5); taxiLine = .rgb(0xD69E00); taxiSign = .rgb(0xFFC72C)
            holding = .rgb(0xC81E1E); jetBridge = .rgb(0x7B8491); gate = .rgb(0x1D4ED8)
            serviceRoad = .rgb(0xEA7A1E); road = .rgb(0xA3AAB4)
            route = .rgb(0x2563EB); routeHalo = .white; selected = .rgb(0xC81E1E)
            label = .rgb(0x1F2933); labelHalo = .rgb(0xFFFFFF, alpha: 0.8)
        }
    }

    func areaFill(_ k: AreaKind) -> UIColor {
        switch k {
        case .runway: runway
        case .apron: apron
        case .terminal: terminal
        case .cargo: cargo
        case .hangar: hangar
        case .building: building
        }
    }

    func areaStroke(_ k: AreaKind) -> UIColor {
        switch k {
        case .runway: runway
        case .apron: apronEdge
        case .terminal: terminalEdge
        case .cargo: cargoEdge
        case .hangar, .building: buildingEdge
        }
    }

    func labelColor(_ k: PlaceKind) -> UIColor {
        switch k {
        case .taxiway: .rgb(0x111111)
        case .cargo: cargoEdge
        case .terminal: terminalEdge
        default: label
        }
    }
}

private extension UIColor {
    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: - Map view

/// Moves the map on request from the screen's buttons and search.
@Observable
final class LayoutMapController {
    @ObservationIgnored weak var mapView: MKMapView?
    @ObservationIgnored var layoutBounds: MKMapRect?
    private(set) var isFollowing = false

    func setFollowing(_ on: Bool) { isFollowing = on }

    func fitLayout() {
        guard let map = mapView, let rect = layoutBounds else { return }
        map.setUserTrackingMode(.none, animated: false)
        map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 80, left: 70, bottom: 120, right: 20), animated: true)
    }

    func centre(lat: Double, lon: Double, atLeast zoom: Double? = nil) {
        guard let map = mapView else { return }
        map.setUserTrackingMode(.none, animated: false)
        let target = max(zoom ?? 0, Self.zoom(of: map))
        map.setRegion(Self.region(lat: lat, lon: lon, zoom: target, in: map), animated: true)
    }

    func zoom(by levels: Double) {
        guard let map = mapView else { return }
        let c = map.region.center
        let target = min(maxZoom, max(minZoom, Self.zoom(of: map) + levels))
        map.setRegion(Self.region(lat: c.latitude, lon: c.longitude, zoom: target, in: map), animated: true)
    }

    func follow() {
        guard let map = mapView else { return }
        if Self.zoom(of: map) < 16.5, let here = map.userLocation.location?.coordinate {
            map.setRegion(Self.region(lat: here.latitude, lon: here.longitude, zoom: 16.5, in: map), animated: true)
        }
        map.setUserTrackingMode(.follow, animated: true)
    }

    /// log2 of the world's width in points over 128, as the Android app's zoom.
    static func zoom(of map: MKMapView) -> Double {
        let lonDelta = max(map.region.span.longitudeDelta, 1e-9)
        return log2(Double(max(map.bounds.width, 1)) * 360 / lonDelta / 128)
    }

    static func region(lat: Double, lon: Double, zoom: Double, in map: MKMapView) -> MKCoordinateRegion {
        let width = Double(max(map.bounds.width, 320)), height = Double(max(map.bounds.height, 320))
        let lonDelta = width * 360 / (128 * pow(2, zoom))
        let latDelta = lonDelta * height / width * cos(lat * .pi / 180)
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                  span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))
    }
}

private final class PlaceAnnotation: NSObject, MKAnnotation {
    let place: Place
    let coordinate: CLLocationCoordinate2D

    init(_ place: Place) {
        self.place = place
        coordinate = CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon)
    }

    var title: String? { place.title }
}

private final class HoldAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D

    init(lat: Double, lon: Double) { coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

private final class SelectedAnnotation: NSObject, MKAnnotation {
    let place: Place
    let coordinate: CLLocationCoordinate2D

    init(_ place: Place) {
        self.place = place
        coordinate = CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon)
    }

    var title: String? { place.title }
}

/// How a group of lines is drawn: a minimum width in points (thinner when zoomed out), a
/// real width in metres where known, and dashes.
private struct LineStyle {
    var color: UIColor
    var minPt: CGFloat
    var widthM: Double?
    var dashM: [Double]?
    var dashPt: [CGFloat]?
    var round = false
    var fromZoom = 0.0
}

struct AirportLayoutMap: UIViewRepresentable {
    var airport: Airport
    var layout: AirportLayout?
    var route: Route?
    var selected: Place?
    var style: LayoutStyle
    var showsUser: Bool
    var controller: LayoutMapController
    var onSelect: (Place) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = true
        map.showsScale = true
        map.register(LabelAnnotationView.self, forAnnotationViewWithReuseIdentifier: LabelAnnotationView.reuseID)
        map.register(HoldAnnotationView.self, forAnnotationViewWithReuseIdentifier: HoldAnnotationView.reuseID)
        controller.mapView = map
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        controller.mapView = map
        map.showsUserLocation = showsUser
        if c.airportIcao != airport.icao {
            c.airportIcao = airport.icao
            map.setRegion(LayoutMapController.region(lat: airport.lat, lon: airport.lon, zoom: fallbackZoom, in: map), animated: false)
        }
        c.install(layout, style: style, on: map)
        c.showRoute(route, style: style, on: map)
        c.showSelected(selected, on: map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: AirportLayoutMap
        var airportIcao: String?
        private var layoutKey: String?
        private var fittedIcao: String?
        private var style: LayoutStyle?
        private var lineStyles: [ObjectIdentifier: LineStyle] = [:]
        private var areaKinds: [ObjectIdentifier: AreaKind] = [:]
        private var layoutOverlays: [MKOverlay] = []
        private var routeOverlays: [MKOverlay] = []
        private var routeShown: Route?
        private var places: [String: PlaceAnnotation] = [:]
        private var holds: [HoldAnnotation] = []
        private var holdsShown = false
        private var selectedAnnotation: SelectedAnnotation?
        private var zoom = fallbackZoom

        init(_ parent: AirportLayoutMap) { self.parent = parent }

        // MARK: Content

        func install(_ layout: AirportLayout?, style: LayoutStyle, on map: MKMapView) {
            let key = layout.map { "\($0.icao)@\($0.fetchedAt.timeIntervalSince1970)" }
            guard key != layoutKey || style != self.style else { return }
            let styleOnly = key == layoutKey
            layoutKey = key
            self.style = style
            map.removeOverlays(layoutOverlays)
            layoutOverlays = []
            lineStyles = [:]
            areaKinds = [:]
            if !styleOnly {
                map.removeAnnotations(Array(places.values) + holds)
                places = [:]
                holds = []
                holdsShown = false
            }
            guard let layout else {
                parent.controller.layoutBounds = nil
                return
            }
            for kind in AreaKind.allCases {
                let polygons = layout.areas.filter { $0.kind == kind }.map { polygon($0.shape) }
                guard !polygons.isEmpty else { continue }
                let overlay = MKMultiPolygon(polygons)
                areaKinds[ObjectIdentifier(overlay)] = kind
                layoutOverlays.append(overlay)
            }
            // Pavement under the markings: roads, then runways and taxiways at their real widths.
            addLines(layout, .road, LineStyle(color: style.road, minPt: 3, widthM: 9, round: true))
            addLines(layout, .serviceRoad, LineStyle(color: style.serviceRoad, minPt: 2.5, widthM: 6, round: true))
            addLines(layout, .runway, LineStyle(color: style.runway, minPt: 6, widthM: 45), byWidth: true)
            addLines(layout, .stopway, LineStyle(color: style.runway.withAlphaComponent(0.6), minPt: 6, widthM: 45), byWidth: true)
            addLines(layout, .taxiway, LineStyle(color: style.taxiPavement, minPt: 3, widthM: 23, round: true), byWidth: true)
            addLines(layout, .taxilane, LineStyle(color: style.taxiPavement, minPt: 2, widthM: 15, round: true), byWidth: true)
            // Markings.
            addLines(layout, .runway, LineStyle(color: style.runwayMark, minPt: 1.5, dashM: [30, 20], fromZoom: 14.5))
            addLines(layout, .taxiway, LineStyle(color: style.taxiLine, minPt: 1.6))
            addLines(layout, .taxilane, LineStyle(color: style.taxiLine, minPt: 1.2))
            addLines(layout, .stand, LineStyle(color: style.taxiLine, minPt: 1, dashPt: [6, 4], fromZoom: 15.5))
            addLines(layout, .jetBridge, LineStyle(color: style.jetBridge, minPt: 2, widthM: 3, round: true, fromZoom: 15.5))
            addLines(layout, .holding, LineStyle(color: style.holding, minPt: 3))
            map.addOverlays(layoutOverlays, level: .aboveRoads)

            if !styleOnly {
                for p in layout.places { places[p.id] = PlaceAnnotation(p) }
                holds = layout.holdingPoints.map { HoldAnnotation(lat: $0.lat, lon: $0.lon) }
            } else {
                // Restyle the labels already on the map.
                for a in map.annotations {
                    (map.view(for: a) as? LabelAnnotationView)?.style = style
                    (map.view(for: a) as? HoldAnnotationView)?.color = style.holding
                }
            }
            if let b = layout.bounds {
                let p0 = MKMapPoint(CLLocationCoordinate2D(latitude: b.maxLat, longitude: b.minLon))
                let p1 = MKMapPoint(CLLocationCoordinate2D(latitude: b.minLat, longitude: b.maxLon))
                parent.controller.layoutBounds = MKMapRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                                                           width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
            }
            // Fit the airport once its layout is known, after this layout pass.
            if fittedIcao != layout.icao {
                fittedIcao = layout.icao
                let controller = parent.controller
                DispatchQueue.main.async { controller.fitLayout() }
            }
            refresh(map)
        }

        private func polygon(_ s: LayoutShape) -> MKPolygon {
            var coords = zip(s.lats, s.lons).map { CLLocationCoordinate2D(latitude: $0, longitude: $1) }
            return MKPolygon(coordinates: &coords, count: coords.count)
        }

        private func polyline(_ s: LayoutShape) -> MKPolyline {
            var coords = zip(s.lats, s.lons).map { CLLocationCoordinate2D(latitude: $0, longitude: $1) }
            return MKPolyline(coordinates: &coords, count: coords.count)
        }

        /// Lines of one kind share a width unless they carry their own (runways, taxiways).
        private func addLines(_ layout: AirportLayout, _ kind: LineKind, _ lineStyle: LineStyle, byWidth: Bool = false) {
            let lines = layout.lines.filter { $0.kind == kind }
            let groups = Dictionary(grouping: lines) { byWidth ? $0.widthM : nil }
            for (width, group) in groups.sorted(by: { ($0.key ?? 0) < ($1.key ?? 0) }) {
                let overlay = MKMultiPolyline(group.map { polyline($0.shape) })
                var s = lineStyle
                if byWidth, let width { s.widthM = width }
                lineStyles[ObjectIdentifier(overlay)] = s
                layoutOverlays.append(overlay)
            }
        }

        func showRoute(_ route: Route?, style: LayoutStyle, on map: MKMapView) {
            guard route != routeShown || !routeOverlays.allSatisfy({ lineStyles[ObjectIdentifier($0)] != nil }) else { return }
            routeShown = route
            map.removeOverlays(routeOverlays)
            routeOverlays = []
            guard let route else { return }
            for s in [LineStyle(color: style.routeHalo, minPt: 9, round: true), LineStyle(color: style.route, minPt: 5, round: true)] {
                var coords = zip(route.lats, route.lons).map { CLLocationCoordinate2D(latitude: $0, longitude: $1) }
                let overlay = MKPolyline(coordinates: &coords, count: coords.count)
                lineStyles[ObjectIdentifier(overlay)] = s
                routeOverlays.append(overlay)
            }
            map.addOverlays(routeOverlays, level: .aboveLabels)
        }

        func showSelected(_ place: Place?, on map: MKMapView) {
            guard place != selectedAnnotation?.place else { return }
            if let old = selectedAnnotation { map.removeAnnotation(old) }
            selectedAnnotation = place.map(SelectedAnnotation.init)
            if let new = selectedAnnotation { map.addAnnotation(new) }
        }

        /// Line widths, dashes and which labels show, for the zoom now.
        private func refresh(_ map: MKMapView) {
            zoom = LayoutMapController.zoom(of: map)
            let lonDelta = max(map.region.span.longitudeDelta, 1e-9)
            let ptPerM = Double(map.bounds.width) / (lonDelta * 111_320 * cos(map.region.center.latitude * .pi / 180))
            // Thinner minimum widths when zoomed out, so the airfield doesn't turn to spaghetti.
            let scale = CGFloat(min(1, max(0.35, (zoom - 12) / 3)))
            for overlay in map.overlays {
                guard let s = lineStyles[ObjectIdentifier(overlay)],
                      let r = map.renderer(for: overlay) as? MKOverlayPathRenderer else { continue }
                apply(s, to: r, scale: routeOverlays.contains { $0 === overlay } ? 1 : scale, ptPerM: ptPerM)
                r.setNeedsDisplay()
            }

            let want = Set(places.values.filter { zoom >= labelZoom($0.place.kind) }.map(\.place.id))
            let shown = Set(map.annotations.compactMap { ($0 as? PlaceAnnotation)?.place.id })
            map.removeAnnotations(shown.subtracting(want).compactMap { places[$0] })
            map.addAnnotations(want.subtracting(shown).compactMap { places[$0] })
            let wantHolds = zoom >= 14.5
            if wantHolds != holdsShown {
                holdsShown = wantHolds
                if wantHolds { map.addAnnotations(holds) } else { map.removeAnnotations(holds) }
            }
        }

        private func apply(_ s: LineStyle, to r: MKOverlayPathRenderer, scale: CGFloat, ptPerM: Double) {
            r.strokeColor = s.color
            r.lineWidth = max(s.minPt * scale, CGFloat((s.widthM ?? 0) * ptPerM))
            r.lineCap = s.round ? .round : .butt
            r.lineJoin = .round
            if let dash = s.dashM {
                r.lineDashPattern = dash.map { NSNumber(value: $0 * ptPerM) }
            } else if let dash = s.dashPt {
                r.lineDashPattern = dash.map { NSNumber(value: Double($0 * scale)) }
            }
            r.alpha = zoom >= s.fromZoom ? 1 : 0
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let kind = areaKinds[ObjectIdentifier(overlay)], let polygons = overlay as? MKMultiPolygon, let style {
                let r = MKMultiPolygonRenderer(multiPolygon: polygons)
                r.fillColor = style.areaFill(kind)
                r.strokeColor = style.areaStroke(kind)
                r.lineWidth = 1
                return r
            }
            guard let s = lineStyles[ObjectIdentifier(overlay)] else { return MKOverlayRenderer(overlay: overlay) }
            let r: MKOverlayPathRenderer
            if let multi = overlay as? MKMultiPolyline {
                r = MKMultiPolylineRenderer(multiPolyline: multi)
            } else if let line = overlay as? MKPolyline {
                r = MKPolylineRenderer(polyline: line)
            } else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let lonDelta = max(mapView.region.span.longitudeDelta, 1e-9)
            let ptPerM = Double(mapView.bounds.width) / (lonDelta * 111_320 * cos(mapView.region.center.latitude * .pi / 180))
            let scale = CGFloat(min(1, max(0.35, (zoom - 12) / 3)))
            apply(s, to: r, scale: routeOverlays.contains { $0 === overlay } ? 1 : scale, ptPerM: ptPerM)
            return r
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case let a as PlaceAnnotation:
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: LabelAnnotationView.reuseID, for: a) as? LabelAnnotationView
                v?.style = style
                v?.place = a.place
                return v
            case let a as HoldAnnotation:
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: HoldAnnotationView.reuseID, for: a) as? HoldAnnotationView
                v?.color = style?.holding ?? .red
                return v
            case let a as SelectedAnnotation:
                let v = MKMarkerAnnotationView(annotation: a, reuseIdentifier: nil)
                v.markerTintColor = style?.selected ?? .red
                v.displayPriority = .required
                v.titleVisibility = .visible
                return v
            default:
                return nil // the user's position: MapKit's own blue dot
            }
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let a = view.annotation as? PlaceAnnotation {
                parent.onSelect(a.place)
                mapView.deselectAnnotation(a, animated: false)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            refresh(mapView)
        }

        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            parent.controller.setFollowing(mode != .none)
        }
    }
}

/// A place's name on the map; a yellow sign for taxiway letters, a dot for gates.
private final class LabelAnnotationView: MKAnnotationView {
    static let reuseID = "label"
    private let label = UILabel()
    private let dot = UIView()

    var style: LayoutStyle? { didSet { configure() } }
    var place: Place? { didSet { configure() } }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .rectangle
        canShowCallout = false
        label.layer.cornerRadius = 4
        label.layer.masksToBounds = true
        label.textAlignment = .center
        dot.layer.cornerRadius = 4
        addSubview(dot)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func configure() {
        guard let place, let style else { return }
        let big = place.kind == .cargo || place.kind == .terminal || place.kind == .taxiway
        label.text = place.kind == .gate ? place.label : String(place.label.prefix(28))
        label.font = .systemFont(ofSize: big ? 12 : 11, weight: big ? .bold : .medium)
        label.textColor = style.labelColor(place.kind)
        label.backgroundColor = place.kind == .taxiway ? style.taxiSign : style.labelHalo
        let text = label.intrinsicContentSize
        let size = CGSize(width: text.width + 8, height: text.height + 2)
        let isGate = place.kind == .gate
        dot.isHidden = !isGate
        dot.backgroundColor = style.gate
        if isGate {
            // The dot on the gate, its number to the right.
            dot.frame = CGRect(x: 0, y: (size.height - 8) / 2, width: 8, height: 8)
            label.frame = CGRect(x: 12, y: 0, width: size.width, height: size.height)
            frame.size = CGSize(width: 12 + size.width, height: size.height)
            centerOffset = CGPoint(x: (12 + size.width) / 2 - 4, y: 0)
        } else {
            label.frame = CGRect(origin: .zero, size: size)
            frame.size = size
            centerOffset = .zero
        }
        displayPriority = MKFeatureDisplayPriority(rawValue: 900 - Float(labelRank(place.kind)) * 100)
        accessibilityLabel = place.title
        isAccessibilityElement = true
    }
}

private final class HoldAnnotationView: MKAnnotationView {
    static let reuseID = "hold"
    var color: UIColor = .red { didSet { backgroundColor = color } }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame.size = CGSize(width: 6, height: 6)
        layer.cornerRadius = 3
        backgroundColor = color
        displayPriority = .defaultLow
        collisionMode = .circle
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
