import XCTest
@testable import ClusterLens

final class ClusterLensTests: XCTestCase {
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
