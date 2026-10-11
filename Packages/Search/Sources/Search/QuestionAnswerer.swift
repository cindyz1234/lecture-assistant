import Shared

/// A source an answer cites: a moment in a lecture.
public struct Citation: Sendable, Hashable {
    /// The number the answer uses for it, e.g. 2 for "[2]".
    public var number: Int
    public var lectureID: Lecture.ID
    public var time: LectureTime
}

/// An answer grounded in lecture passages.
public struct Answer: Sendable {
    /// The model's answer, with citation markers such as "[2]" kept in place.
    /// Markers that don't refer to a provided passage are removed.
    public var text: String
    /// Citations in order of first appearance; each `number` matches a marker in `text`.
    public var citations: [Citation]
    /// False when the passages didn't contain the answer and the model declined.
    public var isAnswered: Bool
    /// The passages the model was given, best first.
    public var passages: [RetrievedPassage]
}

/// Answers questions from retrieved lecture passages only.
///
/// Passages are numbered [1]…[k] in the prompt and the model cites them by
/// number (timestamps are ambiguous across lectures, and small models copy short
/// numbers reliably). Every citation is checked: a number that isn't one of the
/// provided passages is removed rather than shown as a link.
public struct QuestionAnswerer<Generator: TextGenerator>: Sendable {
    public static var notFoundMarker: String { "NOT_IN_LECTURES" }

    public let retriever: HybridRetriever
    public let generator: Generator
    /// Passages given to the model.
    public var passageCount = 5
    public var maxTokens = 300
    /// Lecture titles shown to the model, by ID.
    public var lectureTitles: [Lecture.ID: String] = [:]

    public init(retriever: HybridRetriever, generator: Generator) {
        self.retriever = retriever
        self.generator = generator
    }

    public func answer(_ question: String) async throws -> Answer {
        let passages = try await retriever.retrieve(question, k: passageCount)
        guard !passages.isEmpty else {
            return Answer(text: "", citations: [], isAnswered: false, passages: [])
        }
        let output = try await generator.generate(
            instructions: Self.instructions,
            prompt: prompt(question, passages: passages),
            maxTokens: maxTokens
        )
        return Self.parse(output, passages: passages)
    }

    // Static stored properties aren't allowed in generic types, so this is computed.
    static var instructions: String { """
    You answer students' questions using only the lecture excerpts you are given. \
    Cite the excerpts you use with their numbers in square brackets, like [2]. \
    Do not use outside knowledge. If the excerpts do not contain the answer, reply \
    with exactly \(notFoundMarker) and nothing else. \
    Write plain text in two to four sentences. Write math in words or plain symbols, never LaTeX.
    """ }

    func prompt(_ question: String, passages: [RetrievedPassage]) -> String {
        let excerpts = passages.enumerated().map { index, retrieved in
            let title = lectureTitles[retrieved.passage.lectureID] ?? "Lecture"
            return "[\(index + 1)] (\(title), \(retrieved.passage.start)) \(retrieved.passage.text)"
        }
        // Small models follow instructions next to the question far better than
        // ones in the system prompt (measured: 12 citations in 44 dev answers).
        return """
        Lecture excerpts:

        \(excerpts.joined(separator: "\n\n"))

        Question: \(question)

        Answer in two to four sentences using only the excerpts. End each sentence with the \
        number of the excerpt it comes from, for example: The determinant must be zero [2]. \
        If the excerpts do not answer the question, reply only \(Self.notFoundMarker).
        """
    }

    /// Declines phrased in the model's own words rather than with `notFoundMarker`.
    static func isDecline(_ text: String) -> Bool {
        let lower = text.lowercased()
        let phrases = ["not addressed in the", "not mentioned in the", "not covered in the", "not discussed in the",
                       "excerpts do not", "excerpts don't", "no information about", "not in the lecture"]
        return lower.count < 200 && phrases.contains { lower.contains($0) }
    }

    /// Turns model output into an `Answer`, keeping only citations of provided passages.
    static func parse(_ output: String, passages: [RetrievedPassage]) -> Answer {
        let text = ModelOutput.plainText(ModelOutput.stripReasoning(output))
        if text.isEmpty || text.contains(notFoundMarker) || isDecline(text) {
            return Answer(text: "", citations: [], isAnswered: false, passages: passages)
        }

        var citations: [Citation] = []
        // Rewrite each bracket group ("[2]", "[1, 3]", "[1][3]") keeping valid numbers.
        let cleaned = text.replacing(/\[(\d+(?:\s*,\s*\d+)*)\]/) { match in
            let numbers = match.1.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let valid = numbers.filter { (1...passages.count).contains($0) }
            for number in valid where !citations.contains(where: { $0.number == number }) {
                let passage = passages[number - 1].passage
                citations.append(Citation(number: number, lectureID: passage.lectureID, time: passage.start))
            }
            return valid.map { "[\($0)]" }.joined()
        }
        // Removing an invalid marker can leave a doubled space or a space before punctuation.
        let tidied = cleaned
            .replacing(/\ {2,}/, with: " ")
            .replacing(/\ ([.,;:!?])/) { String($0.1) }
        return Answer(text: tidied, citations: citations, isAnswered: true, passages: passages)
    }
}
