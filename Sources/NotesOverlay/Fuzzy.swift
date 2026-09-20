import Foundation

enum Fuzzy {
    /// nil when `query` does not match `title` or `content`; otherwise a score, higher is
    /// better. `content` is expected to be lowercased already.
    static func score(query: String, title: String, content: String) -> Int? {
        let lowerQuery = query.lowercased()
        let q = Array(lowerQuery)
        guard !q.isEmpty else { return 0 }

        let lowerTitle = title.lowercased()
        var best: Int?
        if let s = subsequenceScore(q, in: Array(lowerTitle)) { best = s * 2 + 100 }
        if lowerTitle.contains(lowerQuery) { best = (best ?? 0) + 200 }
        if let s = subsequenceScore(q, in: Array(content)) { best = max(best ?? Int.min, s) }
        return best
    }

    /// Greedy in-order character match. Rewards consecutive characters and word starts,
    /// penalises gaps and long texts.
    private static func subsequenceScore(_ query: [Character], in text: [Character]) -> Int? {
        var score = 0
        var ti = 0
        var previous = -2
        for ch in query {
            var found = false
            while ti < text.count {
                if text[ti] == ch {
                    var s = 10
                    if ti == previous + 1 { s += 15 }
                    if ti == 0 || !(text[ti - 1].isLetter || text[ti - 1].isNumber) { s += 10 }
                    if previous >= 0 { s -= min(ti - previous - 1, 10) }
                    score += s
                    previous = ti
                    ti += 1
                    found = true
                    break
                }
                ti += 1
            }
            if !found { return nil }
        }
        return score - min(text.count / 50, 20)
    }
}
