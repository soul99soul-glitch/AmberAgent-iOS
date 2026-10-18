import CoreLocation
import EventKit
import Contacts
import XCTest
@testable import iosApp

@MainActor
final class IOSPermissionScopeRegressionTests: XCTestCase {
    func testLocationStatusReflectsRequestedScopeAndPrecision() throws {
        let coordinator = IOSSystemPermissionCoordinator()
        let cases: [(String, CLAuthorizationStatus, CLAccuracyAuthorization, IOSSystemPermissionStatus)] = [
            ("ios.location.when_in_use", .authorizedWhenInUse, .reducedAccuracy, .authorized),
            ("ios.location.always", .authorizedWhenInUse, .fullAccuracy, .limited),
            ("ios.location.always", .authorizedAlways, .reducedAccuracy, .authorized),
            ("ios.location.temporary_precise", .authorizedWhenInUse, .reducedAccuracy, .limited),
            ("ios.location.temporary_precise", .authorizedAlways, .fullAccuracy, .authorized),
            ("ios.location.temporary_precise", .notDetermined, .fullAccuracy, .notDetermined),
            ("ios.location.temporary_precise", .restricted, .fullAccuracy, .restricted),
            ("ios.location.temporary_precise", .denied, .fullAccuracy, .denied)
        ]
        for (id, status, accuracy, expected) in cases {
            XCTAssertEqual(coordinator.mapCLAuthorizationStatus(
                status, for: try capability(id), accuracyAuthorization: accuracy
            ), expected, "\(id): \(status.rawValue) / \(accuracy.rawValue)")
        }
    }

    func testCalendarFullAccessDistinguishesWriteOnlyAuthorization() throws {
        let coordinator = IOSSystemPermissionCoordinator()
        let cases: [(String, EKAuthorizationStatus, IOSSystemPermissionStatus)] = [
            ("ios.calendar.full", .writeOnly, .limited),
            ("ios.calendar.write_only", .writeOnly, .authorized),
            ("ios.calendar.full", .fullAccess, .authorized),
            ("ios.calendar.write_only", .fullAccess, .authorized),
            ("ios.calendar.full", .notDetermined, .notDetermined),
            ("ios.calendar.full", .restricted, .restricted),
            ("ios.calendar.full", .denied, .denied),
            ("ios.reminders.full", .fullAccess, .authorized)
        ]
        for (id, status, expected) in cases {
            XCTAssertEqual(
                coordinator.mapEventKitStatus(status, for: try capability(id)),
                expected, "\(id): \(status.rawValue)"
            )
        }
    }

    func testContactsRequestCachesActualLimitedAndFullAuthorization() async throws {
        for (systemStatus, expected) in [
            (CNAuthorizationStatus.limited, IOSSystemPermissionStatus.limited),
            (.authorized, .authorized)
        ] {
            let coordinator = IOSSystemPermissionCoordinator()
            var requested = false
            var statusReads = 0
            coordinator.contactsAccessRequester = {
                requested = true
                return true
            }
            coordinator.contactsAuthorizationStatus = {
                XCTAssertTrue(requested, "Read the real status after the request completes")
                statusReads += 1
                return systemStatus
            }
            let contacts = try capability("ios.contacts.full")
            let result = await coordinator.request(contacts)
            XCTAssertTrue(requested)
            XCTAssertEqual(statusReads, 1)
            XCTAssertEqual(result.status, expected)
            XCTAssertEqual(coordinator.cachedStatus(for: contacts), result)
        }
    }

    private func capability(_ id: String) throws -> IOSPlatformCapability {
        try XCTUnwrap(IOSCapabilityRegistry.capabilities.first { $0.id == id })
    }
}
