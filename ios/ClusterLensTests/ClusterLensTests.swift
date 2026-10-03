import XCTest
#if SWIFT_PACKAGE
@testable import ClusterLensCore
#else
@testable import ClusterLens
#endif

final class ClusterLensTests: XCTestCase {
    #if !SWIFT_PACKAGE && DEBUG
    @MainActor
    func testSyntheticCoordinatorPagesWithoutConnectionsAndKeepsWritesLocked() async throws {
        let model = AppModel(syntheticUI: true)
        await model.bootstrap()
        XCTAssertTrue(model.isSyntheticUI)
        XCTAssertEqual(model.profiles.count, 1)
        XCTAssertEqual(model.databases.map(\.name), ["fixture_store"])
        XCTAssertFalse(model.writesUnlocked)
        let session = try model.prepareBrowsing(database: "fixture_store", collection: "orders")
        var all: [JSONValue] = []
        for pageIndex in 0..<3 {
            let page = try await model.loadBrowsePage(session, start: pageIndex == 0)
            try page.validate()
            XCTAssertEqual(page.documents.count, pageIndex == 2 ? 1 : 20)
            XCTAssertEqual(page.hasMore, pageIndex < 2)
            all += page.documents
        }
        XCTAssertEqual(all.count, 41)
        XCTAssertEqual(Set(all.map(\.prettyPrinted)).count, 41)
        do { _ = try await model.loadBrowsePage(session, start: false); XCTFail("Closed cursor reused") } catch {}
        do { try await model.unlockWrites(); XCTFail("Fixtures unlocked writes") } catch {}
        do { try await model.connect(name: "blocked", connectionString: "mongodb://example.invalid"); XCTFail("Fixture opened connection") } catch {}
        let id = try XCTUnwrap(model.activeProfileID)
        await model.disconnectSession(id)
        XCTAssertFalse(model.activeConnectionStatus.isConnected)
        await model.reconnect(id)
        XCTAssertTrue(model.activeConnectionStatus.isConnected)
        await model.removeConnection(id)
        XCTAssertTrue(model.profiles.isEmpty)
    }

