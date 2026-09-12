import Foundation

/// Normalizes C source copied from an AI response without trying to interpret
/// or alter the program itself. In particular, it removes an enclosing
/// Markdown fenced code block so accidental ` ```c ` text never reaches GCC.
enum ClipboardCSource {
    static func normalized(from rawText: String) -> String {
        let normalizedLineEndings = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")

        let lines = normalizedLineEndings.components(separatedBy: "\n")
        guard let openingIndex = lines.firstIndex(where: isFenceLine) else {
            return trimmedSource(normalizedLineEndings)
        }

        let followingLines = lines.index(after: openingIndex)..<lines.endIndex
        guard let closingIndex = lines[followingLines].firstIndex(where: isFenceLine) else {
            return trimmedSource(normalizedLineEndings)
        }

        return trimmedSource(lines[(openingIndex + 1)..<closingIndex].joined(separator: "\n"))
    }

    private static func isFenceLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```")
    }

    private static func trimmedSource(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : trimmed + "\n"
    }
}
