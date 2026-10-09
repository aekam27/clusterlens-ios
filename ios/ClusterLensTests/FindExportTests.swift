import XCTest
#if SWIFT_PACKAGE
@testable import ClusterLensCore
#else
@testable import ClusterLens
#endif

final class FindExportTests: XCTestCase {
    func testTypedConditionsPreserveLargeIntegersAndRepeatedFields() throws {
        var minimum = FilterRule(); minimum.field = "amount"; minimum.type = .integer; minimum.value = "9007199254740993"; minimum.operation = .atLeast
        var maximum = minimum; maximum.value = "9007199254740995"; maximum.operation = .atMost
        let raw = try FindQuery.build(rules: [minimum, maximum], any: false)
        let query = try FindQuery(rawFilter: raw)
        XCTAssertEqual(query.filter["$and"], .array([try minimum.clause(), try maximum.clause()]))
        XCTAssertTrue(raw.contains("9007199254740993"))
        XCTAssertTrue(raw.contains("$numberLong"))
    }

    func testRawValidationAndProjectionRejectAmbiguity() throws {
        XCTAssertThrowsError(try FindQuery(rawFilter: "{\"a\":1,\"a\":2}"))
        XCTAssertThrowsError(try FindQuery(rawFilter: #"{"a":1,"\u0061":2}"#))
        XCTAssertNoThrow(try FindQuery(rawFilter: "{\"a\":{\"x\":1},\"b\":{\"x\":2}}"))
        XCTAssertThrowsError(try FindQuery(rawFilter: "{x: ObjectId('abc')}"))
        XCTAssertThrowsError(try FindQuery(rawFilter: "[]"))
        XCTAssertThrowsError(try FindQuery(rawFilter: "{\"$where\":\"return true\"}"))
        XCTAssertThrowsError(try FindQuery(rawFilter: "{\"$expr\":{\"$function\":{}}}"))
        for fields in ["a,a", "a,", "a..b", "$where", "a,a.b"] { XCTAssertThrowsError(try FindQuery(rawFilter: "{}", fields: fields)) }
        let query = try FindQuery(rawFilter: "{\"_id\":{\"$oid\":\"507f1f77bcf86cd799439011\"}}", fields: "customer.name, total", descending: true)
        XCTAssertEqual(query.input["projection"], .object(["customer.name": .integer(1), "total": .integer(1), "_id": .integer(0)]))
        XCTAssertEqual(query.input["sort"], .object(["_id": .integer(-1)]))
    }

    private func request(_ format: DataExportFormat, fields: String = "", rows: Int = 41) throws -> DataExportRequest {
        try DataExportRequest(connectionID: UUID(), database: "fixture", collection: "orders", query: FindQuery(rawFilter: "{}", fields: fields), format: format, rowLimit: rows)
    }

    func testJSONStreamsBeyondPreviewPageAndRetainsCanonicalBSON() throws {
        let writer = try DataExportWriter(request: request(.json))
        let document = JSONValue.object(["n": .object(["$numberLong": .string("9007199254740993")]), "decimal": .object(["$numberDecimal": .string("123.456")])])
        for _ in 0..<41 { try writer.write(document) }
        let result = try writer.finish(hasMore: false)
        defer { try? FileManager.default.removeItem(at: result.url) }
        let decoded = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: result.url))
        XCTAssertEqual(decoded, Array(repeating: document, count: 41))
        XCTAssertEqual(result.rows, 41)
        XCTAssertFalse(result.reachedRequestedLimit)
    }

