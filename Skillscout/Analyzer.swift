import Foundation

enum Analyzer {
  static let maxMessages = 2000

  private struct Candidate: Decodable {
    let name: String
    let title: String
    let summary: String
    let why: String
    let messageIds: [Int]
  }

  private struct Response: Decodable {
    let suggestions: [Candidate]
  }

  struct BadResponse: LocalizedError {
    let output: String
    var errorDescription: String? { "The AI reply wasn't valid JSON:\n\(output.prefix(300))" }
  }

  static func findSuggestions(prompts: [Prompt], skills: [Skill], dismissed: [String], engine: AIEngine) async throws -> [Suggestion] {
    var groups: [[Prompt]] = []
    var groupIndex: [String: Int] = [:]
    for prompt in prompts.prefix(maxMessages) {
      let key = oneLine(prompt.text)
      if let index = groupIndex[key] {
        groups[index].append(prompt)
      } else {
        groupIndex[key] = groups.count
        groups.append([prompt])
      }
    }

    let messages = groups.enumerated().map { index, group in
      let first = group[0]
      let repeats = group.count > 1 ? " (×\(group.count))" : ""
      return "\(index + 1) | \(first.tool.name) | \(first.project)\(repeats) | \(oneLine(first.text).prefix(220))"
    }
    let existing = skills.map { "- \($0.name): \(oneLine($0.description).prefix(90))" }
    let rejected = dismissed.isEmpty ? "none" : dismissed.joined(separator: ", ")
    let toolNames = Tool.allCases.filter { tool in prompts.contains { $0.tool == tool } }.map(\.name).joined(separator: ", ")

    let prompt = """
    You help a developer find requests they keep making to AI coding agents (\(toolNames)), so they can turn them into reusable Agent Skills.

    An Agent Skill is a folder with a SKILL.md file: a name, a description of when to use it, and instructions the agent loads when that task comes up. Good skills capture a workflow, a personal style, or conventions the developer keeps explaining again.

    Below are the developer's recent messages, one per line: id | tool | project | text. "(×N)" means the exact same message was sent N times.

    Find up to 10 skill ideas, best first. Rules:
    - Each idea needs at least 3 supporting messages, ideally from different projects or days.
    - Prefer recurring workflows and repeated instructions over one-off bug fixes.
    - Skip messages that look machine-generated or scripted.
    - Skip anything an existing skill already covers.
    - Skip these ideas the developer already rejected: \(rejected)
    - In messageIds, list every message that belongs to the idea, not a sample. The app uses them to count how often the developer asked.

    Reply with only JSON, no code fences, in this shape:
    {"suggestions":[{"name":"kebab-case-name","title":"Short title","summary":"One sentence on what the skill would do","why":"One sentence on the repeated pattern you saw","messageIds":[1,2,3]}]}

    Existing skills:
    \(existing.joined(separator: "\n"))

    Messages:
    \(messages.joined(separator: "\n"))
    """

    let output = try await engine.run(prompt)
    let response = try decode(Response.self, from: output)

    return response.suggestions.compactMap { candidate in
      let examples = Set(candidate.messageIds)
        .filter { groups.indices.contains($0 - 1) }
        .flatMap { groups[$0 - 1] }
      guard examples.count >= 2 else { return nil }
      return Suggestion(
        name: SkillInstaller.slug(candidate.name),
        title: candidate.title,
        summary: candidate.summary,
        why: candidate.why,
        examples: examples.sorted { $0.date > $1.date },
        createdAt: .now
      )
    }
  }

  static func draftSkill(for suggestion: Suggestion, engine: AIEngine) async throws -> String {
    let examples = suggestion.examples.prefix(15)
      .map { "- [\($0.tool.name), \($0.project)] \(oneLine($0.text).prefix(600))" }
      .joined(separator: "\n")

    let prompt = """
    Write a SKILL.md file for an Agent Skill. It should work in any agent that supports Agent Skills.

    Skill idea: \(suggestion.title)
    What it should do: \(suggestion.summary)
    Why: \(suggestion.why)

    These are real messages where the developer asked for this task:
    \(examples)

    Use this format:

    ---
    name: \(suggestion.name)
    description: What the skill does and when to use it, in one or two sentences, under 300 characters.
    ---

    # Title

    Then the instructions: the steps the agent should follow, the conventions and preferences you can infer from the messages, and a short checklist at the end. Keep it under 80 lines. Write plain, direct sentences. Don't invent tools, paths or facts the messages don't support.

    Reply with only the SKILL.md content, no code fences.
    """
    return stripFences(try await engine.run(prompt))
  }

  static func mergeSkills(_ plan: SkillInstaller.MergePlan, engine: AIEngine) async throws -> String {
    let kept = plan.kept.name
    let merged = plan.merged.name
    let keptText = (try? String(contentsOf: plan.kept.skillFile, encoding: .utf8)) ?? ""
    let mergedText = (try? String(contentsOf: plan.merged.skillFile, encoding: .utf8)) ?? ""

    func list(_ paths: [String]) -> String {
      let shown = paths.prefix(40).joined(separator: ", ")
      return paths.count > 40 ? "\(shown), and \(paths.count - 40) more" : shown
    }
    var files = ["The merged skill keeps the name \(kept) and lives in its folder."]
    if !plan.keptFiles.isEmpty { files.append("Besides SKILL.md, that folder has: \(list(plan.keptFiles)).") }
    if !plan.copiedFiles.isEmpty { files.append("These files from \(merged) get copied into it, at the same paths: \(list(plan.copiedFiles)).") }
    if !plan.skippedFiles.isEmpty {
      files.append("These files from \(merged) stay out, because \(kept) has its own file at the same path: \(list(plan.skippedFiles)).")
    }

    let prompt = """
    Merge two Agent Skills into one SKILL.md. They overlap, and the developer wants a single skill that does what both do.

    Rules:
    - Keep every instruction, step, convention and example from both, and say each thing once.
    - When they disagree, keep the more specific instruction. If you can't tell, keep both and say when each one applies.
    - Keep commands, paths, links and file references exactly as written.
    - Keep the other frontmatter fields of either file.
    - Match the tone and structure of the originals. Don't add instructions of your own.

    \(files.joined(separator: " "))

    Start with this frontmatter:

    ---
    name: \(kept)
    description: What the merged skill does and when to use it, covering both skills, in one or two sentences, under 300 characters.
    ---

    Reply with only the SKILL.md content, no code fences.

    SKILL.md of \(kept):
    \(keptText.prefix(40_000))

    SKILL.md of \(merged):
    \(mergedText.prefix(40_000))
    """
    return stripFences(try await engine.run(prompt))
  }

  static func explain(name: String, skillText: String, engine: AIEngine) async throws -> String {
    let prompt = """
    Explain the Agent Skill "\(name)" to a developer who has never seen it. Plain text, no markdown, under 120 words. Cover what it does, when the agent uses it, and what it needs to work (CLIs, accounts, API keys, specific tools).

    SKILL.md:
    \(skillText.prefix(40_000))
    """
    return try await engine.run(prompt).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func oneLine(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func decode<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
    guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
          let value = try? JSONDecoder().decode(type, from: Data(output[start...end].utf8))
    else { throw BadResponse(output: output) }
    return value
  }

  private static func stripFences(_ text: String) -> String {
    var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
    if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
    if lines.last?.hasPrefix("```") == true { lines.removeLast() }
    return lines.joined(separator: "\n") + "\n"
  }
}
