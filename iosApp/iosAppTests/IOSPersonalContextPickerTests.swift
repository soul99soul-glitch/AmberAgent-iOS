import Foundation
import Testing
import UniformTypeIdentifiers
@testable import iosApp

@Suite("Picker-first personal context")
@MainActor
struct IOSPersonalContextPickerTests {
    @Test func cancellationReturnsNoPersonalData() async {
        let coordinator = makeCoordinator()
        let task = Task { await coordinator.requestResult(toolName: "contacts_pick", input: "{}") }
        await Task.yield()

        coordinator.cancelActiveRequest()
        let output = await task.value

        #expect(output.json.contains("\"status\":\"cancelled\""))
        #expect(coordinator.activeRequest == nil)
    }

    @Test func emptySelectionIsExplicit() async {
        let coordinator = makeCoordinator()
        let task = Task { await coordinator.requestResult(toolName: "contacts_pick", input: "{}") }
        await Task.yield()

        coordinator.receiveContacts([])
        let output = await task.value

        #expect(output.json.contains("empty_selection"))
    }

    @Test func journalingFailsBeforePresentationWithoutEntitlement() async {
        let coordinator = makeCoordinator(journalingEntitlementAvailable: false)

        let output = await coordinator.requestResult(toolName: "journaling_suggestion_pick", input: "{}")

        #expect(output.json.contains("unavailable_entitlement"))
        #expect(coordinator.activeRequest == nil)
    }

    @Test func stalePhotoCopyCannotEnterProviderResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = IOSPersonalContextFileStore(rootURL: root)
        let coordinator = makeCoordinator(fileStore: fileStore)
        let task = Task { await coordinator.requestResult(toolName: "photos_pick", input: #"{"max_count":1}"#) }
        await Task.yield()
        let file = try fileStore.store(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            requestID: coordinator.activeRequest!.id,
            index: 0,
            contentType: .png,
            currentTotalBytes: 0
        )
        coordinator.receivePhotoFilesForTesting([file])
        try FileManager.default.removeItem(at: file.url)

        coordinator.confirmHandoff()
        let output = await task.value

        #expect(output.json.contains("stale_temporary_file"))
    }

    @Test func confirmedContactReturnsOnlySelectedFields() async {
        let coordinator = makeCoordinator()
        let task = Task { await coordinator.requestResult(toolName: "contacts_pick", input: #"{"max_count":2}"#) }
        await Task.yield()
        coordinator.receiveContacts([
            IOSSelectedContact(
                displayName: "Ada Lovelace",
                phoneNumbers: ["+44 20 1234"],
                emailAddresses: ["ada@example.com"]
            )
        ])

        coordinator.confirmHandoff()
        let output = await task.value
        let result = output.json

        #expect(result.contains("Ada Lovelace"))
        #expect(result.contains("ada@example.com"))
        #expect(result.contains("\"selected_count\":1"))
    }

    @Test func excessContactsAreTruncatedWithVisibleNotice() async {
        let coordinator = makeCoordinator()
        let task = Task { await coordinator.requestResult(toolName: "contacts_pick", input: #"{"max_count":1}"#) }
        await Task.yield()
        coordinator.receiveContacts([
            IOSSelectedContact(displayName: "Ada", phoneNumbers: ["1"], emailAddresses: []),
            IOSSelectedContact(displayName: "Grace", phoneNumbers: ["2"], emailAddresses: []),
        ])

        #expect(coordinator.preview?.notice?.contains("仅下列前 1 位") == true)
        #expect(coordinator.preview?.items.count == 1)
        coordinator.confirmHandoff()
        let output = await task.value

        #expect(output.json.contains("\"selected_count\":1"))
        #expect(!output.json.contains("Grace"))
    }

    @Test func confirmedPhotoProducesProviderDataURLWithoutLocalPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = IOSPersonalContextFileStore(rootURL: root)
        let coordinator = makeCoordinator(fileStore: fileStore)
        let task = Task { await coordinator.requestResult(toolName: "photos_pick", input: #"{"max_count":1}"#) }
        await Task.yield()
        let file = try fileStore.store(
            data: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            requestID: coordinator.activeRequest!.id,
            index: 0,
            contentType: .jpeg,
            currentTotalBytes: 0
        )
        coordinator.receivePhotoFilesForTesting([file])

        coordinator.confirmHandoff()
        let output = await task.value

        #expect(output.imageURLs.count == 1)
        #expect(output.imageURLs.first?.hasPrefix("data:image/jpeg;base64,") == true)
        #expect(!output.json.contains("file://"))
    }

    @Test func malformedPickerCountFailsClosed() async {
        let coordinator = makeCoordinator()

        let output = await coordinator.requestResult(toolName: "photos_pick", input: #"{"max_count":true}"#)

        #expect(output.json.contains("invalid_arguments"))
        #expect(coordinator.activeRequest == nil)
    }

    private func makeCoordinator(
        fileStore: IOSPersonalContextFileStore = IOSPersonalContextFileStore(
            rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        ),
        journalingEntitlementAvailable: Bool = true
    ) -> IOSPersonalContextPickerCoordinator {
        IOSPersonalContextPickerCoordinator(
            fileStore: fileStore,
            journalingEntitlementAvailable: { journalingEntitlementAvailable }
        )
    }
}