    func testCSVSchemaEscapingFormulaGuardAndNestedValues() throws {
        let writer = try DataExportWriter(request: request(.csv, fields: "name, customer.city, n"))
        try writer.write(.object(["name": .string(" =SUM(1,2)\n\"test\""), "customer": .object(["city": .string("A,B")]), "n": .object(["$numberLong": .string("9007199254740993")])]))
        let result = try writer.finish(hasMore: false)
        defer { try? FileManager.default.removeItem(at: result.url) }
        let csv = try String(contentsOf: result.url, encoding: .utf8)
        XCTAssertTrue(csv.hasPrefix("\"name\",\"customer.city\",\"n\"\r\n"))
        XCTAssertTrue(csv.contains("\"' =SUM(1,2)\n\"\"test\"\"\""))
        XCTAssertTrue(csv.contains("\"A,B\""))
        XCTAssertTrue(csv.contains("$numberLong"))
        for value in ["=1+1", " +cmd", "-2", "@SUM(A1)", "\ttext", "\rtext"] { XCTAssertTrue(DataExportWriter.csvCell(value).hasPrefix("\"'")) }
        XCTAssertThrowsError(try DataExportWriter.value(at: "items.name", in: .object(["items": .array([])])))
    }

    func testExportLimitsAndIncompleteFileCleanup() throws {
        XCTAssertThrowsError(try request(.csv))
        XCTAssertThrowsError(try request(.json, rows: 0))
        XCTAssertThrowsError(try request(.json, rows: 10_001))
        var writer: DataExportWriter? = try DataExportWriter(request: request(.json, rows: 1))
        let partial = try XCTUnwrap(writer?.url)
        try writer?.write(.object(["ok": .bool(true)]))
        XCTAssertThrowsError(try writer?.write(.null))
        writer = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        let limited = try DataExportWriter(request: request(.json, rows: 1))
        try limited.write(.null)
        let result = try limited.finish(hasMore: true)
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertTrue(result.reachedRequestedLimit)
    }
    func testExportByteBudgetDiscardsPartialFile() throws {
        var writer: DataExportWriter? = try DataExportWriter(request: request(.json), byteLimit: 64)
        let url = try XCTUnwrap(writer?.url)
        XCTAssertThrowsError(try writer?.write(.string(String(repeating: "x", count: 80))))
        writer = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCollectionActionRequiresExactNamespaceAndRevocablePermit() throws {
        let connectionID = UUID(), authID = UUID()
        let authorization = WriteAuthorization(id: authID, connectionID: connectionID)
        for operation in [QueryOperation.createCollection, .dropCollection] {
            XCTAssertTrue(operation.isWrite)
            XCTAssertThrowsError(try QueryRequest(connectionID: connectionID, authorizationID: authID, database: "fixture", collection: "orders", operation: operation, sourceText: "{\"confirmNamespace\":\"other.orders\"}"))
            XCTAssertThrowsError(try QueryRequest(connectionID: connectionID, authorizationID: authID, database: "fixture", collection: "system.users", operation: operation, sourceText: "{\"confirmNamespace\":\"fixture.system.users\"}"))
        }
        let request = try QueryRequest(connectionID: connectionID, authorizationID: authID, database: "fixture", collection: "orders", operation: .dropCollection, sourceText: "{\"confirmNamespace\":\"fixture.orders\"}")
        let permit = try authorization.permit(for: request)
        let changed = try QueryRequest(connectionID: connectionID, authorizationID: authID, database: "fixture", collection: "other", operation: .dropCollection, sourceText: "{\"confirmNamespace\":\"fixture.other\"}")
        XCTAssertThrowsError(try permit.authorizeDispatch(for: changed))
        authorization.revoke()
        XCTAssertThrowsError(try permit.authorizeDispatch(for: request))
    }

    func testRawWorkbenchRejectsMisplacedFilterCodeAndCompoundSort() throws {
        for input in ["{\"status\":\"active\"}", "{\"filter\":null}", "{\"filter\":{\"$where\":\"true\"}}", "{\"sort\":{\"a\":1,\"b\":-1}}"] {
            XCTAssertThrowsError(try QueryRequest(connectionID: UUID(), authorizationID: nil, database: "fixture", collection: "orders", operation: .find, sourceText: input))
        }
    }

    #if !SWIFT_PACKAGE && DEBUG
    @MainActor
    func testSyntheticExportExceedsVisiblePageAndRejectsQueryEmulation() async throws {
        let model = AppModel(syntheticUI: true)
        await model.bootstrap()
        let id = try XCTUnwrap(model.activeProfileID)
        let request = try DataExportRequest(connectionID: id, database: "fixture_store", collection: "orders", query: FindQuery(rawFilter: "{}", fields: "item"), format: .json, rowLimit: 35)
        let result = try await model.exportData(request) { _, _ in }
        defer { try? FileManager.default.removeItem(at: result.url) }
        let rows = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: result.url))
        XCTAssertEqual(rows.count, 35)
        XCTAssertTrue(result.reachedRequestedLimit)
        XCTAssertEqual(rows.first, .object(["item": .string("Fixture order 1")]))
        XCTAssertEqual(rows.last, .object(["item": .string("Fixture order 35")]))
        let filtered = try DataExportRequest(connectionID: id, database: "fixture_store", collection: "orders", query: FindQuery(rawFilter: "{\"item\":\"no match\"}"), format: .json, rowLimit: 35)
        do { _ = try await model.exportData(filtered) { _, _ in }; XCTFail("Must not fake query semantics") } catch {}
        let task = Task { try await model.exportData(request) { _, _ in } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled export succeeded") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        XCTAssertFalse(model.writesUnlocked)
        XCTAssertThrowsError(try model.prepareQuery(database: "fixture_store", collection: "orders", operation: .dropCollection, sourceText: "{\"confirmNamespace\":\"fixture_store.orders\"}"))
    }
    #endif

