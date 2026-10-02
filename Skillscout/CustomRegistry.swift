import Foundation

struct CustomRegistry {
    static let shared = CustomRegistry()
    private let url = Paths.home.appending(path: ".config/skillscout/custom-registry.json")

    enum SourceError: LocalizedError {
        case invalidFolder

        var errorDescription: String? {
            "Choose a folder containing at least one SKILL.md file."
        }
    }

    func fetch() -> [RegistrySkill] {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode([RegistrySkill].self, from: data) else {
            return []
        }
        return payload
    }

    @discardableResult
    func add(repoURL: String) throws -> String {
        let source = try normalizedSource(repoURL)
        var skills = fetch()
        // Avoid duplicates
        if !skills.contains(where: { $0.repo == source }) {
            let isLocal = source.hasPrefix("/")
            let name = isLocal ? URL(fileURLWithPath: source).lastPathComponent
                : (URL(string: source)?.lastPathComponent.replacingOccurrences(of: ".git", with: "") ?? source)
            let newSkill = RegistrySkill(name: name, description: isLocal ? "Local skills folder" : "Custom skill repository", repo: source, tools: nil, author: "Custom")
            skills.append(newSkill)

            let data = try JSONEncoder().encode(skills)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return source
    }

    private func normalizedSource(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("https://") || value.hasPrefix("http://") || value.hasPrefix("git@") { return value }
        let path = value.hasPrefix("file://") ? (URL(string: value)?.path ?? value) : value
        guard path.hasPrefix("/") || path.hasPrefix("~/") else { throw SourceError.invalidFolder }
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw SourceError.invalidFolder
        }
        var hasSkill = false
        while let item = enumerator.nextObject() as? URL {
            if item.lastPathComponent == "node_modules" { enumerator.skipDescendants() }
            if item.lastPathComponent == "SKILL.md" { hasSkill = true; break }
        }
        guard hasSkill else { throw SourceError.invalidFolder }
        return folder.path
    }

    func remove(id: String) throws {
        var skills = fetch()
        skills.removeAll { $0.id == id }
        let data = try JSONEncoder().encode(skills)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
