import XCTest
#if SWIFT_PACKAGE
@testable import ClusterLensCore
#else
@testable import ClusterLens
#endif

final class ResultProjectionTests: XCTestCase {
    func testNestedSelectionDistinguishesMissingNullAndArray() {
        let document = JSONValue.object(["customer": .object(["city": .string("Cedar Hill"), "phone": .null]),
                                         "items": .array([.object(["name": .string("Book")])])])
        XCTAssertEqual(ResultCell(ResultProjection.value(at: "customer.city", in: document)).text, "Cedar Hill")
        XCTAssertEqual(ResultCell(ResultProjection.value(at: "customer.phone", in: document)).type, "Null")
        XCTAssertFalse(ResultCell(ResultProjection.value(at: "customer.phone", in: document)).missing)
        XCTAssertTrue(ResultCell(ResultProjection.value(at: "customer.email", in: document)).missing)
        XCTAssertEqual(ResultCell(ResultProjection.value(at: "items", in: document)).text, "1 items")
        XCTAssertNil(ResultProjection.value(at: "items.name", in: document))
        XCTAssertNil(ResultProjection.value(at: "customer..city", in: document))
    }

    func testCanonicalBSONValuesRemainExactAndTyped() {
        for (key, value, expected) in [("$numberLong", "9007199254740993", "Int64"),
                                       ("$numberDecimal", "12345678901234567890.123456", "Decimal128"),
                                       ("$oid", "507f1f77bcf86cd799439011", "ObjectId")] {
            let cell = ResultCell(.object([key: .string(value)]))
            XCTAssertEqual(cell.text, value)
            XCTAssertEqual(cell.type, expected)
        }
        let date = ResultCell(.object(["$date": .object(["$numberLong": .string("1790000000000")])]))
        XCTAssertEqual(date.type, "Date")
        XCTAssertEqual(date.text, "1790000000000 ms since epoch")
        XCTAssertEqual(ResultCell(.string("null")).type, "Text")
        XCTAssertEqual(ResultCell(.bool(false)).text, "false")
    }

    func testLargeValuesAreSummarizedWithoutMutatingData() throws {
        let text = String(repeating: "🦉", count: 10_000)
        let document = JSONValue.object(["body": .string(text), "items": .array(Array(repeating: .null, count: 1000))])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(document)
        let cell = ResultCell(ResultProjection.value(at: "body", in: document))
        XCTAssertTrue(cell.truncated)
        XCTAssertEqual(cell.text, String(repeating: "🦉", count: 120) + "…")
        XCTAssertEqual(ResultCell(document).text, "2 fields")
        XCTAssertEqual(ResultCell(ResultProjection.value(at: "items", in: document)).type, "Array")
        XCTAssertEqual(try encoder.encode(document), before)
    }

    func testSuggestionsSampleNestedObjectsButNeverTraverseArraysOrBSONWrappers() {
        let documents: [JSONValue] = [.object([
            "customer": .object(["city": .string("Cedar Hill")]), "tags": .array([.string("Fictional")]),
            "quantity": .object(["$numberLong": .string("42")]), "literal.dot": .string("literal"), "$invalid": .null,
        ])]
        let fields = ResultProjection.suggestions(in: documents)
        XCTAssertEqual(fields, ["customer", "customer.city", "quantity", "tags"])
        XCTAssertFalse(fields.contains("quantity.$numberLong"))
        XCTAssertFalse(fields.contains("tags.0"))
        let wide = JSONValue.object(Dictionary(uniqueKeysWithValues: (0..<1000).map { ("field\($0)", JSONValue.null) }))
        XCTAssertLessThanOrEqual(ResultProjection.suggestions(in: Array(repeating: wide, count: 20)).count, 80)
    }

    func testSuggestedColumnsCanBeUsedForProjectionAndCSVWithoutChangingValues() throws {
        let suggestions = ["_id", "customer", "customer.city", "item", "quantity", "status", "tags"]
        let selected = ResultProjection.initialColumns(from: suggestions)
        XCTAssertEqual(selected, ["item", "status", "quantity", "customer.city"])
        let query = try FindQuery(rawFilter: "{}", fields: selected.joined(separator: ", "))
        XCTAssertEqual(query.fields, selected)
        let document = JSONValue.object(["item": .string("Fictional order"), "status": .null,
                                         "quantity": .object(["$numberLong": .string("9007199254740993")]),
                                         "customer": .object(["city": .string("Cedar Hill")])])
        for field in selected {
            XCTAssertEqual(ResultProjection.value(at: field, in: document), try DataExportWriter.value(at: field, in: document))
        }
        XCTAssertEqual(ResultProjection.initialColumns(from: []), ["_id"])
    }

    func testMatchedResultFormattingEvidence() throws {
        let payload = String(repeating: "Fictional document content. ", count: 4000)
        let documents: [JSONValue] = (1...20).map { index in
            .object(["item": .string("Cedar order \(index)"), "status": .string("Ready"),
                     "quantity": .integer(Int64(index)), "customer": .object(["city": .string("Cedar Hill")]), "payload": .string(payload)])
        }
        let columns = ["item", "status", "quantity", "customer.city"]
        var before: [Double] = [], after: [Double] = [], checksum = 0
        for _ in 0..<10 {
            var start = ProcessInfo.processInfo.systemUptime
            for document in documents {
                // Exact prior filtered-preview expressions: full JSON encoding twice.
                checksum += String(document.prettyPrinted.prefix(16_384)).utf8.count
                checksum += document.prettyPrinted.count > 16_384 ? 1 : 0
            }
            before.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            start = ProcessInfo.processInfo.systemUptime
            for document in documents {
                for column in columns { checksum += ResultCell(ResultProjection.value(at: column, in: document)).text.utf8.count }
            }
            after.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        XCTAssertGreaterThan(checksum, 0)
        let report: [String: Any] = ["scope": "Debug in-process formatting only; not end-to-end UI or network latency", "rows": 20, "columns": 4,
                                   "documentJSONBytes": try JSONEncoder().encode(documents).count, "baselineMS": before, "selectedFieldsMS": after]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("RESULT_FORMATTING_EVIDENCE " + String(decoding: data, as: UTF8.self))
    }
}