    func testInvalidPreviewReplacementPreservesPageAndContinuation() throws {
        var preview = FindPreviewState<UUID>()
        let session = UUID()
        let first = preview.replace { session }.read
        let firstPage = CollectionPage(documents: [.integer(1)], hasMore: true, elapsedMS: 0)
        XCTAssertTrue(try preview.accept(firstPage, for: first))

        XCTAssertThrowsError(try preview.replace {
            _ = try FindQuery(rawFilter: "{invalid}")
            return UUID()
        })
        XCTAssertEqual(preview.session, session)
        XCTAssertEqual(preview.page?.documents, firstPage.documents)
        XCTAssertEqual(preview.pageNumber, 1)

        let next = try preview.next()
        XCTAssertEqual(next.session, session)
        XCTAssertFalse(next.startsCursor)
        XCTAssertNil(preview.page, "Loading releases the prior page to preserve the memory bound")
        XCTAssertTrue(try preview.accept(CollectionPage(documents: [.integer(2)], hasMore: false, elapsedMS: 0), for: next))
        XCTAssertEqual(preview.pageNumber, 2)
        XCTAssertThrowsError(try preview.next())
    }

    func testFailedPreparationDoesNotInvalidateAnInFlightPreview() throws {
        enum PreparationError: Error { case disconnected }
        var preview = FindPreviewState<UUID>()
        let first = preview.replace { UUID() }.read
        XCTAssertThrowsError(try preview.replace { throw PreparationError.disconnected })
        XCTAssertEqual(preview.session, first.session)
        XCTAssertTrue(try preview.accept(CollectionPage(documents: [.integer(1)], hasMore: true, elapsedMS: 0), for: first))
        XCTAssertEqual(preview.pageNumber, 1)
    }

    func testSupersededPreviewCannotPublishOrClearReplacement() throws {
        var preview = FindPreviewState<UUID>()
        let old = preview.replace { UUID() }.read
        let replacement = preview.replace { UUID() }
        XCTAssertEqual(replacement.retired, old.session)
        XCTAssertNotEqual(replacement.read.session, old.session)
        let invalidStalePage = CollectionPage(documents: Array(repeating: .null, count: 21), hasMore: true, elapsedMS: 0)
        XCTAssertFalse(try preview.accept(invalidStalePage, for: old), "Stale replies are ignored before page validation")
        XCTAssertFalse(preview.fail(old), "Late errors cannot retire the replacement session")
        XCTAssertEqual(preview.session, replacement.read.session)
        let currentPage = CollectionPage(documents: [.integer(2)], hasMore: false, elapsedMS: 0)
        XCTAssertTrue(try preview.accept(currentPage, for: replacement.read))
        XCTAssertFalse(try preview.accept(currentPage, for: old))
        XCTAssertFalse(try preview.accept(currentPage, for: replacement.read), "A completion publishes once")
        XCTAssertEqual(preview.page?.documents, [.integer(2)])
        XCTAssertEqual(preview.pageNumber, 1)
    }

