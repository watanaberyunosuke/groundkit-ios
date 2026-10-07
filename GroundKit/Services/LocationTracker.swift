import CoreLocation
import Observation

/// Where you are, for the maps: distances and routes to places on the airport. Runs only
/// while a map is on screen, and only after you allow it from the map. Nothing is stored
/// or sent anywhere.
@Observable
final class LocationTracker: NSObject, CLLocationManagerDelegate {
    nonisolated struct Fix: Equatable, Sendable {
        var lat: Double
        var lon: Double
        var accuracyM: Double
    }

    private(set) var fix: Fix?
    private(set) var authorization: CLAuthorizationStatus
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var wanted = false

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    var isAllowed: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    /// Asks for permission the first time; starts updates once allowed.
    func request() {
        wanted = true
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() } else { start() }
    }

    func start() {
        wanted = true
        if isAllowed { manager.startUpdatingLocation() }
    }

    func stop() {
        wanted = false
        manager.stopUpdatingLocation()
    }

    // The manager calls back on the main thread, where it was created.

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            authorization = status
            if wanted { start() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0 else { return }
        let fix = Fix(lat: l.coordinate.latitude, lon: l.coordinate.longitude, accuracyM: l.horizontalAccuracy)
        MainActor.assumeIsolated { self.fix = fix }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
