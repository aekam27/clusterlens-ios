import Foundation

// Executable policy checks for hosts with Swift but no XCTest/Xcode installation.
@main
struct FoundationChecks {
    static func expectFailure(_ action: () throws -> Void) {
        do {
            try action()
            fatalError("Expected a policy rejection")
        } catch {
            precondition(!error.localizedDescription.contains("private-password"))
        }
    }

    static func input(_ json: String) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
    }

    static func tryAccept(_ window: inout CollectionPageWindow, _ page: CollectionPage, _ session: UUID) -> Bool {
        do { return try window.accept(page, sessionID: session) }
        catch { fatalError("Unexpected page rejection: \(error)") }
    }

    static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--validate-browse-fixture" {
            let source = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            let page = try JSONDecoder().decode(CollectionPage.self, from: source)
            try page.validate()
            precondition(page.hasMore && page.documents.count == 20)
            for (index, document) in page.documents.enumerated() {
                guard case .object(let fields) = document else { fatalError("Expected document") }
                precondition(fields["_id"] == .object(["$numberLong": .string(String(9007199254740993 + index / 3))]))
                precondition(fields["ordinal"] == .object(["$numberInt": .string(String(index))]))
            }
            print("PASS: native page -> Swift decoding preserves ordered duplicate boundaries and exact _id values")
            return
        }
        if CommandLine.arguments.count == 3 {
            let source = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let value = try JSONDecoder().decode(JSONValue.self, from: source)
            try Data(value.prettyPrinted.utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            print("PASS: native numeric fixture decoded and re-encoded through Swift")
            return
        }
        for option in ["tls=false", "ssl=false", "TLS=false", "%74ls=false", "tls=true&tls=false",
                       "tlsInsecure=true", "tlsAllowInvalidCertificates=true", "tlsAllowInvalidHostnames=true",
                       "tlsDisableCertificateRevocationCheck=true", "tlsDisableOCSPEndpointCheck=true",
                       "tlsAllowInvalidCertificates=1"] {
            expectFailure { _ = try MongoConnectionString.requiringTLS("mongodb://user:private-password@example.invalid/?" + option) }
        }
        for (source, expected) in [
            ("mongodb://example.invalid", "mongodb://example.invalid/?tls=true"),
            ("mongodb://example.invalid/db?", "mongodb://example.invalid/db?tls=true"),
            ("mongodb+srv://example.invalid/?authSource=admin", "mongodb+srv://example.invalid/?authSource=admin&tls=true"),
            ("mongodb://example.invalid/?SSL=true", "mongodb://example.invalid/?SSL=true")
        ] {
            let actual = try MongoConnectionString.requiringTLS(source)
            precondition(actual == expected)
        }
        let safe = "mongodb://user:p%40ss@example.invalid/?tls=true&tlsAllowInvalidCertificates=false"
        let actual = try MongoConnectionString.requiringTLS(safe)
        precondition(actual == safe)
        print("PASS: TLS defaults, overrides, encoded options, credential-safe failures")

        for json in [
            "{\"pipeline\":[{\"$out\":\"archive\"}]}",
            "{\"pipeline\":[{\"$merge\":{\"into\":\"archive\"}}]}",
            "{\"pipeline\":[{\"$facet\":{\"nested\":[{\"$merge\":\"archive\"}]}}]}",
            "{\"pipeline\":{}}"
        ] {
            let parsed = try input(json)
            expectFailure { try QuerySafety.validate(operation: .aggregate, input: parsed) }
        }
        try QuerySafety.validate(operation: .aggregate, input: input("{\"pipeline\":[{\"$match\":{}},{\"$limit\":20}]}"))
        print("PASS: read-only aggregation including nested output stages")

        for operation in [QueryOperation.updateOne, .deleteOne] {
            for json in ["{}", "{\"filter\":{}}", "{\"filter\":null}", "{\"filter\":[]}"] {
                let parsed = try input(json)
                expectFailure { try QuerySafety.validate(operation: operation, input: parsed) }
            }
            try QuerySafety.validate(operation: operation, input: input("{\"filter\":{\"_id\":42}}"))
        }
        try QuerySafety.validate(operation: .find, input: input("{\"filter\":{}}"))
        print("PASS: update/delete filter guards without blocking empty read filters")

        var attempts = ConnectionAttempts()
        let first = UUID(), second = UUID()
        let stale = attempts.begin(first), other = attempts.begin(second)
        attempts.invalidate(first)
        precondition(!attempts.isCurrent(stale, for: first))
        let next = attempts.begin(first)
        precondition(!attempts.isCurrent(stale, for: first))
        precondition(attempts.isCurrent(next, for: first))
        precondition(attempts.isCurrent(other, for: second))
        _ = attempts.begin(first)
        precondition(!attempts.isCurrent(next, for: first))
        print("PASS: disconnected, replaced, and independent connection attempts")

        for operation in QueryOperation.allCases {
            try QuerySafety.validate(operation: operation, input: input(operation.template))
        }
        let original = try input("{\"_id\":{\"$oid\":\"507f1f77bcf86cd799439011\"},\"date\":{\"$date\":\"2026-01-01T00:00:00Z\"}}")
        let roundTrip = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(original))
        precondition(original == roundTrip)
        print("PASS: query templates and Extended JSON fixtures")

        let record = MongoSRVRecord(priority: 0, weight: 0, port: 27017, host: "shard.example.invalid")
        let expanded = try MongoConnectionString.expand("mongodb+srv://user:p%40ss@cluster.example.invalid/?authSource=users", records: [record], txtOptions: ["authSource=admin", "tls=false"])
        precondition(expanded == "mongodb://user:p%40ss@shard.example.invalid:27017/?authSource=users&tls=true")
        let summary = try MongoConnectionString.summary(for: expanded)
        precondition(summary.host == "shard.example.invalid")
        print("PASS: synthetic SRV expansion, TXT filtering, credential-free summaries")

        for number in ["9007199254740993", "9223372036854775807", "-9223372036854775808"] {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(number.utf8))
            precondition(value == .integer(Int64(number)!))
            precondition(value.prettyPrinted == number)
        }
        for number in ["9223372036854775808", "-9223372036854775809", "1e100"] {
            expectFailure { _ = try JSONDecoder().decode(JSONValue.self, from: Data(number.utf8)) }
        }
        let canonical = try input("{\"large\":{\"$numberLong\":\"9223372036854775807\"},\"decimal\":{\"$numberDecimal\":\"1234567890.123456789012345678901234\"},\"double\":{\"$numberDouble\":\"NaN\"}}")
        let canonicalRoundTrip = try input(JSONValue.object(canonical).prettyPrinted)
        precondition(canonical == canonicalRoundTrip)
        print("PASS: exact Int64 boundaries, explicit out-of-range rejection, canonical numeric strings")

        let connection = UUID(), generation = UUID()
        let authorization = WriteAuthorization(id: generation, connectionID: connection)
        var editor = "{\"filter\":{\"_id\":9007199254740993}}"
        let request = try QueryRequest(connectionID: connection, authorizationID: generation,
                                       database: "fixtures", collection: "items", operation: .deleteOne, sourceText: editor)
        editor = "{\"filter\":{\"_id\":1}}"
        precondition(request.sourceText != editor)
        precondition(request.input["filter"] == .object(["_id": .integer(9007199254740993)]))
        let permit = try authorization.permit(for: request)
        let changed = try QueryRequest(connectionID: connection, authorizationID: generation,
                                       database: "fixtures", collection: "items", operation: .deleteOne, sourceText: editor)
        expectFailure { try permit.authorizeDispatch(for: changed) }
        try permit.authorizeDispatch(for: request)
        expectFailure { try permit.authorizeDispatch(for: request) }
        let queued = try authorization.permit(for: changed)
        authorization.revoke()
        expectFailure { try queued.authorizeDispatch(for: changed) }
        expectFailure { _ = try authorization.permit(for: request) }
        let wrongConnection = WriteAuthorization(id: generation, connectionID: UUID())
        expectFailure { _ = try wrongConnection.permit(for: request) }
        let newSession = WriteAuthorization(id: UUID(), connectionID: connection)
        expectFailure { _ = try newSession.permit(for: request) }
        print("PASS: immutable query snapshots, exact target, one-shot permit, relock and session revocation")

        var window = CollectionPageWindow()
        let browseID = UUID()
        window.begin(browseID)
        let firstPage = CollectionPage(documents: [.object(["_id": .object(["$numberLong": .string("9007199254740993")])])], hasMore: true, elapsedMS: 1)
        precondition(tryAccept(&window, firstPage, browseID))
        for pageIndex in 2...1000 {
            window.releasePage()
            precondition(window.page == nil)
            let nextPage = CollectionPage(documents: [.object(["_id": .integer(Int64(pageIndex))])], hasMore: true, elapsedMS: 1)
            precondition(tryAccept(&window, nextPage, browseID))
            precondition(window.page?.documents.count == 1 && window.pageNumber == pageIndex)
        }
        let replacement = UUID()
        window.begin(replacement)
        precondition(!tryAccept(&window, firstPage, browseID))
        precondition(window.page == nil && window.documentsSeen == 0)
        let empty = CollectionPage(documents: [], hasMore: false, elapsedMS: 1)
        precondition(tryAccept(&window, empty, replacement))
        expectFailure { try CollectionPage(documents: Array(repeating: .object([:]), count: 21), hasMore: false, elapsedMS: 0).validate() }
        expectFailure { try CollectionPage(documents: [], hasMore: true, elapsedMS: 0).validate() }
        let tooLarge = CollectionPage(documents: [.object(["payload": .string(String(repeating: "x", count: CollectionPage.maximumJSONBytes))])], hasMore: false, elapsedMS: 0)
        expectFailure { try tooLarge.validate() }
        window.close()
        precondition(window.page == nil && window.sessionID == nil)
        precondition(JSONValue.object(["$numberLong": .string("9007199254740993")]).browseLabel == "9007199254740993")
        precondition(JSONValue.string(String(repeating: "x", count: 10000)).browseLabel.count == 120)
        print("PASS: one-page retention across 1000 pages, stale-session rejection, limits and lazy row labels")
    }
}
