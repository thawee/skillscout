import Foundation

struct RegistrySkill: Codable, Identifiable, Hashable, Sendable {
  var id: String { repo }
  let name: String
  let description: String
  let repo: String
  let tools: [String]?
  let author: String
  var manualInstall: String? = nil
}

actor Registry {
  static let shared = Registry()

  var skills: [RegistrySkill] = []
  private var lastFetched: Date?

  func fetch() async throws -> [RegistrySkill] {
    if let lastFetched, Date().timeIntervalSince(lastFetched) < 3600, !skills.isEmpty {
      return skills
    }

    guard let url = Bundle.main.url(forResource: "registry", withExtension: "json") else {
      throw CocoaError(.fileNoSuchFile)
    }
    let data = try Data(contentsOf: url)

    struct RegistryPayload: Codable {
      let skills: [RegistrySkill]
    }

    let payload = try JSONDecoder().decode(RegistryPayload.self, from: data)
    self.skills = payload.skills
    self.lastFetched = Date()
    return self.skills
  }
}
