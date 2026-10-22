import Foundation
import Testing
@testable import TinyPruneDomain

@Suite struct RuleTemplateTests {
    private let home = "/Users/example"
    private let day: TimeInterval = 86_400

    @Test func everyTemplateProducesUsableScopedTrashRules() throws {
        for template in RuleTemplate.allCases {
            let folder = template.suggestedFolders.first.map { home + $0.path.dropFirst() } ?? home + "/Work"
            _ = try ManagedRoot(displayName: template.title, path: folder, bookmarkData: Data([1]))
            let rules = try template.rules(in: folder, state: .preview)
            #expect(!rules.isEmpty)
            for rule in rules {
                #expect(rule.scope.path == folder)
                #expect(rule.matchMode == .scoped)
                #expect(rule.action == .trashItem)
                #expect(rule.state == .preview)
                #expect(rule.lifetime.seconds > 0)
                #expect(rule.scope.relativePath(of: folder) == nil)
                #expect(rule.scope.relativePath(of: folder + "-other/item") == nil)
                _ = try JSONDecoder().decode(LifetimeRule.self, from: JSONEncoder().encode(rule))
            }
        }
    }

    @Test func appPresetsHaveConservativeShapesAndPreviewEnforcement() throws {
        let presets: [(RuleTemplate, String, TimeInterval, ItemKind, Bool)] = [
            (.xcodeDerivedData, "~/Library/Developer/Xcode/DerivedData", 60, .directory, false),
            (.xcodeDeviceSupport, "~/Library/Developer/Xcode/iOS DeviceSupport", 180, .directory, false),
            (.homebrewDownloads, "~/Library/Caches/Homebrew/downloads", 90, .file, true),
            (.npmCache, "~/.npm/_cacache", 90, .file, true),
            (.yarnClassicCache, "~/Library/Caches/Yarn", 90, .file, true),
            (.pipCache, "~/Library/Caches/pip", 90, .file, true),
            (.cargoRegistryCache, "~/.cargo/registry/cache", 90, .file, true),
            (.gradleCaches, "~/.gradle/caches", 90, .file, true),
            (.agentSessionLogs, "~/.claude/projects", 60, .file, true),
            (.agentEditBackups, "~/.claude/file-history", 30, .file, true),
        ]
        for (template, suggestion, days, kind, recursive) in presets {
            #expect(template.suggestedFolders.first?.path == suggestion)
            #expect(template.isBroad)
            let folder = home + suggestion.dropFirst()
            let rules = try template.rules(in: folder, state: .active)
            #expect(rules.count == 1)
            let rule = try #require(rules.first)
            #expect(rule.state == .preview)
            #expect(rule.expiryBasis == .modified)
            #expect(rule.lifetime.seconds == days * day)
            #expect(rule.matcher.itemKind == kind)
            #expect(rule.scope.recursive == recursive)
            #expect(try template.rules(in: folder, state: .paused).allSatisfy { $0.state == .paused })
        }
        for template in [RuleTemplate.downloads, .screenshots, .temporaryWorkspace] {
            #expect(!template.isBroad)
            #expect(template.suggestedFolders.isEmpty)
            #expect(try template.rules(in: home + "/Work", state: .active).allSatisfy { $0.state == .active })
        }
        for template in [RuleTemplate.developerCleanup, .buildArtifacts, .agentDebugLogs] {
            #expect(template.isBroad)
            #expect(template.suggestedFolders.isEmpty == (template != .agentDebugLogs))
            #expect(try template.rules(in: home + "/Work", state: .active).allSatisfy { $0.state == .preview })
        }
    }

