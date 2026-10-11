import Foundation

/// A block of mono PCM audio positioned on the lecture timeline.
public struct AudioChunk: Sendable, Equatable {
    /// Mono samples in the range [-1, 1].
    public var samples: [Float]
    public var sampleRate: Double
    /// Time of the first sample.
    public var start: LectureTime

    public init(samples: [Float], sampleRate: Double, start: LectureTime) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.start = start
    }

    public var duration: LectureTime {
        LectureTime(sampleIndex: Int64(samples.count), sampleRate: sampleRate)
    }

    /// Time just after the last sample.
    public var end: LectureTime { start + duration }
}

/// A piece of transcribed text spanning `start..<end` on the lecture timeline.
public struct TranscriptSegment: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var text: String
    public var start: LectureTime
    public var end: LectureTime
    /// `false` while the ASR engine may still revise this segment.
    public var isFinal: Bool

    public init(id: UUID = UUID(), text: String, start: LectureTime, end: LectureTime, isFinal: Bool) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.isFinal = isFinal
    }
}

/// A recorded or imported lecture.
public struct Lecture: Sendable, Hashable, Codable, Identifiable {
    public enum Status: String, Sendable, Codable, CaseIterable {
        /// Transcription is running.
        case transcribing
        case complete
        /// The app stopped (quit, crash, cancel) before transcription finished.
        case interrupted
        case failed
    }

    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var duration: LectureTime
    public var status: Status
    /// Name of the imported file, if the lecture came from one.
    public var sourceFileName: String?

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        duration: LectureTime = .zero,
        status: Status = .complete,
        sourceFileName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.status = status
        self.sourceFileName = sourceFileName
    }
}

/// One summary point, linked to the moment in the lecture it refers to.
public struct SummaryItem: Sendable, Hashable, Codable {
    public var text: String
    /// Start of the transcript segment this point refers to.
    public var start: LectureTime

    public init(text: String, start: LectureTime) {
        self.text = text
        self.start = start
    }
}

/// A lecture summary: a short overview plus timestamped key points.
public struct LectureSummary: Sendable, Hashable, Codable {
    public var overview: String
    /// Ordered by `start`.
    public var keyPoints: [SummaryItem]

    public init(overview: String, keyPoints: [SummaryItem]) {
        self.overview = overview
        self.keyPoints = keyPoints
    }
}
