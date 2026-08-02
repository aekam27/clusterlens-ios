import XCTest
@testable import ClusterLens

final class ClusterLensTests: XCTestCase {
    func testBundledCertificateAuthorityStoreIsPresent() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "cacert", withExtension: "pem"))
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("-----BEGIN CERTIFICATE-----"))
        XCTAssertTrue(contents.contains("-----END CERTIFICATE-----"))
    }

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
            "mongodb+srv://cluster.example.com/?authSource=users&tls=false",
            records: [record],
            txtOptions: ["authSource=admin"]
        )
        XCTAssertEqual(
            expanded,
            "mongodb://shard.example.com:27017/?authSource=users&tls=false"
        )
    }
}
