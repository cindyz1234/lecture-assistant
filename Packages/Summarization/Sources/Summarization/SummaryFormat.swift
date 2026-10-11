import Foundation
import Shared

/// Formats transcripts for prompts and parses model output.
///
/// The model sees transcript lines as `[m:ss] text` and is asked to answer with
/// one point per line in the same `[m:ss] point` form, so every point carries a
/// timestamp that can be checked against the transcript.
enum SummaryFormat {
    /// `[12:34] text` per segment, one per line.
    static func transcriptLines(_ segments: [TranscriptSegment]) -> String {
        segments.map { "[\($0.start)] \($0.text)" }.joined(separator: "\n")
    }

    /// `[12:34] point` per item, one per line.
    static func pointLines(_ items: [SummaryItem]) -> String {
        items.map { "[\($0.start)] \($0.text)" }.joined(separator: "\n")
    }

    /// Removes a reasoning block (`<think>…</think>`) that some models emit.
    static func stripReasoning(_ text: String) -> String {
        var text = text
        while let open = text.range(of: "<think>") {
            if let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                // Unterminated (e.g. output was cut off): drop everything after <think>.
                text.removeSubrange(open.lowerBound..<text.endIndex)
            }
        }
        return text
    }

    // Regex isn't Sendable, so these are computed rather than stored statics.
    private static var pointLine: Regex<(Substring, Substring?, Substring, Substring, Substring)> {
        /^\s*(?:[-*•]|\d+[.)])?\s*\[(?:(\d{1,2}):)?(\d{1,3}):(\d{2})\]\s*[-–:]?\s*(.+?)\s*$/
    }

    /// Parses `[h:mm:ss] point` / `[m:ss] point` lines, optionally bulleted.
    /// Lines without a timestamp are ignored.
    static func parsePoints(_ output: String) -> [SummaryItem] {
        stripReasoning(output).split(whereSeparator: \.isNewline).compactMap { line in
            guard let match = String(line).wholeMatch(of: pointLine),
                  let minutes = Int64(match.2), let seconds = Int64(match.3), seconds < 60
            else { return nil }
            let hours = match.1.flatMap { Int64($0) } ?? 0
            // A second "[m:ss]" inside the line means two points were run together; keep the first.
            let firstPoint = String(match.4).split(separator: /\s\[\d{1,2}(?::\d{2}){1,2}\]\s/, maxSplits: 1)
            let text = plainText(String(firstPoint.first ?? ""))
            guard !text.isEmpty else { return nil }
            let milliseconds = ((hours * 60 + minutes) * 60 + seconds) * 1000
            return SummaryItem(text: text, start: LectureTime(milliseconds: milliseconds))
        }
    }

    private static var label: Regex<Substring> {
        /^(?i)(?:overview|summary|key points|key ideas)\s*:?\s*/
    }

    /// The text before the first timestamped line, e.g. an overview paragraph,
    /// with labels such as "Overview:" and a dangling lead-in ("The key ideas are:") removed.
    static func parseLeadingText(_ output: String) -> String {
        let lines = stripReasoning(output).split(whereSeparator: \.isNewline).map(String.init)
        var text = lines
            .prefix { parsePoints($0).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces).replacing(label, with: "") }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if text.hasSuffix(":") {
            let lastSentenceEnd = text.dropLast().lastIndex { ".!?".contains($0) }
            text = lastSentenceEnd.map { String(text[...$0]) } ?? ""
        }
        return plainText(text)
    }

    /// LaTeX command names (without the backslash) and their plain-text symbols.
    private static let latexSymbols = [
        "Lambda": "Λ", "lambda": "λ", "Psi": "Ψ", "psi": "ψ", "pi": "π",
        "theta": "θ", "alpha": "α", "beta": "β", "mu": "μ", "sigma": "σ",
        "omega": "ω", "Omega": "Ω", "phi": "φ", "Delta": "Δ", "delta": "δ",
        "epsilon": "ε", "hbar": "ħ", "partial": "∂", "nabla": "∇", "sum": "Σ",
        "int": "∫", "cdot": "·", "times": "×", "infty": "∞", "approx": "≈",
        "rightarrow": "→", "to": "→", "leq": "≤", "geq": "≥", "neq": "≠",
    ]

    /// Converts LaTeX that small models emit despite instructions into plain text:
    /// `$ S^{-1} A S = \Lambda $` becomes `S^-1 A S = Λ`.
    static func plainText(_ text: String) -> String {
        var text = text
        text = text.replacing(/\\[a-zA-Z]+\{([^{}]*)\}/) { "\($0.1)" }  // \mathbf{E} -> E
        text = text.replacing(/([\^_])\{([^{}]*)\}/) { "\($0.1)\($0.2)" }  // A^{-1} -> A^-1
        // Whole command names, so \int never matches inside \infty. Unknown commands are dropped.
        text = text.replacing(/\\([a-zA-Z]+)/) { latexSymbols[String($0.1)] ?? "" }
        text = text.replacingOccurrences(of: "$", with: "")
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Moves `time` to the start of the segment that contains it, or the nearest
    /// segment start if it falls outside all segments (e.g. an invented timestamp).
    static func snap(_ time: LectureTime, to segments: [TranscriptSegment]) -> LectureTime {
        guard !segments.isEmpty else { return time }
        if let containing = segments.last(where: { $0.start <= time && time < $0.end }) {
            return containing.start
        }
        return segments.min { distance($0.start, time) < distance($1.start, time) }!.start
    }

    private static func distance(_ a: LectureTime, _ b: LectureTime) -> Int64 {
        abs(a.milliseconds - b.milliseconds)
    }
}
