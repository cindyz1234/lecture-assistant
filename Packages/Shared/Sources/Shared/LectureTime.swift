/// A point in time measured in milliseconds from the start of a lecture.
///
/// Every timestamp in the app (audio chunks, transcript segments, summaries,
/// search hits, OCR snapshots) uses this type so they can be aligned directly.
public struct LectureTime: Hashable, Comparable, Sendable, Codable {
    public var milliseconds: Int64

    public init(milliseconds: Int64) {
        self.milliseconds = milliseconds
    }

    public static let zero = LectureTime(milliseconds: 0)

    /// The time at which sample `index` occurs in a stream at `sampleRate` Hz.
    public init(sampleIndex: Int64, sampleRate: Double) {
        self.milliseconds = Int64((Double(sampleIndex) * 1000 / sampleRate).rounded(.down))
    }

    public var seconds: Double { Double(milliseconds) / 1000 }

    public static func < (lhs: LectureTime, rhs: LectureTime) -> Bool {
        lhs.milliseconds < rhs.milliseconds
    }

    public static func + (lhs: LectureTime, rhs: LectureTime) -> LectureTime {
        LectureTime(milliseconds: lhs.milliseconds + rhs.milliseconds)
    }
}

extension LectureTime: CustomStringConvertible {
    /// Formats as `h:mm:ss` or `m:ss`.
    public var description: String {
        let totalSeconds = milliseconds / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours):\(Self.pad(minutes)):\(Self.pad(seconds))"
        }
        return "\(minutes):\(Self.pad(seconds))"
    }

    private static func pad(_ value: Int64) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
