import Foundation

enum Hotwords {
    /// X-ASR trains with a word boundary before every Chinese character.
    /// Preserve English words but split CJK characters before BPE encoding.
    static func forRecognizer(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { line in
            var spaced = ""
            for character in line {
                let cjk = character.unicodeScalars.contains {
                    (0x3400...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value)
                }
                spaced += cjk ? " \(character) " : String(character)
            }
            return spaced.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }.joined(separator: "\n")
    }

    static func normalize(_ text: String) throws -> String {
        var seen = Set<String>()
        let words = text.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard words.count <= 100 else { throw invalid("You can add up to 100 hotwords.") }
        for word in words {
            guard word.count <= 80,
                  !word.contains(where: { ":/<>▁".contains($0) }),
                  !word.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw invalid("Each hotword can contain up to 80 characters, excluding : / < > ▁ and control characters.")
            }
        }
        return words.joined(separator: "\n")
    }

    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "GlobeTalk.Hotwords", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// A local spelling change, rather than an entire rewritten sentence.
    static func correction(from old: String, to new: String) -> (String, String)? {
        guard old != new else { return nil }
        let a = Array(old), b = Array(new)
        var start = 0, endA = a.count, endB = b.count
        while start < min(endA, endB), a[start] == b[start] { start += 1 }
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] {
            endA -= 1; endB -= 1
        }
        func latin(_ c: Character) -> Bool {
            c.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0)) }
        }
        // Include unchanged letters around an acronym/spelling correction.
        while start > 0, latin(a[start - 1]), latin(b[start - 1]),
              ((start < a.count && latin(a[start])) || (start < b.count && latin(b[start]))) { start -= 1 }
        while endA < a.count, endB < b.count, a[endA] == b[endB],
              latin(a[endA]), endA > 0, endB > 0,
              latin(a[endA - 1]), latin(b[endB - 1]) { endA += 1; endB += 1 }
        let before = String(a[start..<endA]).trimmingCharacters(in: .whitespacesAndNewlines)
        let after = String(b[start..<endB]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !before.isEmpty, after.count >= 2, before.count <= 40, after.count <= 40,
              after.split(whereSeparator: { $0.isWhitespace }).count <= 4,
              (try? normalize(after)) == after,
              after.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
        return (before, after)
    }
}
