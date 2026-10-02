import Foundation

/// Two of your skills that read alike, so they could be one skill.
struct SimilarPair: Identifiable, Hashable, Sendable {
  let first: Skill.ID
  let second: Skill.ID
  /// From 0 to 1: how much their names, descriptions and instructions have in common.
  let score: Double
  /// The words that count the most in both.
  let sharedWords: [String]

  var id: String { Self.key(first, second) }

  func other(than id: Skill.ID) -> Skill.ID { id == first ? second : first }

  static func key(_ a: Skill.ID, _ b: Skill.ID) -> String { a < b ? "\(a)|\(b)" : "\(b)|\(a)" }
}

/// Compares skills by the words they use, weighted so that words every skill uses count for little.
/// It runs on your Mac, with no AI.
enum SkillSimilarity {
  static let threshold = 0.25

  /// Pairs of personal skills that score at least `minimum`, most alike first.
  /// Plugin and built-in skills only help weigh the words.
  static func pairs(in skills: [Skill], minimum: Double = threshold, dismissed: Set<String> = []) -> [SimilarPair] {
    // Skills that mention each other, like the steps of a workflow, aren't alike because of it.
    let names = Set(skills.map { $0.name.lowercased() }.filter { $0.contains("-") })
    var forms: [String: [String: Int]] = [:]
    let documents = skills.map { document($0, skipping: names, forms: &forms) }
    var frequency: [String: Int] = [:]
    for document in documents {
      for word in document.keys { frequency[word, default: 0] += 1 }
    }

    let total = Double(skills.count)
    let vectors = documents.map { document in
      var vector = document.reduce(into: [String: Double]()) { vector, entry in
        vector[entry.key] = (1 + log(entry.value)) * log(total / Double(frequency[entry.key] ?? 1))
      }
      let length = vector.values.reduce(0) { $0 + $1 * $1 }.squareRoot()
      if length > 0 { vector = vector.mapValues { $0 / length } }
      return vector
    }

    let personal = skills.indices.filter { skills[$0].isPersonal }
    var pairs: [SimilarPair] = []
    for (offset, a) in personal.enumerated() {
      for b in personal.dropFirst(offset + 1) {
        let (small, large) = vectors[a].count < vectors[b].count ? (vectors[a], vectors[b]) : (vectors[b], vectors[a])
        let products = small.compactMap { word, weight in large[word].map { (word, weight * $0) } }
        let score = products.reduce(0) { $0 + $1.1 }
        let key = SimilarPair.key(skills[a].id, skills[b].id)
        guard score >= minimum, !dismissed.contains(key) else { continue }
        let shared = products.sorted { $0.1 > $1.1 }.prefix(4).map { word, _ in
          forms[word]?.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? word
        }
        pairs.append(SimilarPair(first: skills[a].id, second: skills[b].id, score: score, sharedWords: shared))
      }
    }
    return pairs.sorted { $0.score > $1.score }
  }

  /// Word counts for a skill. The name and the description count more than the instructions,
  /// because they say what the skill is for.
  /// `forms` counts how each word is written, to show it the way the skills spell it.
  private static func document(_ skill: Skill, skipping names: Set<String>, forms: inout [String: [String: Int]]) -> [String: Double] {
    var counts: [String: Double] = [:]
    func add(_ words: [(word: String, form: String)], weight: Double) {
      for (word, form) in words {
        counts[word, default: 0] += weight
        forms[word, default: [:]][form, default: 0] += 1
      }
    }
    add(words(skill.name.replacingOccurrences(of: "-", with: " ")), weight: 1.5)
    add(words(skill.description, skipping: names), weight: 2)
    if let text = try? String(contentsOf: skill.skillFile, encoding: .utf8) {
      add(words(String(Frontmatter.body(of: text).prefix(30_000)), skipping: names), weight: 1)
    }
    return counts
  }

  /// The words that carry meaning, without the ones every text uses and without `names`.
  static func words(_ text: String, skipping names: Set<String> = []) -> [(word: String, form: String)] {
    text.lowercased()
      .split { !$0.isLetter && !$0.isNumber && $0 != "-" }
      .filter { !names.contains(String($0)) }
      .flatMap { $0.split(separator: "-") }
      .compactMap { token in
        guard token.count >= 3, token.contains(where: \.isLetter) else { return nil }
        let word = stem(String(token))
        return stopWords.contains(word) ? nil : (word, String(token))
      }
  }

  private static func stem(_ word: String) -> String {
    if word.hasSuffix("ies"), word.count > 4 { return word.dropLast(3) + "y" }
    if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), word.count > 3 { return String(word.dropLast()) }
    return word
  }

  private static let stopWords: Set<String> = [
    "about", "after", "again", "also", "and", "any", "are", "ask", "back", "because", "been", "before", "being", "both",
    "but", "can", "could", "did", "doe", "doing", "don", "done", "each", "even", "every", "few", "for", "from", "get", "give",
    "good", "had", "has", "have", "her", "here", "his", "how", "into", "isn", "it", "its", "just", "keep", "let", "like",
    "make", "many", "may", "more", "most", "much", "must", "need", "never", "new", "next", "not", "now", "off", "once",
    "one", "only", "other", "our", "out", "over", "own", "per", "same", "see", "should", "skill", "some", "such", "sure",
    "take", "than", "that", "the", "their", "them", "then", "there", "these", "they", "thi", "this", "those", "through",
    "too", "two", "under", "until", "use", "used", "user", "using", "very", "via", "want", "was", "way", "well", "were",
    "what", "when", "where", "whether", "which", "while", "who", "why", "will", "with", "without", "won", "would", "yes",
    "you", "your", "yours",
  ]
}
