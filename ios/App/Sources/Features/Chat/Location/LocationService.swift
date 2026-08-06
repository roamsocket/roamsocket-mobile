import Foundation
import CoreLocation

/// One-shot location snapshot for chat context.
///
/// When Location is enabled in Add to Chat, a fresh fix (with optional reverse
/// geocode) is formatted into a system prompt so the model knows where the
/// user is without inventing a place.
@MainActor
final class LocationService: NSObject, ObservableObject {
    enum AuthorizationState: Equatable {
        case unknown
        case notDetermined
        case denied
        case restricted
        case authorized
    }

    @Published private(set) var authorizationState: AuthorizationState = .unknown
    @Published private(set) var lastError: String?

    private let manager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private static let geocoder = CLGeocoder()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        refreshAuthorizationState()
    }

    // MARK: - Availability / auth

    var isLocationServicesEnabled: Bool {
        CLLocationManager.locationServicesEnabled()
    }

    /// Refresh local auth state (does not prompt).
    func refreshAuthorizationState() {
        switch manager.authorizationStatus {
        case .notDetermined:
            authorizationState = .notDetermined
        case .restricted:
            authorizationState = .restricted
        case .denied:
            authorizationState = .denied
        case .authorizedAlways, .authorizedWhenInUse:
            authorizationState = .authorized
        @unknown default:
            authorizationState = .unknown
        }
    }

    /// Prompt the system location permission sheet when needed.
    func requestAuthorization() async throws {
        refreshAuthorizationState()
        guard isLocationServicesEnabled else {
            throw LocationServiceError.servicesDisabled
        }
        switch authorizationState {
        case .authorized:
            return
        case .denied, .restricted:
            throw LocationServiceError.denied
        case .notDetermined, .unknown:
            break
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Store as a one-shot auth wait via locationContinuation pattern
            // is awkward for Void; use a simple nested wait on status change.
            authWaiters.append(continuation)
            manager.requestWhenInUseAuthorization()
            // If status already resolved synchronously, finish immediately.
            DispatchQueue.main.async { [weak self] in
                self?.flushAuthWaitersIfResolved()
            }
        }
    }

    private var authWaiters: [CheckedContinuation<Void, Error>] = []

    private func flushAuthWaitersIfResolved() {
        refreshAuthorizationState()
        guard !authWaiters.isEmpty else { return }
        switch authorizationState {
        case .authorized:
            let waiters = authWaiters
            authWaiters.removeAll()
            waiters.forEach { $0.resume() }
        case .denied, .restricted:
            let waiters = authWaiters
            authWaiters.removeAll()
            waiters.forEach { $0.resume(throwing: LocationServiceError.denied) }
        case .notDetermined, .unknown:
            break
        }
    }

    // MARK: - Snapshot

    /// Build a prompt-ready location summary for the model.
    func snapshotForPrompt() async throws -> String {
        guard isLocationServicesEnabled else {
            throw LocationServiceError.servicesDisabled
        }
        if authorizationState != .authorized {
            try await requestAuthorization()
        }
        guard authorizationState == .authorized else {
            throw LocationServiceError.denied
        }

        let location = try await requestCurrentLocation()
        let place = await reverseGeocode(location)

        let now = Date()
        var lines: [String] = []
        lines.append("## User location snapshot")
        lines.append("Captured at: \(Self.iso.string(from: now))")
        lines.append("Privacy: The user chose to share their device location for this conversation only. Use it for local context (weather, nearby places, time zone, local units/currency hints). Do not invent a different location. Do not store or ask to re-share coordinates unless needed.")
        lines.append("")
        lines.append("### Coordinates")
        lines.append(String(format: "- Latitude: %.5f", location.coordinate.latitude))
        lines.append(String(format: "- Longitude: %.5f", location.coordinate.longitude))
        if location.horizontalAccuracy >= 0 {
            lines.append(String(format: "- Accuracy: ±%.0f m", location.horizontalAccuracy))
        }
        if location.altitude != 0 || location.verticalAccuracy >= 0 {
            lines.append(String(format: "- Altitude: %.0f m", location.altitude))
        }
        lines.append("- Timestamp: \(Self.iso.string(from: location.timestamp))")
        lines.append("")
        lines.append("### Place")
        if let place {
            lines.append(contentsOf: place.promptLines)
        } else {
            lines.append("- Reverse geocode: unavailable (use coordinates only)")
        }
        lines.append("")
        lines.append("### Device locale")
        lines.append("- Time zone: \(TimeZone.current.identifier)")
        if let region = Locale.current.region?.identifier {
            lines.append("- Region: \(region)")
        }
        lines.append("- Preferred languages: \(Locale.preferredLanguages.prefix(3).joined(separator: ", "))")

        return lines.joined(separator: "\n")
    }

    // MARK: - CoreLocation

    private func requestCurrentLocation() async throws -> CLLocation {
        if let existing = manager.location,
           abs(existing.timestamp.timeIntervalSinceNow) < 120,
           existing.horizontalAccuracy >= 0,
           existing.horizontalAccuracy < 500 {
            return existing
        }

        return try await withCheckedThrowingContinuation { continuation in
            if locationContinuation != nil {
                continuation.resume(throwing: LocationServiceError.requestInProgress)
                return
            }
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    private func reverseGeocode(_ location: CLLocation) async -> PlaceSummary? {
        do {
            let placemarks = try await Self.geocoder.reverseGeocodeLocation(location)
            guard let mark = placemarks.first else { return nil }
            return PlaceSummary(placemark: mark)
        } catch {
            return nil
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.refreshAuthorizationState()
            self.flushAuthWaitersIfResolved()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let cont = self.locationContinuation else { return }
            self.locationContinuation = nil
            if let best = locations.last {
                cont.resume(returning: best)
            } else {
                cont.resume(throwing: LocationServiceError.noFix)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.lastError = error.localizedDescription
            if let cont = self.locationContinuation {
                self.locationContinuation = nil
                cont.resume(throwing: error)
            }
            // Auth denial can surface here as well.
            self.flushAuthWaitersIfResolved()
        }
    }
}

// MARK: - Place formatting

private struct PlaceSummary {
    let name: String?
    let thoroughfare: String?
    let locality: String?
    let subLocality: String?
    let administrativeArea: String?
    let postalCode: String?
    let country: String?
    let isoCountryCode: String?
    let inlandWater: String?
    let ocean: String?

    init(placemark: CLPlacemark) {
        name = placemark.name
        thoroughfare = placemark.thoroughfare
        locality = placemark.locality
        subLocality = placemark.subLocality
        administrativeArea = placemark.administrativeArea
        postalCode = placemark.postalCode
        country = placemark.country
        isoCountryCode = placemark.isoCountryCode
        inlandWater = placemark.inlandWater
        ocean = placemark.ocean
    }

    var promptLines: [String] {
        var lines: [String] = []
        if let name, !name.isEmpty { lines.append("- Name: \(name)") }
        if let thoroughfare, !thoroughfare.isEmpty { lines.append("- Street: \(thoroughfare)") }
        if let subLocality, !subLocality.isEmpty { lines.append("- Area: \(subLocality)") }
        if let locality, !locality.isEmpty { lines.append("- City: \(locality)") }
        if let administrativeArea, !administrativeArea.isEmpty {
            lines.append("- Region/State: \(administrativeArea)")
        }
        if let postalCode, !postalCode.isEmpty { lines.append("- Postal code: \(postalCode)") }
        if let country, !country.isEmpty {
            let code = isoCountryCode.map { " (\($0))" } ?? ""
            lines.append("- Country: \(country)\(code)")
        }
        if let inlandWater, !inlandWater.isEmpty { lines.append("- Near water: \(inlandWater)") }
        if let ocean, !ocean.isEmpty { lines.append("- Ocean: \(ocean)") }
        if lines.isEmpty {
            lines.append("- Place details: unavailable")
        }
        return lines
    }
}

enum LocationServiceError: LocalizedError {
    case servicesDisabled
    case denied
    case noFix
    case requestInProgress

    var errorDescription: String? {
        switch self {
        case .servicesDisabled:
            return "Location Services are turned off on this device."
        case .denied:
            return "Location access was denied. Enable it in Settings → Privacy → Location Services."
        case .noFix:
            return "Could not determine your current location."
        case .requestInProgress:
            return "A location request is already in progress."
        }
    }
}
