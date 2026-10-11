import Foundation

@main enum RepositoryBenchmark {
  static func main() async throws {
    let source = URL(fileURLWithPath: CommandLine.arguments[1])
    let clock = ContinuousClock()
    let start = clock.now
    let installed = try await SkillInstaller.install(source: source.path, explicitTools: [])
    let importDuration = start.duration(to: clock.now)
    let scanStart = clock.now
    let count = SkillScanner.scan().count
    let scanDuration = scanStart.duration(to: clock.now)
    var warmScans: [Double] = []
    for _ in 0..<5 {
      let warmStart = clock.now
      guard SkillScanner.scan().count == count else { throw CocoaError(.fileReadCorruptFile) }
      warmScans.append(milliseconds(warmStart.duration(to: clock.now)))
    }
    try "Changed fixture content".write(to: source.appending(path: "skills/skill-0000/helper.txt"), atomically: true, encoding: .utf8)
    let updateStart = clock.now
    let update = try await SkillInstaller.prepareRepoUpdate(name: installed.lastPathComponent)
    let trash = try SkillInstaller.applyRepoUpdate(update)
    let updateDuration = updateStart.duration(to: clock.now)
    for item in trash { try FileManager.default.removeItem(at: item) }
    func milliseconds(_ duration: Duration) -> Double {
      Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    let result: [String: Double] = ["skills": Double(count), "importMS": milliseconds(importDuration),
      "scanMS": milliseconds(scanDuration), "warmScanMS": warmScans.sorted()[2], "updateMS": milliseconds(updateDuration)]
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self))
  }
}
