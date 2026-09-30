import Foundation

let fileManager = FileManager.default
let fixtureRoot = fileManager.temporaryDirectory
    .appendingPathComponent("TinyPrune-Phase0-Trash-\(UUID().uuidString)", isDirectory: true)
let fixture = fixtureRoot.appendingPathComponent("candidate.txt", isDirectory: false)

try fileManager.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
try Data("TinyPrune phase zero fixture".utf8).write(to: fixture)

defer {
    try? fileManager.removeItem(at: fixtureRoot)
}

var trashedURL: NSURL?
try fileManager.trashItem(at: fixture, resultingItemURL: &trashedURL)

guard !fileManager.fileExists(atPath: fixture.path),
      let trashedURL = trashedURL as URL?,
      fileManager.fileExists(atPath: trashedURL.path) else {
    throw NSError(domain: "TinyPrunePhase0", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture was not moved to Trash"])
}

print("Trash smoke passed: \(trashedURL.path)")
