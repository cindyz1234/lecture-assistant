/// Helpers for cleaning up language-model output.
public enum ModelOutput {
    /// Removes a reasoning block (`<think>…</think>`) that some models emit.
    public static func stripReasoning(_ text: String) -> String {
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
    public static func plainText(_ text: String) -> String {
        var text = text
        text = text.replacing(/\\[a-zA-Z]+\{([^{}]*)\}/) { "\($0.1)" }  // \mathbf{E} -> E
        text = text.replacing(/([\^_])\{([^{}]*)\}/) { "\($0.1)\($0.2)" }  // A^{-1} -> A^-1
        // Whole command names, so \int never matches inside \infty. Unknown commands are dropped.
        text = text.replacing(/\\([a-zA-Z]+)/) { latexSymbols[String($0.1)] ?? "" }
        text = text.replacingOccurrences(of: "$", with: "")
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
