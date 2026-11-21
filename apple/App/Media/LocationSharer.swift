import CoreLocation
import Foundation
import Observation

/// CoreLocation for the location sheet (one fix) and live sharing (spec v1.1 section 1): an
/// update at most every 10 s after 10 m of movement, a final `stop`, background updates only
/// while a live share runs.
@Observable
final class LocationSharer: NSObject, CLLocationManagerDelegate {
    private(set) var coordinate: CLLocationCoordinate2D?
    private(set) var accuracy: Double?
    private(set) var status: CLAuthorizationStatus
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var live = false
    @ObservationIgnored private var lastSent: (at: Date, location: CLLocation)?
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var denied: Bool { status == .denied || status == .restricted }

    /// Starts updates for the sheet (asks for when-in-use the first time).
    func startPreview() {
        if status == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }

    func stopPreview() {
        guard !live else { return }
        manager.stopUpdatingLocation()
    }

    func startLive() {
        live = true
        lastSent = nil
        manager.distanceFilter = 10
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.startUpdatingLocation()
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.expireShares()
            }
        }
    }

    func stopLive() {
        live = false
        watchdog?.cancel()
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func stopAll() {
        if let model { for id in model.liveShares.keys { model.stopLive(id) } }
        stopLive()
    }

    private func expireShares() {
        guard let model else { return }
        let now = Clock.nowMs
        for (id, share) in model.liveShares where share.until <= now { model.stopLive(id) }
    }

    private func received(_ location: CLLocation) {
        coordinate = location.coordinate
        accuracy = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
        guard live, let model else { return }
        if let lastSent {
            guard Date().timeIntervalSince(lastSent.at) >= 10, location.distance(from: lastSent.location) > 10 else { return }
        }
        lastSent = (Date(), location)
        model.sendLocationUpdate(.init(
            lat: location.coordinate.latitude, lon: location.coordinate.longitude, accuracyM: accuracy,
            heading: location.course >= 0 ? location.course : nil))
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.received(last) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.status = status
            if status == .authorizedWhenInUse || status == .authorizedAlways { self.manager.startUpdatingLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
