import SwiftUI
#if canImport(CoreLocation)
@preconcurrency import CoreLocation
#endif
#if canImport(CoreMotion)
@preconcurrency import CoreMotion
#endif

@MainActor
final class IOSMiniAppSystemBridge: NSObject, ObservableObject {
    #if canImport(CoreLocation)
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()
    private var locationContinuation: CheckedContinuation<IOSMiniAppJSONValue, Error>?
    #endif

    #if canImport(CoreMotion)
    private let motionManager = CMMotionManager()
    private var accelerometerHandlers: [String: (IOSMiniAppJSONValue) -> Void] = [:]
    private var gyroscopeHandlers: [String: (IOSMiniAppJSONValue) -> Void] = [:]
    private var sensorTypes: [String: String] = [:]
    #endif

    func currentLocation(accuracy: String) async throws -> IOSMiniAppJSONValue {
        #if canImport(CoreLocation)
        guard CLLocationManager.locationServicesEnabled() else {
            throw IOSMiniAppSystemBridgeError.unavailable("Location services are disabled.")
        }
        guard locationContinuation == nil else {
            throw IOSMiniAppSystemBridgeError.unavailable("Another location request is already running.")
        }
        locationManager.desiredAccuracy = accuracy == "fine" ? kCLLocationAccuracyBest : kCLLocationAccuracyKilometer
        return try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
            switch locationManager.authorizationStatus {
            case .notDetermined:
                locationManager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                locationManager.requestLocation()
            case .denied, .restricted:
                finishLocation(.failure(IOSMiniAppSystemBridgeError.unavailable("Location permission is not granted.")))
            @unknown default:
                finishLocation(.failure(IOSMiniAppSystemBridgeError.unavailable("Location authorization is unavailable.")))
            }
        }
        #else
        throw IOSMiniAppSystemBridgeError.unavailable("CoreLocation is unavailable on this device.")
        #endif
    }

    func subscribeSensor(
        subscriptionId: String,
        type: String,
        intervalMs: Int,
        onEvent: @escaping (IOSMiniAppJSONValue) -> Void
    ) throws {
        #if canImport(CoreMotion)
        let normalized = type
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let interval = TimeInterval(max(250, intervalMs)) / 1_000
        switch normalized {
        case "accelerometer", "accel":
            guard motionManager.isAccelerometerAvailable else {
                throw IOSMiniAppSystemBridgeError.unavailable("Accelerometer is unavailable.")
            }
            accelerometerHandlers[subscriptionId] = onEvent
            sensorTypes[subscriptionId] = "accelerometer"
            if motionManager.isAccelerometerActive {
                let current = motionManager.accelerometerUpdateInterval > 0
                    ? motionManager.accelerometerUpdateInterval
                    : interval
                motionManager.accelerometerUpdateInterval = min(current, interval)
            } else {
                motionManager.accelerometerUpdateInterval = interval
                motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
                    Task { @MainActor in
                        guard let self, let data, error == nil else { return }
                        let payload = self.sensorPayload(
                            type: "accelerometer",
                            x: data.acceleration.x,
                            y: data.acceleration.y,
                            z: data.acceleration.z
                        )
                        self.accelerometerHandlers.values.forEach { $0(payload) }
                    }
                }
            }
        case "gyroscope", "gyro":
            guard motionManager.isGyroAvailable else {
                throw IOSMiniAppSystemBridgeError.unavailable("Gyroscope is unavailable.")
            }
            gyroscopeHandlers[subscriptionId] = onEvent
            sensorTypes[subscriptionId] = "gyroscope"
            if motionManager.isGyroActive {
                let current = motionManager.gyroUpdateInterval > 0
                    ? motionManager.gyroUpdateInterval
                    : interval
                motionManager.gyroUpdateInterval = min(current, interval)
            } else {
                motionManager.gyroUpdateInterval = interval
                motionManager.startGyroUpdates(to: .main) { [weak self] data, error in
                    Task { @MainActor in
                        guard let self, let data, error == nil else { return }
                        let payload = self.sensorPayload(
                            type: "gyroscope",
                            x: data.rotationRate.x,
                            y: data.rotationRate.y,
                            z: data.rotationRate.z
                        )
                        self.gyroscopeHandlers.values.forEach { $0(payload) }
                    }
                }
            }
        case "light", "ambientlight", "ambient-light", "illuminance":
            throw IOSMiniAppSystemBridgeError.unavailable("Ambient light sensor is unavailable on iOS.")
        default:
            throw IOSMiniAppSystemBridgeError.unavailable("Unsupported sensor type.")
        }
        #else
        throw IOSMiniAppSystemBridgeError.unavailable("CoreMotion is unavailable on this device.")
        #endif
    }

    func unsubscribeSensor(subscriptionId: String) {
        #if canImport(CoreMotion)
        let type = sensorTypes.removeValue(forKey: subscriptionId)
        accelerometerHandlers.removeValue(forKey: subscriptionId)
        gyroscopeHandlers.removeValue(forKey: subscriptionId)
        if type == "accelerometer", accelerometerHandlers.isEmpty {
            motionManager.stopAccelerometerUpdates()
        }
        if type == "gyroscope", gyroscopeHandlers.isEmpty {
            motionManager.stopGyroUpdates()
        }
        #endif
    }

    func close() {
        #if canImport(CoreLocation)
        finishLocation(.failure(CancellationError()))
        locationManager.stopUpdatingLocation()
        #endif
        #if canImport(CoreMotion)
        motionManager.stopAccelerometerUpdates()
        motionManager.stopGyroUpdates()
        accelerometerHandlers.removeAll()
        gyroscopeHandlers.removeAll()
        sensorTypes.removeAll()
        #endif
    }

    #if canImport(CoreMotion)
    private func sensorPayload(type: String, x: Double, y: Double, z: Double) -> IOSMiniAppJSONValue {
        .object([
            "sensorType": .string(type),
            "timestamp": .number(Date().timeIntervalSince1970 * 1_000),
            "x": .number(x),
            "y": .number(y),
            "z": .number(z),
        ])
    }
    #endif

    #if canImport(CoreLocation)
    private func finishLocation(_ result: Result<IOSMiniAppJSONValue, Error>) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        continuation.resume(with: result)
    }
    #endif
}

#if canImport(CoreLocation)
extension IOSMiniAppSystemBridge: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard locationContinuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finishLocation(.failure(IOSMiniAppSystemBridgeError.unavailable("Location permission is not granted.")))
        case .notDetermined:
            break
        @unknown default:
            finishLocation(.failure(IOSMiniAppSystemBridgeError.unavailable("Location authorization is unavailable.")))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finishLocation(.failure(IOSMiniAppSystemBridgeError.unavailable("Location is unavailable.")))
            return
        }
        finishLocation(.success(.object([
            "latitude": .number(location.coordinate.latitude),
            "longitude": .number(location.coordinate.longitude),
            "accuracy": .number(location.horizontalAccuracy),
            "provider": .string("core-location"),
            "timestamp": .number(location.timestamp.timeIntervalSince1970 * 1_000),
        ])))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finishLocation(.failure(error))
    }
}
#endif

private enum IOSMiniAppSystemBridgeError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        if case .unavailable(let message) = self { return message }
        return nil
    }
}
