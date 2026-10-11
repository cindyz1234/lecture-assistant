import Shared

/// Summarizes long transcripts with a small model in two stages:
///
/// 1. **Map:** split the transcript into chunks and ask for timestamped key
///    points from each chunk.
/// 2. **Reduce:** give all chunk points to the model and ask for an overview
///    of the whole lecture.
///
/// Key points are selected by code, not by the model: the first point of each
/// chunk, spread evenly over the lecture. Small models asked to select points
/// across a long list favor the first ones (measured: all points came from the
/// first 40% of the lecture), so coverage is guaranteed by construction.
///
/// Every timestamp the model returns is snapped to a real transcript segment,
/// so a key point always links to a moment that exists.
public struct MapReduceSummarizer<Generator: TextGenerator>: Summarizer {
    public struct Configuration: Sendable {
        /// Words of transcript per map call (~1,200 words ≈ 1,600 tokens).
        public var chunkWords = 1_200
        public var pointsPerChunk = 2
        public var maxKeyPoints = 10
        public var mapMaxTokens = 250
        public var reduceMaxTokens = 250

        public init() {}
    }

    public let generator: Generator
    public let configuration: Configuration

    public init(generator: Generator, configuration: Configuration = Configuration()) {
        self.generator = generator
        self.configuration = configuration
    }

    public func summarize(
        _ segments: [TranscriptSegment],
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> LectureSummary {
        let chunks = TranscriptChunker.chunks(segments, maxWords: configuration.chunkWords)
        guard !chunks.isEmpty else { return LectureSummary(overview: "", keyPoints: []) }
        let totalSteps = chunks.count + 1
        progress?(0, totalSteps)

        // Map: key points per chunk, snapped into that chunk and deduplicated.
        var pointsByChunk: [[SummaryItem]] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let output = try await generator.generate(
                instructions: Prompts.mapInstructions,
                prompt: Prompts.map(chunk, points: configuration.pointsPerChunk),
                maxTokens: configuration.mapMaxTokens
            )
            var seenStarts: Set<LectureTime> = []
            let points = SummaryFormat.parsePoints(output)
                .filter { $0.text != Prompts.formatExampleText }
                .map { SummaryItem(text: $0.text, start: SummaryFormat.snap($0.start, to: chunk.segments)) }
                .filter { seenStarts.insert($0.start).inserted }
                .prefix(configuration.pointsPerChunk)
            pointsByChunk.append(Array(points))
            progress?(index + 1, totalSteps)
        }

        // Reduce: an overview of the whole lecture from all chunk points.
        try Task.checkCancellation()
        let output = try await generator.generate(
            instructions: Prompts.reduceInstructions,
            prompt: Prompts.reduce(pointsByChunk.flatMap { $0 }),
            maxTokens: configuration.reduceMaxTokens
        )
        progress?(totalSteps, totalSteps)

        return LectureSummary(
            overview: SummaryFormat.parseLeadingText(output),
            keyPoints: Self.selectKeyPoints(pointsByChunk, max: configuration.maxKeyPoints)
        )
    }

    /// Picks up to `max` points spread over the lecture: each chunk's first point
    /// (from evenly spaced chunks if there are more chunks than `max`), then
    /// further points round-robin while there is room. Sorted by time.
    static func selectKeyPoints(_ pointsByChunk: [[SummaryItem]], max: Int) -> [SummaryItem] {
        let chunks = pointsByChunk.filter { !$0.isEmpty }
        guard max > 0, !chunks.isEmpty else { return [] }
        var selected: [SummaryItem] = []
        if chunks.count >= max {
            // Evenly spaced chunk indices, always including the first and last chunk.
            let indices = (0..<max).map { i in max == 1 ? 0 : i * (chunks.count - 1) / (max - 1) }
            selected = indices.map { chunks[$0][0] }
        } else {
            var depth = 0
            while selected.count < max, chunks.contains(where: { $0.count > depth }) {
                for chunk in chunks where chunk.count > depth && selected.count < max {
                    selected.append(chunk[depth])
                }
                depth += 1
            }
        }
        return selected.sorted { $0.start < $1.start }
    }
}

/// Prompt text. Kept in one place so prompt changes are easy to review and evaluate.
enum Prompts {
    /// Format example shown to the model. It is content-free on purpose: a small
    /// model copied a realistic example sentence into its output verbatim.
    static let formatExampleText = "One complete sentence stating the idea."
    static let formatExample = "[m:ss] \(formatExampleText)"

    static let mapInstructions = """
    You summarize parts of university lecture transcripts for students. \
    Be factual and specific; only state what the lecturer says. \
    Write plain text. Write math in words or plain symbols (for example "A x = lambda x"), never LaTeX.
    """

    static func map(_ chunk: TranscriptChunk, points: Int) -> String {
        """
        Below is part of a lecture transcript. Each line starts with its timestamp.

        \(SummaryFormat.transcriptLines(chunk.segments))

        List the \(points) most important ideas in this part. Each idea must be different \
        from the others. Write each one as a complete sentence in your own words; do not \
        copy transcript lines. Put one idea per line, starting with the timestamp where it \
        is discussed, in this format:
        \(Prompts.formatExample)
        """
    }

    static let reduceInstructions = """
    You write concise study summaries of university lectures for students. \
    Be factual; only use the notes you are given. \
    Write plain text. Write math in words or plain symbols, never LaTeX.
    """

    static func reduce(_ points: [SummaryItem]) -> String {
        """
        Below are timestamped notes from one whole lecture, in order.

        \(SummaryFormat.pointLines(points))

        Write a 3-4 sentence overview of the whole lecture for a student who missed it. \
        Cover how it starts, what it builds up to, and where it ends. \
        Write one paragraph without timestamps or bullet points.
        """
    }
}
