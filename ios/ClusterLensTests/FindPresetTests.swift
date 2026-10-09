import XCTest
#if SWIFT_PACKAGE
@testable import ClusterLensCore
#else
@testable import ClusterLens
#endif
#if !SWIFT_PACKAGE && DEBUG
import SwiftUI
import UIKit
#endif

final class FindPresetTests: XCTestCase {
    private func context(connection: UUID = UUID(), database: String = "fixture", collection: String = "orders") -> FindPresetContext {
        FindPresetContext(connectionID: connection, database: database, collection: collection)
    }
    private func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClusterLensPresetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("saved-find-presets.json")
    }
    private func query() throws -> FindQuery {
        try FindQuery(rawFilter: "{\"amount\":{\"$gte\":{\"$numberLong\":\"9007199254740993\"}}}", fields: "amount, customer.name", descending: true)
    }

    func testMissingFileInitializesWithoutWritingAndPersistsExactSettings() throws {
        let url = try temporaryURL(), scope = context()
        let store = FindPresetStore(fileURL: url)
        try store.load()
        XCTAssertTrue(store.writesAllowed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let expected = try query()
        let saved = try store.save(name: "  High amounts  ", query: expected, in: scope)
        XCTAssertEqual(saved.name, "High amounts")
        let reloaded = FindPresetStore(fileURL: url)
        try reloaded.load()
        XCTAssertEqual(try reloaded.query(id: saved.id, in: scope), expected)
        XCTAssertEqual(reloaded.presets.count, 1)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["schemaVersion", "presets"])
        let record = try XCTUnwrap((root["presets"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(record.keys), ["id", "context", "name", "filterJSON", "fields", "descending"])
        // Simulator storage does not report iOS data-protection attributes.
        // The device assertion is retained for an authorized physical test run.
        #if os(iOS) && !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
        #endif
        XCTAssertEqual(try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testRenameDeleteAndDuplicateNamesAreScopedAndDurable() throws {
        let url = try temporaryURL(), scope = context()
        let store = FindPresetStore(fileURL: url); try store.load()
        let first = try store.save(name: "Daily", query: query(), in: scope)
        XCTAssertThrowsError(try store.save(name: "daily", query: query(), in: scope))
        let second = try store.save(name: "Weekly", query: query(), in: scope)
        XCTAssertThrowsError(try store.rename(id: first.id, in: scope, to: "Weekly"))
        try store.rename(id: first.id, in: scope, to: "Monthly")
        XCTAssertEqual(store.list(in: scope).map(\.name), ["Monthly", "Weekly"])
        try store.delete(id: second.id, in: scope)
        let reloaded = FindPresetStore(fileURL: url); try reloaded.load()
        XCTAssertEqual(reloaded.presets.map(\.id), [first.id])
        XCTAssertEqual(reloaded.presets.first?.name, "Monthly")
        XCTAssertEqual(try reloaded.query(id: first.id, in: scope), try query())
    }

    func testCrossConnectionDatabaseAndCollectionCannotReuseOrManagePreset() throws {
        let store = FindPresetStore(fileURL: nil); try store.load()
        let scope = context()
        let preset = try store.save(name: "Daily", query: query(), in: scope)
        let otherScopes = [context(), context(connection: scope.connectionID, database: "other"), context(connection: scope.connectionID, collection: "other")]
        for other in otherScopes {
            XCTAssertTrue(store.list(in: other).isEmpty)
            XCTAssertThrowsError(try store.query(id: preset.id, in: other))
            XCTAssertThrowsError(try store.rename(id: preset.id, in: other, to: "Renamed"))
            XCTAssertThrowsError(try store.delete(id: preset.id, in: other))
            XCTAssertNoThrow(try store.save(name: "Daily", query: query(), in: other))
        }
        XCTAssertEqual(store.list(in: scope).first?.name, "Daily")
    }

    func testRemovingConnectionPurgesOnlyItsPresetsAndPreservesCorruptStorage() throws {
        let url = try temporaryURL(), scope = context(), other = context()
        let store = FindPresetStore(fileURL: url); try store.load()
        try store.save(name: "Orders", query: query(), in: scope)
        try store.save(name: "Other namespace", query: query(), in: context(connection: scope.connectionID, collection: "other"))
        let retained = try store.save(name: "Other connection", query: query(), in: other)
        try store.removeConnection(scope.connectionID)
        let reloaded = FindPresetStore(fileURL: url); try reloaded.load()
        XCTAssertEqual(reloaded.presets, [retained])
        let corrupt = Data("{bad".utf8); try corrupt.write(to: url)
        XCTAssertThrowsError(try reloaded.load())
        XCTAssertThrowsError(try reloaded.removeConnection(other.connectionID))
        XCTAssertEqual(reloaded.presets, [retained])
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testInvalidNamesQueriesAndConnectionURIsAreRejected() throws {
        let store = FindPresetStore(fileURL: nil); try store.load()
        for name in ["", " \n ", "A\nB", String(repeating: "x", count: 81)] {
            XCTAssertThrowsError(try store.save(name: name, query: query(), in: context()))
        }
        let uriQuery = try FindQuery(rawFilter: "{\"uri\":\"mongodb://fixture:fictional@example.invalid\"}")
        XCTAssertThrowsError(try store.save(name: "URI", query: uriQuery, in: context()))
        XCTAssertThrowsError(try FindQuery(rawFilter: "{\"$where\":\"return true\"}"))
        XCTAssertThrowsError(try store.save(name: "Bad context", query: query(), in: context(database: "")))
        XCTAssertTrue(store.presets.isEmpty)
    }

    func testCorruptFutureAndDuplicateKeyFilesArePreservedWithoutWrites() throws {
        let url = try temporaryURL()
        for text in ["{bad", "", "{\"schemaVersion\":99,\"presets\":[]}", "{\"schemaVersion\":1,\"schemaVersion\":1,\"presets\":[]}", "{\"schemaVersion\":1,\"presets\":[],\"credentials\":\"unexpected\"}"] {
            let original = Data(text.utf8); try original.write(to: url)
            let store = FindPresetStore(fileURL: url)
            XCTAssertThrowsError(try store.load())
            XCTAssertFalse(store.writesAllowed)
            XCTAssertThrowsError(try store.save(name: "Never overwrite", query: query(), in: context()))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testCorruptPresetAndFailedReloadPreserveLastGoodSnapshot() throws {
        let url = try temporaryURL(), scope = context()
        let store = FindPresetStore(fileURL: url); try store.load()
        let original = try store.save(name: "Good", query: query(), in: scope)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var records = try XCTUnwrap(root["presets"] as? [[String: Any]])
        records[0]["filterJSON"] = "{\"$where\":\"true\"}"
        root["presets"] = records
        let corrupted = try JSONSerialization.data(withJSONObject: root); try corrupted.write(to: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(store.presets, [original])
        XCTAssertThrowsError(try store.rename(id: original.id, in: scope, to: "Not written"))
        XCTAssertThrowsError(try store.delete(id: original.id, in: scope))
        XCTAssertEqual(try Data(contentsOf: url), corrupted)
        try Data("{\"schemaVersion\":1,\"presets\":[]}".utf8).write(to: url)
        try store.load()
        XCTAssertTrue(store.writesAllowed)
        XCTAssertTrue(store.presets.isEmpty)
    }

    func testPresetCountByteBudgetAndWriteFailureDoNotMutateMemory() throws {
        let store = FindPresetStore(fileURL: nil); try store.load()
        let scope = context(), small = try FindQuery(rawFilter: "{}")
        for index in 0..<100 { try store.save(name: "Query \(index)", query: small, in: scope) }
        XCTAssertThrowsError(try store.save(name: "Over limit", query: small, in: scope))
        XCTAssertEqual(store.presets.count, 100)
        let url = try temporaryURL()
        let oversized = Data(repeating: 32, count: FindPresetStore.maximumBytes + 1); try oversized.write(to: url)
        let oversizedStore = FindPresetStore(fileURL: url)
        XCTAssertThrowsError(try oversizedStore.load())
        XCTAssertEqual(try Data(contentsOf: url), oversized)

        let failureURL = try temporaryURL().appendingPathComponent("child.json")
        let failedStore = FindPresetStore(fileURL: failureURL); try failedStore.load()
        try Data("not a directory".utf8).write(to: failureURL.deletingLastPathComponent())
        XCTAssertThrowsError(try failedStore.save(name: "Unwritten", query: small, in: scope))
        XCTAssertTrue(failedStore.presets.isEmpty)
    }

    #if !SWIFT_PACKAGE && DEBUG
    @MainActor
    func testSyntheticConnectionRemovalContinuesWhenPresetStorageIsCorrupt() async throws {
        let url = try temporaryURL(), store = FindPresetStore(fileURL: url)
        let model = AppModel(syntheticUI: true, presetStore: store)
        await model.bootstrap()
        let id = try XCTUnwrap(model.activeProfileID)
        try model.saveFindPreset(name: "Preserved on failed cleanup", query: query(), in: context(connection: id))
        let corrupted = Data("{bad".utf8); try corrupted.write(to: url)
        model.reloadFindPresets()
        XCTAssertNotNil(model.presetStorageError)
        await model.removeConnection(id)
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertNil(model.activeProfileID)
        XCTAssertTrue(model.globalError?.contains("saved queries could not be deleted") == true)
        XCTAssertEqual(try Data(contentsOf: url), corrupted)
        XCTAssertEqual(store.presets.count, 1)
    }

    // Review attachments exercise real SwiftUI layout in the hosted test app.
    // They are not gesture automation or a VoiceOver interaction test.
    @MainActor
    func testSavedQueryLayoutsForVisualReview() async throws {
        let model = AppModel(syntheticUI: true)
        await model.bootstrap()
        let scope = context(connection: try XCTUnwrap(model.activeProfileID), database: "fixture_store")
        try model.saveFindPreset(name: "High amounts — monthly review", query: query(), in: scope)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        for (label, size) in [("Default", DynamicTypeSize.large), ("Largest accessibility", .accessibility5)] {
            for savedList in [true, false] {
                let view: AnyView = savedList
                    ? AnyView(SavedFindPresetsView(context: scope) { _ in XCTFail("Layout must not load a preset") }.environmentObject(model).environment(\.dynamicTypeSize, size))
                    : AnyView(NavigationStack { FindWorkspaceView(database: scope.database, collection: scope.collection).environmentObject(model) }.environment(\.dynamicTypeSize, size))
                let controller = UIHostingController(rootView: view)
                window.rootViewController = controller
                window.makeKeyAndVisible()
                try await Task.sleep(nanoseconds: 400_000_000)
                controller.view.layoutIfNeeded()
                func capture(_ suffix: String) {
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "\(savedList ? "Saved queries" : "Find editor") — \(label)\(suffix)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                capture("")
                if size == .accessibility5 {
                    func scrollView(in view: UIView) -> UIScrollView? {
                        if let scroll = view as? UIScrollView { return scroll }
                        return view.subviews.compactMap { scrollView(in: $0) }.first
                    }
                    let scroll = try XCTUnwrap(scrollView(in: controller.view))
                    for step in 1...2 {
                        let maximum = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                        scroll.setContentOffset(CGPoint(x: 0, y: min(maximum, CGFloat(step) * window.bounds.height * 0.65)), animated: false)
                        try await Task.sleep(nanoseconds: 200_000_000)
                        capture(" — programmatic scroll \(step)")
                    }
                }
            }
        }
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertFalse(model.writesUnlocked)
    }

    @MainActor
    func testSyntheticPresetLoadingDoesNotRunQueryOrReplacePreview() async throws {
        let model = AppModel(syntheticUI: true)
        await model.bootstrap()
        let id = try XCTUnwrap(model.activeProfileID)
        let scope = context(connection: id, database: "fixture_store")
        let session = try model.prepareBrowsing(database: scope.database, collection: scope.collection, query: FindQuery(rawFilter: "{}"))
        _ = try await model.loadBrowsePage(session, start: true)
        try model.saveFindPreset(name: "Amounts", query: query(), in: scope)
        let preset = try XCTUnwrap(model.findPresets(in: scope).first)
        XCTAssertEqual(try model.loadFindPreset(id: preset.id, in: scope), try query())
        XCTAssertTrue(model.history.isEmpty, "Loading only returns settings; it must not execute a query")
        XCTAssertFalse(model.writesUnlocked)
        let continuation = try await model.loadBrowsePage(session, start: false)
        XCTAssertEqual(try DataExportWriter.value(at: "item", in: continuation.documents[0]), .string("Fixture order 21"))
        let other = context()
        XCTAssertThrowsError(try model.loadFindPreset(id: preset.id, in: other))
        XCTAssertThrowsError(try model.renameFindPreset(id: preset.id, in: other, to: "Wrong scope"))
        XCTAssertThrowsError(try model.deleteFindPreset(id: preset.id, in: other))
        try model.renameFindPreset(id: preset.id, in: scope, to: "Amounts renamed")
        try model.deleteFindPreset(id: preset.id, in: scope)
        XCTAssertTrue(model.savedFindPresets.isEmpty)
        await model.closeBrowsing(session)
        try model.saveFindPreset(name: "Removed with profile", query: query(), in: scope)
        await model.removeConnection(id)
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertTrue(model.savedFindPresets.isEmpty)
    }
    #endif
}
