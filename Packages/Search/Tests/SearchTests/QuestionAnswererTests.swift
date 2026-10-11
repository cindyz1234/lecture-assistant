import Foundation
import Shared
import Testing
@testable import Search

/// Returns one scripted response and records the prompt.
actor OneShotGenerator: TextGenerator {
    let response: String
    private(set) var prompts: [String] = []

    init(_ response: String) { self.response = response }

    func generate(instructions: String, prompt: String, maxTokens: Int) -> String {
        prompts.append(prompt)
        return response
    }
}

struct QuestionAnswererTests {
    let segments = [
        segment(0, 60, "Today eigenvalues and eigenvectors."),
        segment(60, 120, "The p orbital has m equal to zero."),
        segment(120, 180, "A photon carries momentum h over lambda."),
    ]

    /// Retrieval order for "eigen orbital photon": all three passages, by keyword rank 1, 2, 3.
    func makeAnswerer(_ response: String) async throws -> (QuestionAnswerer<OneShotGenerator>, OneShotGenerator) {
        let passages = PassageBuilder.passages(segments, lectureID: lecture, length: .seconds(60), stride: .seconds(60))
        let hits = segments.map {
            SearchHit(lectureID: lecture, lectureTitle: "L", segmentID: $0.id, start: $0.start, fragments: [], score: 1)
        }
        let retriever = try await HybridRetriever.build(passages: passages, embedder: KeywordEmbedder()) { _, _ in hits }
        let generator = OneShotGenerator(response)
        var answerer = QuestionAnswerer(retriever: retriever, generator: generator)
        answerer.lectureTitles = [lecture: "18.06 L22"]
        return (answerer, generator)
    }

    @Test func mapsCitationNumbersToPassagesAndDropsInvalidOnes() async throws {
        let (answerer, _) = try await makeAnswerer(
            "<think></think>A photon has momentum h over lambda [3] [9], unlike [1, 7] eigen stuff [3]."
        )

        let answer = try await answerer.answer("photon momentum")

        #expect(answer.isAnswered)
        #expect(answer.text == "A photon has momentum h over lambda [3], unlike [1] eigen stuff [3].")
        let byNumber = Dictionary(uniqueKeysWithValues: answer.citations.map { ($0.number, $0) })
        #expect(answer.citations.map(\.number) == [3, 1])  // order of first appearance, no duplicates
        #expect(byNumber[3]?.lectureID == lecture)
        #expect(byNumber[3]?.time == answer.passages[2].passage.start)
    }

    @Test func detectsWhenTheModelDeclines() async throws {
        let (answerer, _) = try await makeAnswerer("NOT_IN_LECTURES")

        let answer = try await answerer.answer("What is the capital of France?")

        #expect(!answer.isAnswered)
        #expect(answer.citations.isEmpty)
        #expect(answer.passages.count == 3)  // still shown, so the user can check
    }

    @Test(arguments: [
        "The question is not addressed in the lecture excerpts.",
        "The excerpts do not contain information about stocks.",
        "<think></think>NOT_IN_LECTURES",
    ])
    func recognizesDeclinesInOtherWords(response: String) async throws {
        let (answerer, _) = try await makeAnswerer(response)
        #expect(try await !answerer.answer("stocks vs bonds").isAnswered)
    }

    @Test func longAnswersMentioningExcerptsAreNotDeclines() async throws {
        let long = "The determinant must be zero [1]. " + String(repeating: "It is explained step by step. ", count: 8)
            + "Some details are not mentioned in the excerpts."
        let (answerer, _) = try await makeAnswerer(long)
        #expect(try await answerer.answer("determinant").isAnswered)
    }

    @Test func convertsLatexInAnswers() async throws {
        let (answerer, _) = try await makeAnswerer("So $ A = LU $ with $\\lambda$ on the diagonal [1].")
        #expect(try await answerer.answer("factorization").text == "So A = LU with λ on the diagonal [1].")
    }

    @Test func promptNumbersPassagesWithLectureAndTime() async throws {
        let (answerer, generator) = try await makeAnswerer("Answer [1].")

        _ = try await answerer.answer("eigen")

        let prompt = try #require(await generator.prompts.first)
        #expect(prompt.contains("[1] (18.06 L22, 0:00) Today eigenvalues and eigenvectors."))
        #expect(prompt.contains("[2] (18.06 L22, 1:00)"))
        #expect(prompt.contains("Question: eigen\n"))
        #expect(prompt.contains("End each sentence with the number of the excerpt"))
    }

    @Test func noPassagesMeansNoModelCall() async throws {
        let retriever = HybridRetriever(passages: [], index: VectorIndex(dimension: 4), embedder: KeywordEmbedder()) { _, _ in [] }
        let generator = OneShotGenerator("should not be used")
        let answer = try await QuestionAnswerer(retriever: retriever, generator: generator).answer("anything")

        #expect(!answer.isAnswered)
        #expect(await generator.prompts.isEmpty)
    }
}
