import Foundation

struct SkillDetailRequest: Hashable, Sendable {
  let source: SkillCopy
  let revision: Int
  let lintSource: SkillCopy?
  let lintFolderName: String?

  init(skill: Skill, installationSource: SkillCopy?, revision: Int) {
    source = installationSource ?? skill.primary
    self.revision = revision
    if let installationSource {
      lintSource = installationSource
      lintFolderName = installationSource.folder.lastPathComponent
    } else {
      let editable = skill.copies.filter { $0.root.kind != .plugin && $0.root.kind != .builtIn }
      let read = editable.first { !$0.root.readBy.isEmpty }
      lintSource = read ?? editable.first
      lintFolderName = read?.folder.lastPathComponent
    }
  }
}

struct SkillDetailInspection: Sendable {
  let request: SkillDetailRequest
  let content: String
  let description: String
  let review: SkillReview?
  let problems: [String]
}

actor SkillDetailInspector {
  func inspect(_ request: SkillDetailRequest) throws -> SkillDetailInspection {
    try Task.checkCancellation()
    let content = (try? String(contentsOf: request.source.resolved.appending(path: "SKILL.md"), encoding: .utf8)) ?? ""
    try Task.checkCancellation()
    let review = request.source.root.kind == .managed || request.source.root.kind == .plugin
      ? SkillReview.inspect(request.source.resolved) : nil
    try Task.checkCancellation()
    let lintText = request.lintSource.flatMap { copy in
      try? String(contentsOf: copy.folder.appending(path: "SKILL.md"), encoding: .utf8)
    }
    let problems = lintText.map { SkillLint.problems($0, folderName: request.lintFolderName) } ?? []
    try Task.checkCancellation()
    return SkillDetailInspection(request: request, content: content,
      description: Frontmatter.parse(content)["description"] ?? "", review: review, problems: problems)
  }
}