    @Test func agentTemplatesTargetOnlyTheirLogAndTranscriptFiles() throws {
        let sessions = try #require(RuleTemplate.agentSessionLogs.rules(in: home + "/.claude/projects", state: .preview).first)
        #expect(sessions.matcher.matches(name: "abc.jsonl", relativePath: "proj/abc.jsonl", kind: .file))
        #expect(!sessions.matcher.matches(name: "settings.json", relativePath: "proj/settings.json", kind: .file))
        #expect(!sessions.matcher.matches(name: "abc.jsonl", relativePath: "proj/abc.jsonl", kind: .directory))
        let logs = try #require(RuleTemplate.agentDebugLogs.rules(in: home + "/Work", state: .active).first)
        #expect(logs.state == .preview)
        for name in ["debug.log", "run.trace"] { #expect(logs.matcher.matches(name: name, relativePath: "a/" + name, kind: .file)) }
        for name in ["notes.md", "main.swift", "log"] { #expect(!logs.matcher.matches(name: name, relativePath: name, kind: .file)) }
    }

    @Test func everySuggestedAgentFolderIsAUsableRootAndNamed() throws {
        for template in RuleTemplate.allCases {
            let paths = template.suggestedFolders.map(\.path)
            #expect(Set(paths).count == paths.count)
            #expect(Set(template.suggestedFolders.map(\.name)).count == paths.count)
            for folder in template.suggestedFolders {
                #expect(!folder.name.isEmpty)
                #expect(folder.path.hasPrefix("~/"))
                _ = try ManagedRoot(displayName: folder.name, path: home + folder.path.dropFirst(), bookmarkData: Data([1]))
            }
        }
        let sessionTools = Set(RuleTemplate.agentSessionLogs.suggestedFolders.map(\.name))
        #expect(sessionTools.isSuperset(of: ["Claude Code", "Codex", "OMP", "pi"]))
        #expect(Set(RuleTemplate.agentDebugLogs.suggestedFolders.map(\.name)).isSuperset(of: ["OMP", "Codex"]))
    }

    @Test func sessionRuleCoversNestedAndCompressedTranscriptsButNotAgentMemory() throws {
        let rule = try #require(RuleTemplate.agentSessionLogs.rules(in: home + "/.codex/sessions", state: .preview).first)
        #expect(rule.scope.recursive)
        for path in ["2026/07/12/rollout-2026-07-12T19-59-10-abc.jsonl", "2026/07/12/rollout-x.jsonl.zst", "-Users-me-proj/uuid.jsonl"] {
            let name = String(path.split(separator: "/").last!)
            #expect(rule.matcher.matches(name: name, relativePath: path, kind: .file))
        }
        // Claude keeps hand-curated memory and spilled tool output beside transcripts; neither is a transcript.
        for path in ["-Users-me-proj/memory/MEMORY.md", "-Users-me-proj/uuid/tool-results/out.json", "state_5.sqlite", "session_index.jsonl.bak"] {
            let name = String(path.split(separator: "/").last!)
            #expect(!rule.matcher.matches(name: name, relativePath: path, kind: .file))
        }
    }

    @Test func debugLogRuleAgesOutOmpToolOutputButNeverReportsTranscriptsOrImages() throws {
        let rule = try #require(RuleTemplate.agentDebugLogs.rules(in: home + "/.omp/agent/sessions", state: .preview).first)
        let session = "-proj/2026-10-10T02-14-45-018Z_abc"
        #expect(rule.matcher.matches(name: "5.bash.log", relativePath: session + "/5.bash.log", kind: .file))
        for path in [session + ".jsonl", session + "/ModelComparison.md", session + "/local/ai-comparison.json", session + "/local/pasted-image-1.png", "-proj/." + "x.jsonl.lock.os"] {
            let name = String(path.split(separator: "/").last!)
            #expect(!rule.matcher.matches(name: name, relativePath: path, kind: .file))
        }
    }

    @Test func cacheGlobsExcludeIncompleteAndUnrelatedFiles() throws {
        let brew = try #require(RuleTemplate.homebrewDownloads.rules(in: home + "/Library/Caches/Homebrew/downloads", state: .preview).first)
        for path in ["hash--package.tar.gz", "hash--app.dmg", "hash--package.zip"] {
            #expect(brew.matcher.matches(name: path, relativePath: path, kind: .file))
        }
        for path in ["hash--package.tar.gz.incomplete", "hash--package.zip.partial", "package.zip", "nested/hash--package.zip", "hash--notes.txt"] {
            #expect(!brew.matcher.matches(name: path, relativePath: path, kind: .file))
        }
        #expect(!brew.matcher.matches(name: "hash--package.zip", relativePath: "hash--package.zip", kind: .directory))
        let cargo = try #require(RuleTemplate.cargoRegistryCache.rules(in: home + "/.cargo/registry/cache", state: .preview).first)
        #expect(cargo.matcher.matches(name: "serde.crate", relativePath: "registry/serde.crate", kind: .file))
        #expect(!cargo.matcher.matches(name: "serde.crate.partial", relativePath: "registry/serde.crate.partial", kind: .file))
        #expect(!cargo.matcher.matches(name: "credentials.toml", relativePath: "credentials.toml", kind: .file))
        #expect(!cargo.matcher.matches(name: "serde.crate", relativePath: "registry/serde.crate", kind: .directory))
    }

    @Test func xcodeOnlyTargetsImmediateChildDirectories() throws {
        for template in [RuleTemplate.xcodeDerivedData, .xcodeDeviceSupport] {
            let folder = home + (try #require(template.suggestedFolders.first)).path.dropFirst()
            let rule = try #require(template.rules(in: folder, state: .preview).first)
            #expect(rule.scope.relativePath(of: folder + "/Project-cache") == "Project-cache")
            #expect(rule.scope.relativePath(of: folder + "/Project-cache/Build") == nil)
            #expect(rule.matcher.matches(name: "Project-cache", relativePath: "Project-cache", kind: .directory))
            #expect(!rule.matcher.matches(name: "notes.txt", relativePath: "notes.txt", kind: .file))
        }
    }
}
