import Foundation

/// Appends rows to a CSV file, writing the header when the file is new.
public struct CSVLog {
    public let url: URL

    public init(url: URL, header: [String]) throws {
        self.url = url
        if !FileManager.default.fileExists(atPath: url.path) {
            try (header.map(Self.field).joined(separator: ",") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public func append(_ values: [String]) throws {
        let row = values.map(Self.field).joined(separator: ",") + "\n"
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(row.utf8))
    }

    /// Quotes a field if it contains a comma, quote or newline (RFC 4180).
    public static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

public enum Machine {
    /// Hardware model identifier, e.g. "Mac15,6".
    public static func model() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &value, &size, nil, 0)
        return String(decoding: value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Peak resident memory of this process so far, in MB.
    public static func peakMemoryMB() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576  // bytes on macOS
    }

    public static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

public func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

extension Duration {
    public var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
