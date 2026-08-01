import Foundation
import dnssd

struct MongoConnectionSummary {
    let host: String
    let usesSRV: Bool
}

struct MongoSRVRecord: Equatable {
    let priority: UInt16
    let weight: UInt16
    let port: UInt16
    let host: String
}

enum MongoConnectionError: LocalizedError {
    case invalid(String)
    case dns(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .dns(let message): message
        }
    }
}

struct MongoConnectionString {
    static func summary(for rawValue: String) throws -> MongoConnectionSummary {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix: String
        let usesSRV: Bool
        if value.lowercased().hasPrefix("mongodb+srv://") {
            prefix = "mongodb+srv://"
            usesSRV = true
        } else if value.lowercased().hasPrefix("mongodb://") {
            prefix = "mongodb://"
            usesSRV = false
        } else {
            throw MongoConnectionError.invalid("Connection strings must start with mongodb:// or mongodb+srv://.")
        }

        let remainder = String(value.dropFirst(prefix.count))
        let authority = remainder.prefix { !["/", "?", "#"].contains($0) }
        let hostSection = authority.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let firstHost = hostSection.split(separator: ",").first.map(String.init) ?? ""
        let host = firstHost.split(separator: ":").first.map(String.init) ?? ""
        guard !host.isEmpty else {
            throw MongoConnectionError.invalid("The connection string does not contain a cluster host.")
        }
        if usesSRV && (hostSection.contains(",") || firstHost.contains(":")) {
            throw MongoConnectionError.invalid("mongodb+srv connection strings must contain one hostname and no port.")
        }
        return MongoConnectionSummary(host: host.lowercased(), usesSRV: usesSRV)
    }

    static func expanded(_ rawValue: String, resolver: DNSRecordResolving = SystemDNSResolver()) async throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = try summary(for: value)
        guard summary.usesSRV else { return value }

        let srvName = "_mongodb._tcp.\(summary.host)"
        let srvData = try await resolver.query(name: srvName, type: UInt16(kDNSServiceType_SRV))
        let srvRecords = try srvData.map(parseSRVRecord).sorted {
            ($0.priority, $0.weight, $0.host) < ($1.priority, $1.weight, $1.host)
        }
        guard !srvRecords.isEmpty else {
            throw MongoConnectionError.dns("No MongoDB SRV records were found for \(summary.host).")
        }

        try validate(records: srvRecords, seedHost: summary.host)
        let txtData = (try? await resolver.query(name: summary.host, type: UInt16(kDNSServiceType_TXT))) ?? []
        let txtOptions = try txtData.flatMap(parseTXTRecord)
        return try expand(value, records: srvRecords, txtOptions: txtOptions)
    }

    static func parseSRVRecord(_ data: Data) throws -> MongoSRVRecord {
        let bytes = [UInt8](data)
        guard bytes.count >= 7 else {
            throw MongoConnectionError.dns("The cluster returned a malformed SRV record.")
        }

        func word(at index: Int) -> UInt16 {
            UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
        }

        var index = 6
        var labels: [String] = []
        while index < bytes.count {
            let length = Int(bytes[index])
            index += 1
            if length == 0 { break }
            guard length <= 63, index + length <= bytes.count else {
                throw MongoConnectionError.dns("The cluster returned a malformed SRV hostname.")
            }
            guard let label = String(bytes: bytes[index..<(index + length)], encoding: .utf8) else {
                throw MongoConnectionError.dns("The cluster returned an invalid SRV hostname.")
            }
            labels.append(label)
            index += length
        }
        guard !labels.isEmpty else {
            throw MongoConnectionError.dns("The cluster SRV record did not include a hostname.")
        }
        return MongoSRVRecord(
            priority: word(at: 0),
            weight: word(at: 2),
            port: word(at: 4),
            host: labels.joined(separator: ".").lowercased()
        )
    }

    static func parseTXTRecord(_ data: Data) throws -> [String] {
        let bytes = [UInt8](data)
        var index = 0
        var strings: [String] = []
        while index < bytes.count {
            let length = Int(bytes[index])
            index += 1
            guard index + length <= bytes.count,
                  let value = String(bytes: bytes[index..<(index + length)], encoding: .utf8) else {
                throw MongoConnectionError.dns("The cluster returned a malformed TXT record.")
            }
            strings.append(contentsOf: value.split(separator: "&").map(String.init))
            index += length
        }
        return strings
    }

    static func expand(_ value: String, records: [MongoSRVRecord], txtOptions: [String]) throws -> String {
        let scheme = "mongodb+srv://"
        let remainder = String(value.dropFirst(scheme.count))
        let boundary = remainder.firstIndex { ["/", "?", "#"].contains($0) } ?? remainder.endIndex
        let authority = String(remainder[..<boundary])
        var suffix = String(remainder[boundary...])
        let components = authority.split(separator: "@", omittingEmptySubsequences: false)
        let userInfo = components.count > 1 ? components.dropLast().joined(separator: "@") + "@" : ""

        guard !suffix.contains("#") else {
            throw MongoConnectionError.invalid("MongoDB connection strings cannot contain a URL fragment.")
        }

        let queryStart = suffix.firstIndex(of: "?")
        let path = queryStart.map { String(suffix[..<$0]) } ?? suffix
        let existingQuery = queryStart.map { String(suffix[suffix.index(after: $0)...]) } ?? ""
        let existingOptions = existingQuery.split(separator: "&").map(String.init).filter { !$0.isEmpty }
        let allowedTXTKeys = Set(["authsource", "replicaset", "loadbalanced"])
        let safeTXTOptions = txtOptions.filter { option in
            guard let key = option.split(separator: "=", maxSplits: 1).first else { return false }
            return allowedTXTKeys.contains(key.lowercased())
        }

        let existingKeys = Set(existingOptions.compactMap {
            $0.split(separator: "=", maxSplits: 1).first?.lowercased()
        })
        var options = safeTXTOptions.filter { option in
            guard let key = option.split(separator: "=", maxSplits: 1).first else { return false }
            return !existingKeys.contains(key.lowercased())
        } + existingOptions
        let keys = Set(options.compactMap { $0.split(separator: "=", maxSplits: 1).first?.lowercased() })
        if !keys.contains("tls") && !keys.contains("ssl") {
            options.append("tls=true")
        }

        let hosts = records.map { "\($0.host):\($0.port)" }.joined(separator: ",")
        suffix = path
        if !options.isEmpty {
            if suffix.isEmpty { suffix = "/" }
            suffix += "?" + options.joined(separator: "&")
        }
        return "mongodb://\(userInfo)\(hosts)\(suffix)"
    }

    private static func validate(records: [MongoSRVRecord], seedHost: String) throws {
        let labels = seedHost.split(separator: ".")
        guard labels.count >= 3 else {
            throw MongoConnectionError.invalid("The SRV hostname must contain a registrable domain.")
        }
        let allowedSuffix = labels.dropFirst().joined(separator: ".").lowercased()
        for record in records {
            guard record.host == allowedSuffix || record.host.hasSuffix("." + allowedSuffix) else {
                throw MongoConnectionError.dns("The cluster returned an SRV host outside its trusted domain.")
            }
        }
    }
}

