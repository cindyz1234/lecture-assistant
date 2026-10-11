import Shared

/// A stretch of consecutive transcript segments: the unit that Q&A retrieves
/// and answers from. Long enough to contain an explanation, short enough to
/// point at one moment.
public struct Passage: Sendable, Hashable, Identifiable {
    public var lectureID: Lecture.ID
    public var start: LectureTime
    public var end: LectureTime
    public var text: String
    /// Segment IDs in this passage, in order.
    public var segmentIDs: [TranscriptSegment.ID]

    public var id: String { "\(lectureID.uuidString)@\(start.milliseconds)" }

    public init(lectureID: Lecture.ID, start: LectureTime, end: LectureTime, text: String, segmentIDs: [TranscriptSegment.ID]) {
        self.lectureID = lectureID
        self.start = start
        self.end = end
        self.text = text
        self.segmentIDs = segmentIDs
    }
}

public enum PassageBuilder {
    /// Groups a lecture's segments into passages of about `length`, starting a
    /// new passage every `stride` so neighbors overlap. Overlap means an idea
    /// that crosses one passage boundary is whole inside another passage.
    /// Passages always start and end on segment boundaries.
    public static func passages(
        _ segments: [TranscriptSegment],
        lectureID: Lecture.ID,
        length: Duration = .seconds(60),
        stride: Duration = .seconds(30)
    ) -> [Passage] {
        let segments = segments
            .filter { !$0.text.allSatisfy(\.isWhitespace) }
            .sorted { $0.start < $1.start }
        guard !segments.isEmpty else { return [] }
        let lengthMs = milliseconds(length)
        let strideMs = milliseconds(stride)

        var passages: [Passage] = []
        var first = 0
        while first < segments.count {
            let startMs = segments[first].start.milliseconds
            var last = first
            while last + 1 < segments.count, segments[last + 1].end.milliseconds - startMs <= lengthMs {
                last += 1
            }
            let slice = segments[first...last]
            passages.append(Passage(
                lectureID: lectureID,
                start: slice.first!.start,
                end: slice.last!.end,
                text: slice.map(\.text).joined(separator: " "),
                segmentIDs: slice.map(\.id)
            ))
            if last == segments.count - 1 { break }
            // Next passage: the first segment starting at least `stride` later,
            // but always make progress.
            let next = segments.indices.first { $0 > first && segments[$0].start.milliseconds >= startMs + strideMs }
            first = min(next ?? last + 1, last + 1)
        }
        return passages
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}
