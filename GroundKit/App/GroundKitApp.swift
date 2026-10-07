import SwiftData
import SwiftUI

@main
struct GroundKitApp: App {
    @State private var store = AirportStore()
    @State private var health = HealthService()
    @State private var router = Router()
    @State private var layouts = LayoutStore()
    @State private var location = LocationTracker()
    private let container = Persistence.makeContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(health)
                .environment(router)
                .environment(layouts)
                .environment(location)
        }
        .modelContainer(container)
    }
}

enum AppTab: Hashable {
    case now, arrivals, departures, turnarounds, shift
}

/// Cross-tab navigation: "Start turnaround" on a board opens it in the Turnarounds tab.
@Observable
final class Router {
    var tab: AppTab = .now
    var turnaroundPath: [Turnaround] = []

    func open(_ turnaround: Turnaround) {
        tab = .turnarounds
        turnaroundPath = [turnaround]
    }
}

struct RootView: View {
    @Environment(AirportStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("gloveMode") private var gloveMode = false
    @AppStorage("keepAwake") private var keepAwake = false
    @AppStorage("appearance") private var appearance = Appearance.auto
    /// Ticks each minute, for the Sunset appearance.
    @State private var minute = Date.now

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Now", systemImage: "gauge.with.needle", value: AppTab.now) { NowView() }
            Tab("Arrivals", systemImage: "airplane.arrival", value: AppTab.arrivals) { BoardView(dir: .inbound) }
                .badge(store.arrivals.live.filter { !$0.onGround }.count)
            Tab("Departures", systemImage: "airplane.departure", value: AppTab.departures) { BoardView(dir: .outbound) }
            Tab("Turnarounds", systemImage: "checklist", value: AppTab.turnarounds) { TurnaroundListView() }
            Tab("Shift", systemImage: "heart.text.clipboard", value: AppTab.shift) { ShiftView() }
        }
        // Glove mode: larger text and controls everywhere, on top of the user's setting.
        .dynamicTypeSize(gloveMode ? .xxLarge ... .accessibility3 : .xSmall ... .accessibility5)
        .preferredColorScheme(appearance.colorScheme(for: store.airport, at: minute))
        .task { await store.autoRefresh() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                minute = .now
            }
        }
        .onChange(of: scenePhase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = keepAwake && phase == .active
            if phase == .active {
                minute = .now
                Task { await store.refresh() }
            }
        }
        .onChange(of: keepAwake) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
        .sensoryFeedback(.warning, trigger: store.rampStatus?.severity) { old, new in
            (new ?? .normal) > (old ?? .normal) && (new ?? .normal) >= .caution
        }
    }
}