protocol DNSRecordResolving {
    func query(name: String, type: UInt16) async throws -> [Data]
}

final class SystemDNSResolver: DNSRecordResolving {
    func query(name: String, type: UInt16) async throws -> [Data] {
        try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "com.aekam.ClusterLens.dns")
            let context = DNSQueryContext(name: name, queue: queue, continuation: continuation)
            let pointer = Unmanaged.passRetained(context).toOpaque()
            context.retainedPointer = pointer

            var reference: DNSServiceRef?
            let status = name.withCString { namePointer in
                DNSServiceQueryRecord(
                    &reference,
                    0,
                    0,
                    namePointer,
                    type,
                    UInt16(kDNSServiceClass_IN),
                    dnsQueryCallback,
                    pointer
                )
            }
            guard status == kDNSServiceErr_NoError, let reference else {
                context.finish(.failure(MongoConnectionError.dns("DNS lookup could not start for \(name) (\(status)).")))
                return
            }
            context.reference = reference

            let queueStatus = DNSServiceSetDispatchQueue(reference, queue)
            guard queueStatus == kDNSServiceErr_NoError else {
                context.finish(.failure(MongoConnectionError.dns("DNS lookup could not be scheduled for \(name).")))
                return
            }

            queue.asyncAfter(deadline: .now() + 10) { [weak context] in
                context?.finish(.failure(MongoConnectionError.dns("DNS lookup timed out for \(name).")))
            }
        }
    }
}

private final class DNSQueryContext {
    let name: String
    let queue: DispatchQueue
    var continuation: CheckedContinuation<[Data], Error>?
    var reference: DNSServiceRef?
    var retainedPointer: UnsafeMutableRawPointer?
    var records: [Data] = []

    init(name: String, queue: DispatchQueue, continuation: CheckedContinuation<[Data], Error>) {
        self.name = name
        self.queue = queue
        self.continuation = continuation
    }

    func finish(_ result: Result<[Data], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        if let reference {
            DNSServiceRefDeallocate(reference)
            self.reference = nil
        }
        continuation.resume(with: result)
        if let retainedPointer {
            self.retainedPointer = nil
            Unmanaged<DNSQueryContext>.fromOpaque(retainedPointer).release()
        }
    }
}

private let dnsQueryCallback: DNSServiceQueryRecordReply = {
    _, flags, _, errorCode, _, _, _, length, data, _, rawContext in
    guard let rawContext else { return }
    let context = Unmanaged<DNSQueryContext>.fromOpaque(rawContext).takeUnretainedValue()
    guard errorCode == kDNSServiceErr_NoError else {
        context.finish(.failure(MongoConnectionError.dns("DNS lookup failed for \(context.name) (\(errorCode)).")))
        return
    }
    if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let data, length > 0 {
        context.records.append(Data(bytes: data, count: Int(length)))
    }
    if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 {
        context.finish(.success(context.records))
    }
}
