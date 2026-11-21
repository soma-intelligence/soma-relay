import MapKit
import UIKit

/// MapKit snapshots for location bubbles, cached in memory. The pin is drawn by the bubble at
/// the centre (the region is centred on the coordinate).
enum MapSnapshots {
    private static var cache: [String: UIImage] = [:]

    static func key(lat: Double, lon: Double, size: CGSize, dark: Bool) -> String {
        String(format: "%.5f|%.5f|%.0fx%.0f|%d", lat, lon, size.width, size.height, dark ? 1 : 0)
    }

    static func cached(lat: Double, lon: Double, size: CGSize, dark: Bool) -> UIImage? {
        cache[key(lat: lat, lon: lon, size: size, dark: dark)]
    }

    static func image(lat: Double, lon: Double, size: CGSize, dark: Bool) async -> UIImage? {
        let key = key(lat: lat, lon: lon, size: size, dark: dark)
        if let hit = cache[key] { return hit }
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lon), latitudinalMeters: 700, longitudinalMeters: 700)
        options.size = size
        options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        options.pointOfInterestFilter = .excludingAll
        let snapshotter = MKMapSnapshotter(options: options)
        let image: UIImage? = await withCheckedContinuation { continuation in
            snapshotter.start(with: .main) { snapshot, _ in
                continuation.resume(returning: snapshot?.image)
            }
        }
        if let image {
            if cache.count > 60 { cache.removeAll() }
            cache[key] = image
        }
        return image
    }
}