    func testCancellationRevokesDeliveryBeforeCleanupAndRestart() throws {
        var preview = FindPreviewState<UUID>()
        let old = preview.replace { UUID() }.read
        XCTAssertEqual(preview.cancel(), old.session)
        XCTAssertNil(preview.session)
        XCTAssertNil(preview.page)
        let page = CollectionPage(documents: [.integer(1)], hasMore: true, elapsedMS: 0)
        XCTAssertFalse(try preview.accept(page, for: old))
        XCTAssertFalse(preview.fail(old))
        XCTAssertThrowsError(try preview.next())

        let replacement = preview.replace { UUID() }.read
        XCTAssertFalse(try preview.accept(page, for: old))
        XCTAssertFalse(preview.fail(old))
        XCTAssertTrue(try preview.accept(page, for: replacement))
        let continuation = try preview.next()
        _ = preview.cancel()
        XCTAssertFalse(try preview.accept(page, for: continuation))
        XCTAssertNil(preview.session)
        XCTAssertEqual(preview.pageNumber, 0)
    }

    #if !SWIFT_PACKAGE && DEBUG
    @MainActor
    func testNegativeControlClosingBeforeValidationLosesSyntheticContinuation() async throws {
        let model = AppModel(syntheticUI: true)
        await model.bootstrap()
        let session = try model.prepareBrowsing(database: "fixture_store", collection: "orders", query: FindQuery(rawFilter: "{}"))
        let firstPage = try await model.loadBrowsePage(session, start: true)
        XCTAssertTrue(firstPage.hasMore)

        // Replay the former UI ordering, without a real database: schedule the
        // close, reject invalid input, then let cleanup finish before Next page.
        let cleanup = Task { await model.closeBrowsing(session) }
        XCTAssertThrowsError(try model.prepareBrowsing(database: "fixture_store", collection: "orders", query: FindQuery(rawFilter: "{invalid}")))
        await cleanup.value
        do {
            _ = try await model.loadBrowsePage(session, start: false)
            XCTFail("The old ordering should lose its continuation cursor")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Synthetic cursor is closed.")
        }
    }

    @MainActor
    func testInvalidReplacementKeepsSyntheticCursorUsable() async throws {
        let model = AppModel(syntheticUI: true)
        await model.bootstrap()
        var preview = FindPreviewState<CollectionBrowseSession>()
        let first = try preview.replace {
            try model.prepareBrowsing(database: "fixture_store", collection: "orders", query: FindQuery(rawFilter: "{}"))
        }.read
        let firstPage = try await model.loadBrowsePage(first.session, start: first.startsCursor)
        XCTAssertTrue(try preview.accept(firstPage, for: first))

        XCTAssertThrowsError(try preview.replace {
            try model.prepareBrowsing(database: "fixture_store", collection: "orders", query: FindQuery(rawFilter: "{invalid}"))
        })
        XCTAssertEqual(preview.session?.id, first.session.id)
        let continuation = try preview.next()
        let nextPage = try await model.loadBrowsePage(continuation.session, start: continuation.startsCursor)
        XCTAssertTrue(try preview.accept(nextPage, for: continuation))
        XCTAssertEqual(preview.pageNumber, 2)
        XCTAssertEqual(nextPage.documents.count, 20)
        XCTAssertEqual(try DataExportWriter.value(at: "item", in: nextPage.documents[0]), .string("Fixture order 21"))
        await model.closeBrowsing(continuation.session)
    }
    #endif

}
