import Foundation
import Shared

/// Persists lectures and their transcripts.
///
/// `SQLiteLectureStore` is the on-disk implementation; `InMemoryLectureStore`
/// backs previews. Both pass the same contract tests.
public protocol LectureStore: Sendable {
    /// Inserts the lecture, or updates it if one with the same ID exists.
    func save(_ lecture: Lecture) async throws
    /// All lectures, newest first.
    func lectures() async throws -> [Lecture]
    func append(_ segments: [TranscriptSegment], to lectureID: Lecture.ID) async throws
    /// Segments for a lecture, ordered by start time.
    func segments(for lectureID: Lecture.ID) async throws -> [TranscriptSegment]
    /// Deletes the lecture, its segments and its summary. Does nothing if it doesn't exist.
    func deleteLecture(_ lectureID: Lecture.ID) async throws
    /// Saves the lecture's summary, replacing any previous one.
    func saveSummary(_ summary: LectureSummary, for lectureID: Lecture.ID) async throws
    /// The lecture's summary, or `nil` if it hasn't been summarized.
    func summary(for lectureID: Lecture.ID) async throws -> LectureSummary?
    /// Transcript segments across all lectures, most relevant first.
    ///
    /// With `.allWords` (the search box), a segment must contain every word of
    /// `query`, each of which may be a prefix ("eigen" finds "eigenvalue").
    /// With `.anyWord` (Q&A retrieval), any word matches and ranking favors
    /// segments with more and rarer words. Very common words ("the", "is") are
    /// ignored unless the query has nothing else. A query without words finds nothing.
    func searchTranscripts(_ query: String, limit: Int, matching: SearchMatching) async throws -> [SearchHit]
    /// Replaces the lecture's Q&A passages (all embedding models).
    func savePassages(_ passages: [EmbeddedPassage], for lectureID: Lecture.ID) async throws
    /// All passages embedded with `model`, ordered by lecture and time.
    func embeddedPassages(model: String) async throws -> [EmbeddedPassage]
    /// Complete lectures with no passages embedded with `model` yet.
    func lecturesMissingPassages(model: String) async throws -> [Lecture.ID]
}

/// How search treats the words of a query.
public enum SearchMatching: Sendable {
    /// Every word must appear (as a prefix) in the segment.
    case allWords
    /// Any word may appear; more and rarer matching words rank higher.
    case anyWord
}

extension LectureStore {
    /// Search-box search: every word must appear.
    public func searchTranscripts(_ query: String, limit: Int) async throws -> [SearchHit] {
        try await searchTranscripts(query, limit: limit, matching: .allWords)
    }
}

/// The words a search looks for: the query's words minus stopwords, or all of
/// them if the query is only stopwords.
struct SearchTerms {
    /// Words so common in lectures that they match most segments and add
    /// nothing to relevance.
    static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "has", "have",
        "he", "i", "if", "in", "is", "it", "its", "of", "on", "or", "so", "that", "the",
        "their", "then", "there", "these", "they", "this", "to", "was", "we", "were", "what",
        "when", "which", "will", "with", "you",
    ]

    let searched: [String]
    let isStopwordsOnly: Bool

    init(_ query: String) {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let contentWords = words.filter { !Self.stopwords.contains($0) }
        isStopwordsOnly = contentWords.isEmpty
        searched = isStopwordsOnly ? words : contentWords
    }
}

public enum LectureStoreError: Error, Equatable {
    case lectureNotFound(Lecture.ID)
}

