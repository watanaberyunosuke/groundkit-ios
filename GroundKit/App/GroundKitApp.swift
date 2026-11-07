import SwiftData
import SwiftUI

@main
struct GroundKitApp: App {
    @State private var store = AirportStore()
    @State private var health = HealthService()
    @State private var router = Router()
    @State private var layouts = LayoutStore()
    @State private var location = LocationTracker()
    @State private var account = AccountService()
    private let container = Persistence.makeContainer()

    var body: some Scene {
        #if os(macOS)
        // One main window: the tabs and the turnaround path are app-wide (Router).
        Window("GroundKit", id: "main") {
            withServices(RootView())
        }
        .modelContainer(container)
        .defaultSize(width: 1180, height: 820)
        .commands { GroundKitCommands(store: store, router: router) }

        Settings {
            withServices(SettingsView())
                .frame(width: 560, height: 680)
        }
        .modelContainer(container)
        #else
        WindowGroup {
            withServices(RootView())
        }
        .modelContainer(container)
        #endif
    }

    private func withServices(_ view: some View) -> some View {
        view
            .environment(store)
            .environment(health)
            .environment(router)
            .environment(layouts)
            .environment(location)
            .environment(account)
    }
}

#if os(macOS)
/// The Mac's View menu: the tabs (Command-1 to 4) and Refresh (Command-R).
struct GroundKitCommands: Commands {
    let store: AirportStore
    let router: Router

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Now") { router.tab = .now }.keyboardShortcut("1")
            Button("Flights") { router.tab = .flights }.keyboardShortcut("2")
            Button("Turnarounds") { router.tab = .turnarounds }.keyboardShortcut("3")
            Button("Shift") { router.tab = .shift }.keyboardShortcut("4")
            Divider()
            Button("Refresh") { Task { await store.refresh(force: true) } }.keyboardShortcut("r")
        }
    }
}
#endif

/// The four tabs, the same as the Android app's.
enum AppTab: Hashable {
    case now, flights, turnarounds, shift
}

/// Cross-tab navigation: "Start turnaround" on a board opens it in the Turnarounds tab, and
/// "See all" on Now opens Flights on arrivals or departures.
@Observable
final class Router {
    var tab: AppTab = .now
    var flightsDir: Direction = .inbound
    var turnaroundPath: [Turnaround] = []

    func showFlights(_ dir: Direction) {
        flightsDir = dir
        tab = .flights
    }

    func open(_ turnaround: Turnaround) {
        tab = .turnarounds
        turnaroundPath = [turnaround]
    }
}

struct RootView: View {
    @Environment(AirportStore.self) private var store
    @Environment(AccountService.self) private var account
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
            Tab("Now", systemImage: "clock", value: AppTab.now) { NowView() }
            Tab("Flights", systemImage: "airplane", value: AppTab.flights) { BoardView() }
            Tab("Turnarounds", systemImage: "checklist", value: AppTab.turnarounds) { TurnaroundListView() }
            Tab("Shift", systemImage: "heart.text.clipboard", value: AppTab.shift) { ShiftView() }
        }
        #if os(macOS)
        .tabViewStyle(.sidebarAdaptable)
        #endif
        // Glove mode: larger text and controls everywhere, on top of the user's setting.
        // iOS only: on the Mac the synced value is kept for the phone but not applied.
        #if os(iOS)
        .dynamicTypeSize(gloveMode ? .xxLarge ... .accessibility3 : .xSmall ... .accessibility5)
        #endif
        .preferredColorScheme(appearance.colorScheme(for: store.airport, at: minute))
        .task { await store.autoRefresh() }
        .task { account.attach(store) }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                minute = .now
            }
        }
        .onChange(of: scenePhase) { _, phase in
            ScreenAwake.set(keepAwake && phase == .active)
            if phase == .active {
                minute = .now
                Task { await store.refresh() }
                Task { await account.sync(ifStale: true) }
            }
        }
        .onChange(of: keepAwake) { _, on in ScreenAwake.set(on) }
        .sensoryFeedback(.warning, trigger: store.rampStatus?.severity) { old, new in
            (new ?? .normal) > (old ?? .normal) && (new ?? .normal) >= .caution
        }
    }
}