    @MainActor
    func testSyntheticEmptyFailureCancellationAndReadHistory() async throws {
        let model = AppModel(syntheticUI: true)
        await model.bootstrap()
        let empty = try model.prepareBrowsing(database: "fixture_store", collection: "empty")
        let page = try await model.loadBrowsePage(empty, start: true)
        XCTAssertTrue(page.documents.isEmpty)
        XCTAssertFalse(page.hasMore)
        let failure = try model.prepareBrowsing(database: "fixture_store", collection: "error")
        do { _ = try await model.loadBrowsePage(failure, start: true); XCTFail("Expected fixture error") } catch {}
        let slow = try model.prepareBrowsing(database: "fixture_store", collection: "slow")
        let task = Task { try await model.loadBrowsePage(slow, start: true) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected: \(error)") }
        let request = try model.prepareQuery(database: "fixture_store", collection: "orders", operation: .find, sourceText: QueryOperation.find.template)
        let result = try await model.runQuery(request)
        XCTAssertTrue(result.result.prettyPrinted.contains("query semantics are not executed"))
        XCTAssertEqual(model.activeHistory.count, 1)
        model.clearHistory()
        XCTAssertTrue(model.activeHistory.isEmpty)
    }
    #endif

    #if !SWIFT_PACKAGE
    func testBundledCertificateAuthorityStoreIsPresent() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "cacert", withExtension: "pem"))
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("-----BEGIN CERTIFICATE-----"))
        XCTAssertTrue(contents.contains("-----END CERTIFICATE-----"))
    }

    #endif

    func testSavedConnectionMetadataContainsNoCredentials() throws {
        let profile = ConnectionProfile(
            id: UUID(uuidString: "B544DDC7-76C8-4515-9945-881E9784A9DA")!,
            name: "Production",
            host: "cluster.example.mongodb.net",
            usesSRV: true
        )
        let text = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        XCTAssertTrue(text.contains("cluster.example.mongodb.net"))
        XCTAssertFalse(text.contains("mongodb+srv://"))
        XCTAssertFalse(text.lowercased().contains("password"))
    }

    func testLegacyHistoryWithoutConnectionIDStillDecodes() throws {
        let source = """
        [{
          "id": "EFC54597-6AA1-4175-BF8A-A69EDE7DB0F4",
          "date": 0,
          "database": "app",
          "collection": "users",
          "operation": "find",
          "input": "{}",
          "elapsedMS": 4.2
        }]
        """
        let entries = try JSONDecoder().decode([QueryHistoryEntry].self, from: Data(source.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].connectionID)
    }

    func testConnectionStatusTracksIndependentLiveSessions() {
        let first = UUID()
        let second = UUID()
        let states: [UUID: ConnectionStatus] = [first: .connected, second: .saved]
        XCTAssertTrue(states[first]?.isConnected == true)
        XCTAssertFalse(states[second]?.isConnected == true)
    }

    func testEveryQueryTemplateIsAJSONObject() throws {
        for operation in QueryOperation.allCases {
            let data = try XCTUnwrap(operation.template.data(using: .utf8))
            let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
            XCTAssertFalse(decoded.isEmpty, "\(operation.title) should have a useful template")
        }
    }

    func testExtendedJSONRoundTrips() throws {
        let source = """
        {"_id":{"$oid":"507f1f77bcf86cd799439011"},"createdAt":{"$date":"2026-01-01T00:00:00Z"}}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: encoded), value)
    }

    func testWriteOperationsAreMarkedDestructive() {
        XCTAssertTrue(QueryOperation.insertOne.isWrite)
        XCTAssertTrue(QueryOperation.updateOne.isWrite)
        XCTAssertTrue(QueryOperation.deleteOne.isWrite)
        XCTAssertFalse(QueryOperation.find.isWrite)
        XCTAssertFalse(QueryOperation.aggregate.isWrite)
    }

    func testSRVRecordParsing() throws {
        let data = Data([
            0, 0, 0, 5, 0x69, 0x89,
            5, 115, 104, 97, 114, 100,
            7, 101, 120, 97, 109, 112, 108, 101,
            3, 99, 111, 109,
            0
        ])
        let record = try MongoConnectionString.parseSRVRecord(data)
        XCTAssertEqual(record.host, "shard.example.com")
        XCTAssertEqual(record.port, 27_017)
        XCTAssertEqual(record.weight, 5)
    }

    func testSRVConnectionStringExpansion() throws {
        let record = MongoSRVRecord(priority: 0, weight: 0, port: 27_017, host: "shard.example.com")
        let expanded = try MongoConnectionString.expand(
            "mongodb+srv://user:pass@cluster.example.com/app?retryWrites=true",
            records: [record],
            txtOptions: ["authSource=admin", "replicaSet=rs0"]
        )
        XCTAssertEqual(
            expanded,
            "mongodb://user:pass@shard.example.com:27017/app?authSource=admin&replicaSet=rs0&retryWrites=true&tls=true"
        )
    }

    func testConnectionSummaryNeverKeepsCredentials() throws {
        let summary = try MongoConnectionString.summary(
            for: "mongodb+srv://private-user:private-pass@cluster.example.com/app"
        )
        XCTAssertEqual(summary.host, "cluster.example.com")
        XCTAssertTrue(summary.usesSRV)
    }

    func testExplicitOptionsOverrideTXTDefaults() throws {
        let record = MongoSRVRecord(priority: 0, weight: 0, port: 27_017, host: "shard.example.com")
        let expanded = try MongoConnectionString.expand(
            "mongodb+srv://cluster.example.com/?authSource=users&tls=true",
            records: [record],
            txtOptions: ["authSource=admin"]
        )
        XCTAssertEqual(
            expanded,
            "mongodb://shard.example.com:27017/?authSource=users&tls=true"
        )
    }

    func testTLSIsAddedForBothSchemesAndExistingQueries() throws {
        for (source, expected) in [
            ("mongodb://example.com", "mongodb://example.com/?tls=true"),
            ("mongodb://example.com/app?", "mongodb://example.com/app?tls=true"),
            ("mongodb+srv://example.com/?authSource=admin", "mongodb+srv://example.com/?authSource=admin&tls=true"),
            ("mongodb://example.com/?SSL=true", "mongodb://example.com/?SSL=true")
        ] {
            XCTAssertEqual(try MongoConnectionString.requiringTLS(source), expected)
        }
    }

    func testTLSBypassesAreRejectedWithoutEchoingSecrets() {
        for option in ["tls=false", "ssl=false", "TLS=false", "tls=true&tls=false", "tlsInsecure=true",
                       "tlsAllowInvalidCertificates=true", "tlsAllowInvalidHostnames=true",
                       "tlsDisableOCSPEndpointCheck=true", "tlsDisableCertificateRevocationCheck=true",
                       "%74ls=false", "tlsAllowInvalidCertificates=1"] {
            XCTAssertThrowsError(try MongoConnectionString.requiringTLS("mongodb://secret:password@example.com/?" + option)) { error in
                XCTAssertFalse(error.localizedDescription.contains("password"))
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
    }

    func testSafeTLSOptionsAndEncodedCredentialsArePreserved() throws {
        let uri = "mongodb://user:p%40ss@example.com/?tls=true&tlsAllowInvalidCertificates=false"
        XCTAssertEqual(try MongoConnectionString.requiringTLS(uri), uri)
    }

    func testWriteAggregationIsRejectedIncludingNestedStages() throws {
        for source in [
            "{\"pipeline\":[{\"$out\":\"archive\"}]}",
            "{\"pipeline\":[{\"$merge\":{\"into\":\"archive\"}}]}",
            "{\"pipeline\":[{\"$facet\":{\"nested\":[{\"$merge\":\"archive\"}]}}]}"
        ] {
            let input = try JSONDecoder().decode([String: JSONValue].self, from: Data(source.utf8))
            XCTAssertThrowsError(try QuerySafety.validate(operation: .aggregate, input: input))
        }
        XCTAssertNoThrow(try QuerySafety.validate(operation: .aggregate, input: ["pipeline": .array([.object(["$match": .object([:])])])]))
        XCTAssertThrowsError(try QuerySafety.validate(operation: .aggregate, input: ["pipeline": .object([:])]))
    }

    func testUpdateAndDeleteRequireExplicitNonEmptyFilters() {
        for operation in [QueryOperation.updateOne, .deleteOne] {
            for input: [String: JSONValue] in [[:], ["filter": .null], ["filter": .object([:])], ["filter": .array([])]] {
                XCTAssertThrowsError(try QuerySafety.validate(operation: operation, input: input))
            }
            XCTAssertNoThrow(try QuerySafety.validate(operation: operation, input: ["filter": .object(["_id": .number(1)])]))
        }
        XCTAssertNoThrow(try QuerySafety.validate(operation: .find, input: ["filter": .object([:])]))
    }

    func testInvalidatedAndSupersededConnectionAttemptsCannotPublish() {
        var attempts = ConnectionAttempts()
        let firstID = UUID(), secondID = UUID()
        let old = attempts.begin(firstID)
        let second = attempts.begin(secondID)
        attempts.invalidate(firstID)
        XCTAssertFalse(attempts.isCurrent(old, for: firstID))
        let current = attempts.begin(firstID)
        XCTAssertFalse(attempts.isCurrent(old, for: firstID))
        XCTAssertTrue(attempts.isCurrent(current, for: firstID))
        XCTAssertTrue(attempts.isCurrent(second, for: secondID))
        let replacement = attempts.begin(firstID)
        XCTAssertFalse(attempts.isCurrent(current, for: firstID))
        XCTAssertTrue(attempts.isCurrent(replacement, for: firstID))
    }

    func testLargeIntegersAndCanonicalNumbersRemainExact() throws {
        for text in ["9007199254740993", "9223372036854775807", "-9223372036854775808"] {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            XCTAssertEqual(value, .integer(Int64(text)!))
            XCTAssertEqual(value.prettyPrinted, text)
        }
        for text in ["9223372036854775808", "-9223372036854775809", "1e100"] {
            XCTAssertThrowsError(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))
        }
        let text = "{\"large\":{\"$numberLong\":\"9223372036854775807\"},\"decimal\":{\"$numberDecimal\":\"1234567890.123456789012345678901234\"},\"double\":{\"$numberDouble\":\"NaN\"}}"
        let original = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(original.prettyPrinted.utf8)), original)
    }

    func testWritePermitIsBoundToSnapshotAndRevocableBeforeDispatch() throws {
        let connection = UUID(), generation = UUID()
        let authorization = WriteAuthorization(id: generation, connectionID: connection)
        var source = "{\"filter\":{\"_id\":9007199254740993}}"
        let request = try QueryRequest(connectionID: connection, authorizationID: generation,
                                       database: "fixtures", collection: "items", operation: .deleteOne, sourceText: source)
        source = "{\"filter\":{\"_id\":1}}"
        XCTAssertNotEqual(request.sourceText, source)
        XCTAssertEqual(request.input["filter"], .object(["_id": .integer(9007199254740993)]))
        let changed = try QueryRequest(connectionID: connection, authorizationID: generation,
                                       database: "fixtures", collection: "items", operation: .deleteOne, sourceText: source)
        let permit = try authorization.permit(for: request)
        XCTAssertThrowsError(try permit.authorizeDispatch(for: changed))
        XCTAssertNoThrow(try permit.authorizeDispatch(for: request))
        XCTAssertThrowsError(try permit.authorizeDispatch(for: request))
        let queued = try authorization.permit(for: changed)
        authorization.revoke()
        XCTAssertThrowsError(try queued.authorizeDispatch(for: changed))
        XCTAssertThrowsError(try authorization.permit(for: request))
        XCTAssertThrowsError(try WriteAuthorization(id: generation, connectionID: UUID()).permit(for: request))
        XCTAssertThrowsError(try WriteAuthorization(id: UUID(), connectionID: connection).permit(for: request))
    }

    func testCollectionWindowReplacesPagesAndRejectsStaleCompletions() throws {
        var window = CollectionPageWindow()
        let first = UUID()
        window.begin(first)
        for index in 1...1000 {
            window.releasePage()
            XCTAssertNil(window.page)
            let page = CollectionPage(documents: [.object(["_id": .integer(Int64(index))])], hasMore: true, elapsedMS: 1)
            XCTAssertTrue(try window.accept(page, sessionID: first))
            XCTAssertEqual(window.page?.documents.count, 1)
        }
        XCTAssertEqual(window.documentsSeen, 1000)
        XCTAssertEqual(window.pageNumber, 1000)
        let second = UUID()
        window.begin(second)
        let empty = CollectionPage(documents: [], hasMore: false, elapsedMS: 0)
        XCTAssertFalse(try window.accept(empty, sessionID: first))
        XCTAssertNil(window.page)
        XCTAssertTrue(try window.accept(empty, sessionID: second))
        window.close()
        XCTAssertNil(window.page)
        XCTAssertNil(window.sessionID)
    }

    func testCollectionPageLimitsAndExactCompactIdentifiers() throws {
        XCTAssertThrowsError(try CollectionPage(documents: Array(repeating: .object([:]), count: 21), hasMore: false, elapsedMS: 0).validate())
        XCTAssertThrowsError(try CollectionPage(documents: [], hasMore: true, elapsedMS: 0).validate())
        let huge = CollectionPage(documents: [.object(["payload": .string(String(repeating: "x", count: CollectionPage.maximumJSONBytes))])], hasMore: false, elapsedMS: 0)
        XCTAssertThrowsError(try huge.validate())
        XCTAssertEqual(JSONValue.object(["$numberLong": .string("9007199254740993")]).browseLabel, "9007199254740993")
        XCTAssertEqual(JSONValue.string(String(repeating: "x", count: 10000)).browseLabel.count, 120)
    }
}
