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

/// A passage with its embedding vector and the model that produced it.
public struct EmbeddedPassage: Sendable, Hashable {
    public var passage: Passage
    public var vector: [Float]
    /// Vectors from different models aren't comparable, so the model is stored with them.
    public var model: String

    public init(passage: Passage, vector: [Float], model: String) {
        self.passage = passage
        self.vector = vector
        self.model = model
    }
}