public actor InMemoryLectureStore: LectureStore {
    private var lecturesByID: [Lecture.ID: Lecture] = [:]
    private var segmentsByLecture: [Lecture.ID: [TranscriptSegment]] = [:]
    private var summariesByLecture: [Lecture.ID: LectureSummary] = [:]
    private var passagesByLecture: [Lecture.ID: [EmbeddedPassage]] = [:]

    public init() {}

    public func save(_ lecture: Lecture) {
        lecturesByID[lecture.id] = lecture
    }

    public func lectures() -> [Lecture] {
        lecturesByID.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func append(_ segments: [TranscriptSegment], to lectureID: Lecture.ID) throws {
        guard lecturesByID[lectureID] != nil else { throw LectureStoreError.lectureNotFound(lectureID) }
        segmentsByLecture[lectureID, default: []].append(contentsOf: segments)
    }

    public func segments(for lectureID: Lecture.ID) throws -> [TranscriptSegment] {
        guard lecturesByID[lectureID] != nil else { throw LectureStoreError.lectureNotFound(lectureID) }
        return (segmentsByLecture[lectureID] ?? []).sorted { $0.start < $1.start }
    }

    public func deleteLecture(_ lectureID: Lecture.ID) {
        lecturesByID[lectureID] = nil
        segmentsByLecture[lectureID] = nil
        summariesByLecture[lectureID] = nil
        passagesByLecture[lectureID] = nil
    }

    public func savePassages(_ passages: [EmbeddedPassage], for lectureID: Lecture.ID) throws {
        guard lecturesByID[lectureID] != nil else { throw LectureStoreError.lectureNotFound(lectureID) }
        passagesByLecture[lectureID] = passages
    }

    public func embeddedPassages(model: String) -> [EmbeddedPassage] {
        passagesByLecture
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .flatMap { $0.value.filter { $0.model == model }.sorted { $0.passage.start < $1.passage.start } }
    }

    public func lecturesMissingPassages(model: String) -> [Lecture.ID] {
        lecturesByID.values
            .filter { $0.status == .complete }
            .filter { lecture in !(passagesByLecture[lecture.id] ?? []).contains { $0.model == model } }
            .sorted { $0.createdAt < $1.createdAt }
            .map(\.id)
    }

    public func saveSummary(_ summary: LectureSummary, for lectureID: Lecture.ID) throws {
        guard lecturesByID[lectureID] != nil else { throw LectureStoreError.lectureNotFound(lectureID) }
        summariesByLecture[lectureID] = summary
    }

    public func summary(for lectureID: Lecture.ID) throws -> LectureSummary? {
        guard lecturesByID[lectureID] != nil else { throw LectureStoreError.lectureNotFound(lectureID) }
        return summariesByLecture[lectureID]
    }

    /// Simple prefix matching without stemming or relevance ranking, for previews.
    public func searchTranscripts(_ query: String, limit: Int, matching: SearchMatching) -> [SearchHit] {
        let terms = SearchTerms(query).searched
        guard !terms.isEmpty, limit > 0 else { return [] }
        var hits: [SearchHit] = []
        for (lectureID, segments) in segmentsByLecture {
            guard let lecture = lecturesByID[lectureID] else { continue }
            for segment in segments {
                let words = Self.words(in: segment.text.lowercased())
                let matched = terms.filter { term in words.contains { $0.hasPrefix(term) } }
                guard matching == .anyWord ? !matched.isEmpty : matched.count == terms.count else { continue }
                let fragments = Self.fragments(segment.text) { word in terms.contains { word.lowercased().hasPrefix($0) } }
                hits.append(SearchHit(
                    lectureID: lectureID, lectureTitle: lecture.title, segmentID: segment.id,
                    start: segment.start, fragments: fragments,
                    score: Double(fragments.filter(\.isMatch).count)
                ))
            }
        }
        return Array(hits.sorted { ($0.score, $1.start) > ($1.score, $0.start) }.prefix(limit))
    }

    private static func words(in text: String) -> [Substring] {
        text.split { !$0.isLetter && !$0.isNumber }
    }

    /// Splits text into word and non-word runs, marking words where `isMatch` is true.
    private static func fragments(_ text: String, isMatch: (Substring) -> Bool) -> [SearchHit.Fragment] {
        var fragments: [SearchHit.Fragment] = []
        var index = text.startIndex
        while index < text.endIndex {
            let isWordChar: (Character) -> Bool = { $0.isLetter || $0.isNumber }
            let inWord = isWordChar(text[index])
            let end = text[index...].firstIndex { isWordChar($0) != inWord } ?? text.endIndex
            let run = text[index..<end]
            fragments.append(SearchHit.Fragment(text: String(run), isMatch: inWord && isMatch(run)))
            index = end
        }
        return fragments
    }
}
