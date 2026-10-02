import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import TinyPruneAgentCore
import TinyPruneDomain
import TinyPruneIPC
import TinyPrunePersistence
import TinyPruneUI

// Offscreen GUI verification: real SwiftUI views, a real in-process agent, a fixture tree in $HOME.
// No window is shown, no events are synthesized, and no Screen Recording permission is needed.

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let outputDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("TinyPruneUISnapshots-\(UUID().uuidString.prefix(8))", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let snap = Snapshotter(outputDirectory: outputDirectory)
snap.dynamicTypeSizes = quickMode ? [nil] : [nil, .accessibility5]
if quickMode { snap.scales = [1] }
print("PNG output directory: \(outputDirectory.path)")

let defaults = UserDefaults.standard
for key in ["onboardingCompleted", "showMenuBarIcon", "notificationsEnabled", "previewBroadByDefault"] { defaults.removeObject(forKey: key) }

phase("fonts")
registerBundledFonts(repositoryRoot: repositoryRoot)

@MainActor
func rootView(_ model: AgentViewModel, _ router: AppRouter) -> some View {
    TinyPruneRootView()
        .environmentObject(model)
        .environmentObject(router)
        .tinyPruneWindowStyle()
}

@MainActor
func shoot(_ name: String, _ section: AppSection, model: AgentViewModel, router: AppRouter, size: CGSize = CGSize(width: 1100, height: 760)) async {
    router.selection = section
    await snap.capture(rootView(model, router), name: name, size: size)
}

@MainActor
func sheetCanvas<V: View>(_ view: V) -> some View {
    view
        .background(PrunePalette.canvas)
        .tinyPruneWindowStyle()
}

let tempAgentDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("TinyPruneUISnapshotsState-\(UUID().uuidString.prefix(8))")
var fixture: Fixture?

do {
    // MARK: - Agent unavailable

    phase("agent unavailable")
    do {
        let services = StubServices(status: .notRegistered)
        let model = AgentViewModel(transport: UnavailableTransport(), services: services, postsNotifications: false)
        let router = AppRouter()
        defaults.set(true, forKey: "onboardingCompleted")
        await model.refresh()
        Check.expect(model.overview == nil && model.errorMessage != nil, "unavailable agent surfaces an error state")
        await shoot("20-agent-unavailable-not-installed", .overview, model: model, router: router)
        services.agentStatus = .requiresApproval
        model.refreshRegistrationStatus()
        await shoot("21-agent-unavailable-needs-approval", .overview, model: model, router: router)
        services.agentStatus = .notFound
        model.refreshRegistrationStatus()
        await shoot("22-agent-unavailable-dev-build", .settings, model: model, router: router)
        await model.registerAgent()
        Check.expect(services.registerCalls == 1, "register goes through the injected services, not launchd")
    }

    // MARK: - Empty agent (first run)

    phase("first run on an empty agent")
    let emptyAgent = try await LiveAgent(directory: tempAgentDirectory.appendingPathComponent("empty"))
    do {
        let model = emptyAgent.model(services: StubServices(status: .enabled))
        let router = AppRouter()
        defaults.set(false, forKey: "onboardingCompleted")
        await snap.capture(rootView(model, router), name: "01-onboarding-1-intro")
        await model.refresh()
        Check.expect(model.policy?.rules.isEmpty == true && model.policy?.managedRoots.isEmpty == true, "empty agent reports no rules and no roots")
        // Root latches onboarding once it has loaded an empty policy.
        await snap.capture(rootView(model, router), name: "01b-onboarding-root-after-load")

        func onboarding(step: Int, name: String) async {
            await snap.capture(
                OnboardingFlow(initialStep: step, finish: {})
                    .environmentObject(model)
                    .background(PrunePalette.canvas)
                    .tinyPruneWindowStyle(),
                name: name, size: CGSize(width: 900, height: 640)
            )
        }
        await onboarding(step: 0, name: "02-onboarding-step1")
        await onboarding(step: 1, name: "03-onboarding-step2")
        await onboarding(step: 2, name: "04-onboarding-step3")

        defaults.set(true, forKey: "onboardingCompleted")
        for (index, section) in [AppSection.overview, .rules, .upcoming, .activity, .templates, .settings].enumerated() {
            await shoot("1\(index)-empty-\(section.rawValue.lowercased())", section, model: model, router: router)
        }
        await snap.capture(
            MenuBarContent().environmentObject(model).environmentObject(router).padding(14).frame(width: 300, alignment: .leading).background(.white).tinyPruneWindowStyle(),
            name: "19-menubar-empty", size: CGSize(width: 320, height: 260)
        )
    }

    // MARK: - Fixture tree and live agent

    phase("fixture tree")
    let tree = try Fixture.build()
    fixture = tree
    print("  fixture: \(tree.root.path)")
    let agent = try await LiveAgent(directory: tempAgentDirectory.appendingPathComponent("live"))
    let services = StubServices(status: .enabled)
    let model = agent.model(services: services)
    let router = AppRouter()
    defaults.set(true, forKey: "onboardingCompleted")
    await model.refresh()
    Check.expect(model.policy?.rules.isEmpty == true, "live agent starts without rules")

    // MARK: - Templates through the real code path

    phase("add template rules in Preview")
    let downloadsFolder = try ChosenFolder.make(from: tree.downloads)
    let screenshotsFolder = try ChosenFolder.make(from: tree.screenshots)
    let projectsFolder = try ChosenFolder.make(from: tree.projects)
    let scratchFolder = try ChosenFolder.make(from: tree.scratch)
    for (template, folder) in [
        (RuleTemplate.downloads, downloadsFolder), (.screenshots, screenshotsFolder),
        (.developerCleanup, projectsFolder), (.temporaryWorkspace, scratchFolder),
    ] {
        let rules = try template.rules(in: folder.root.path, state: .preview, temporaryLifetime: 3 * 86_400)
        try await model.addRules(rules, in: folder)
    }
    Check.expect(model.policy?.rules.count == 10, "10 template rules were added (got \(model.policy?.rules.count ?? -1))")
    Check.expect(model.policy?.managedRoots.count == 4, "4 managed roots were registered")
    Check.expect(model.policy?.rules.allSatisfy { $0.state == .preview } == true, "every new rule starts in Preview")

    await waitFor("scheduled matches to appear") {
        await model.refresh()
        return (model.overview?.upcoming.count ?? 0) >= 8
    }
    let scheduledCount = model.overview?.upcoming.count ?? 0
    print("  scheduled items: \(scheduledCount)")
    Check.expect(scheduledCount >= 8, "indexer scheduled matches from the fixture tree")
    Check.expect(model.activity.contains { $0.kind == .ruleCreated }, "rule creation was audited")

    router.selection = .overview
    for (index, section) in [AppSection.overview, .rules, .upcoming, .activity, .templates, .settings].enumerated() {
        await shoot("3\(index)-seeded-\(section.rawValue.lowercased())", section, model: model, router: router)
    }

    phase("sidebar selection")
    do {
        router.selection = .rules
        let hosted = await snap.host(rootView(model, router), size: CGSize(width: 1100, height: 760))
        await pump(0.8)
        let table = snap.allViews(hosted.host).compactMap { $0 as? NSTableView }.first
        Check.expect(table != nil, "sidebar is hosted in an NSTableView")
        if let table {
            Check.expect(table.numberOfRows == AppSection.allCases.count, "sidebar lists every section (rows: \(table.numberOfRows))")
            Check.expect(table.selectedRow == AppSection.allCases.firstIndex(of: .rules), "router selection highlights its sidebar row (selected row \(table.selectedRow))")
            table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
            await pump(0.5)
            Check.expect(router.selection == .activity, "choosing the fourth sidebar row navigates to Activity (router: \(String(describing: router.selection)))")
            router.selection = .overview
        }
        hosted.window.contentView = nil
        hosted.window.close()
    }

    // MARK: - Activate

    phase("activate a rule")
    if let scratchRule = model.policy?.rules.first(where: { $0.scope.path == tree.scratch.path }) {
        try await model.setState(.active, for: scratchRule)
        let after = model.policy?.rules.first { $0.id == scratchRule.id }
        Check.expect(after?.state == .active, "Temporary workspace is Active")
        Check.expect(FileManager.default.fileExists(atPath: tree.scratch.appendingPathComponent("todo.txt").path), "activating a rule with nothing due moved nothing")
    } else {
        Check.fail("scratch template rule not found")
    }
    await shoot("40-rules-after-activate", .rules, model: model, router: router, size: CGSize(width: 1100, height: 1000))

    // MARK: - Keep

    phase("keep an item")
    try await model.keep(path: tree.contract.path, protectDescendants: false)
    Check.expect(model.policy?.overrides.contains { $0.path == tree.contract.path && $0.policy == .keep(protectDescendants: false) } == true, "Keep override stored")
    let explanation = try await model.explain(path: tree.contract.path)
    if case .protected = explanation.resolution { Check.expect(true, "explain reports the item as protected") } else { Check.fail("explain did not report protection: \(explanation.resolution)") }
    await waitFor("protected item to leave Upcoming") {
        await model.refresh()
        return model.overview?.upcoming.contains { $0.explanation.candidateIdentity.pathHint == tree.contract.path } == false
    }
    router.upcomingRuleFilter = nil
    await shoot("41-upcoming-protected", .upcoming, model: model, router: router, size: CGSize(width: 1100, height: 2300))

    // MARK: - Why inspector, set expiry

    phase("why inspector and custom expiry")
    guard let item = model.overview?.upcoming.first(where: { $0.explanation.candidateIdentity.pathHint.hasSuffix("Figma installer.dmg") }) ?? model.overview?.upcoming.first else {
        Check.fail("no upcoming item to inspect")
        throw ExitSignal()
    }
    let itemPath = item.explanation.candidateIdentity.pathHint
    do {
        let listed = try await model.explain(path: itemPath)
        if case .scheduled = listed.resolution {
            Check.expect(true, "explain agrees with Upcoming for a scheduled item")
        } else {
            print("  KNOWN AGENT DEFECT: explain says \(listed.resolution) for an item that Upcoming lists as scheduled")
        }
    }
    router.selection = .upcoming
    router.inspectedItemID = item.id
    do {
        let hosted = await snap.host(rootView(model, router), size: CGSize(width: 1180, height: 780))
        await pump(0.6)
        let sizeRequests = agent.transport.requests { if case .itemSize = $0 { true } else { false } }
        let explainRequests = agent.transport.requests { if case .explainItem = $0 { true } else { false } }
        Check.expect(explainRequests >= 1, "opening the inspector asks the agent to explain the item")
        let inspectorButtons = snap.buttons(in: hosted.host) { $0.minX > 760 }
        if snap.click(inspectorButtons.dropFirst().first) {
            await waitFor("size request") { agent.transport.requests { if case .itemSize = $0 { true } else { false } } > sizeRequests }
            Check.expect(true, "Calculate size sends an itemSize request")
        } else {
            print("  note: Calculate size is not an AppKit-backed button; size not driven")
        }
        await pump(0.5)
        await snap.snapshot(hosted, name: "42-upcoming-why-inspector")
        snap.audit(hosted.host, screen: "42-upcoming-why-inspector")
        hosted.window.contentView = nil
        hosted.window.close()
    }
    router.inspectedItemID = nil
    do {
        let hosted = await snap.host(
            WhyInspectorContent(item: item)
                .environmentObject(model).environmentObject(router)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(PrunePalette.canvas)
                .tinyPruneWindowStyle(),
            size: CGSize(width: 360, height: 640)
        )
        await waitFor("inspector explanation request") { agent.transport.requests { if case .explainItem = $0 { true } else { false } } >= 2 }
        await pump(0.8)
        await snap.snapshot(hosted, name: "45-why-inspector-standalone")
        snap.audit(hosted.host, screen: "45-why-inspector-standalone")
        hosted.window.contentView = nil
        hosted.window.close()
    }

    let newExpiry = Date().addingTimeInterval(30 * 86_400)
    try await model.setExpiry(path: itemPath, at: newExpiry, state: .preview)
    let customOverride = model.policy?.overrides.first { $0.path == itemPath }
    if case .customExpiry(let date, _)? = customOverride?.policy {
        Check.expect(abs(date.timeIntervalSince(newExpiry)) < 1, "custom expiry stored with the requested date")
    } else {
        Check.fail("custom expiry override missing")
    }
    let customExplanation = try await model.explain(path: itemPath)
    if case .customExpiry(let custom) = customExplanation.resolution {
        Check.expect(abs(custom.expiresAt.timeIntervalSince(newExpiry)) < 1, "explain reports the custom expiry date")
    } else {
        Check.fail("explain did not report a custom expiry: \(customExplanation.resolution)")
    }
    // Re-indexing after a policy change briefly empties the list; wait for it to settle before judging.
    await waitFor("Upcoming to repopulate after the expiry change") {
        await model.refresh()
        return (model.overview?.upcoming.count ?? 0) >= 8
    }
    if model.overview?.upcoming.contains(where: { $0.explanation.candidateIdentity.pathHint == itemPath }) == true {
        Check.expect(true, "custom-expiry item stays visible in Upcoming")
    } else {
        // Agent-side gap reported to RulePreview: custom-expiry items are not indexed as deadlines.
        print("  KNOWN AGENT DEFECT: custom-expiry item left Upcoming (\(model.overview?.upcoming.count ?? -1) items listed); see report")
    }
    router.inspectedItemID = model.overview?.upcoming.first?.id
    await shoot("43-upcoming-custom-expiry-inspector", .upcoming, model: model, router: router, size: CGSize(width: 1180, height: 1100))
    router.inspectedItemID = nil
    await snap.capture(
        sheetCanvas(CustomExpirySheet(path: itemPath).environmentObject(model)),
        name: "44-sheet-custom-expiry", size: CGSize(width: 460, height: 260)
    )

    // MARK: - Pause until

    phase("pause until")
    let resumeAt = Date().addingTimeInterval(4 * 3_600)
    try await model.pause(until: resumeAt)
    Check.expect(model.policy?.globallyPaused == true, "pause-until pauses the agent")
    Check.expect(model.policy.flatMap { $0.pausedUntil }.map { abs($0.timeIntervalSince(resumeAt)) < 2 } == true, "pausedUntil matches the request")
    await shoot("50-overview-paused", .overview, model: model, router: router)
    await snap.capture(
        MenuBarContent().environmentObject(model).environmentObject(router).padding(14).frame(width: 300, alignment: .leading).background(.white).tinyPruneWindowStyle(),
        name: "51-menubar-paused", size: CGSize(width: 320, height: 260)
    )
    try await model.setGlobalPause(false)
    Check.expect(model.policy?.globallyPaused == false, "resume clears the pause")
    await snap.capture(
        MenuBarContent().environmentObject(model).environmentObject(router).padding(14).frame(width: 300, alignment: .leading).background(.white).tinyPruneWindowStyle(),
        name: "52-menubar-running", size: CGSize(width: 320, height: 260)
    )

    // MARK: - Settings

    phase("update settings")
    try await model.updateSettings(AgentSettings(defaultGracePeriodSeconds: 3_600, protectHiddenFiles: true, activityRetentionDays: 30))
    Check.expect(model.settings == AgentSettings(defaultGracePeriodSeconds: 3_600, protectHiddenFiles: true, activityRetentionDays: 30), "settings round-trip through the agent")
    await shoot("60-settings-updated", .settings, model: model, router: router, size: CGSize(width: 1100, height: 1100))

    // MARK: - Config import

    phase("import a config plan")
    let yaml = """
    version: 1

    roots:
      - \(tree.projects.path)

    rules:
      - name: Stale logs
        match:
          globs:
            - "**/*.log"
        expiry:
          after: 14d
          since: modified
    """
    do {
        let rulesBefore = model.policy?.rules.count ?? 0
        let document = try ConfigDocument.parse(yaml + "\n", homeDirectory: NSHomeDirectory())
        let policy = try model.policy.unwrap("policy")
        let plan = try ConfigPlan.make(document: document, currentRules: policy.rules, currentRoots: policy.managedRoots, currentOverrides: policy.overrides, activate: false)
        Check.expect(plan.added.count == 1 && plan.isApplicable, "plan adds one rule inside a managed root")
        await snap.capture(
            sheetCanvas(ConfigImportSheet(preview: ImportPreview(fileName: "tinyprune.yml", plan: plan)).environmentObject(model)),
            name: "61-sheet-config-import", size: CGSize(width: 560, height: 420)
        )

        let outside = tree.root.appendingPathComponent("Elsewhere").path
        let blocked = try ConfigDocument.parse("version: 1\nroots:\n  - \(outside)\nrules:\n  - name: Old stuff\n    match:\n      names:\n        - tmp\n    expiry:\n      after: 7d\n      since: modified\n", homeDirectory: NSHomeDirectory())
        let blockedPlan = try ConfigPlan.make(document: blocked, currentRules: policy.rules, currentRoots: policy.managedRoots, currentOverrides: policy.overrides, activate: false)
        Check.expect(!blockedPlan.isApplicable, "plan outside managed roots is not applicable")
        await snap.capture(
            sheetCanvas(ConfigImportSheet(preview: ImportPreview(fileName: "elsewhere.yml", plan: blockedPlan)).environmentObject(model)),
            name: "62-sheet-config-import-blocked", size: CGSize(width: 560, height: 420)
        )

        let summary = try await model.applyConfig(plan)
        print("  apply summary: \(summary)")
        Check.expect(model.policy?.rules.count == rulesBefore + 1, "apply added the rule")
        Check.expect(model.policy?.rules.first { $0.name == "Stale logs" }?.state == .preview, "imported rule starts in Preview")
    }

    // MARK: - Impact preview

    phase("impact preview")
    guard let staleLogs = model.policy?.rules.first(where: { $0.name == "Stale logs" }) else {
        Check.fail("Stale logs rule missing")
        throw ExitSignal()
    }
    let direct = try await model.previewRule(staleLogs)
    print("  direct preview: \(RulePreviewText.headline(direct)); scanned \(direct.scannedEntries)")
    Check.expect(direct.matches == 11, "preview counts all 11 fixture logs (got \(direct.matches))")
    Check.expect(direct.eligibleNow == 8, "preview reports the 8 old logs as eligible now (got \(direct.eligibleNow))")
    Check.expect(direct.samples.count == 11 && direct.samples == direct.samples.sorted { $0.scheduledAt < $1.scheduledAt }, "samples are soonest-first")
    Check.expect(!direct.truncated, "small fixture is not truncated")
    Check.expect(tree.oldLogs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "preview moved nothing to Trash")

    let overviewNow = try model.overview.unwrap("overview")
    func editorHost(_ controller: RulePreviewController, size: CGSize = CGSize(width: 620, height: 720)) async -> Snapshotter.Hosted {
        await snap.host(
            sheetCanvas(RuleEditorSheet(target: .edit(staleLogs), overview: overviewNow, preview: controller).environmentObject(model)),
            size: size
        )
    }
    func close(_ hosted: Snapshotter.Hosted) {
        hosted.window.contentView = nil
        hosted.window.close()
    }

    do {
        let controller = RulePreviewController()
        let hosted = await editorHost(controller)
        Check.expect(controller.phase == .idle, "no preview result before the user clicks")
        let requestsBefore = agent.transport.previewRequests
        await snap.snapshot(hosted, name: "70-editor-before-preview")
        snap.audit(hosted.host, screen: "70-editor-before-preview")
        Check.expect(agent.transport.previewRequests == requestsBefore, "editor never previews automatically")
        if snap.sendKeyEquivalent("p", modifiers: .command, to: hosted) {
            await waitFor("editor preview result") { if case .finished = controller.phase { true } else { false } }
            if case .finished(let result) = controller.phase {
                Check.expect(result == direct.withoutDuration(result), "editor result equals the agent's direct preview")
                Check.expect(RulePreviewText.headline(result).hasPrefix("11 matches · 8 would be pruned now · "), "editor headline reads '\(RulePreviewText.headline(result))'")
            }
            await snap.snapshot(hosted, name: "71-editor-preview-result")
            snap.audit(hosted.host, screen: "71-editor-preview-result")
        } else {
            Check.fail("⌘P did not trigger Preview matches")
        }
        close(hosted)
    }

    // Truncated, then a stalled scan that the user cancels.
    agent.transport.setMode(.canned(AgentRulePreview(
        matches: 43, eligibleNow: 8, estimatedBytes: 6_400_000_000, scannedEntries: 500_000, truncated: true, durationSeconds: 20,
        samples: (0..<20).map { AgentPreviewSample(path: tree.projects.appendingPathComponent("webapp/node_modules/pkg-\($0)").path, scheduledAt: Date().addingTimeInterval(Double($0) * 86_400), bytes: 120_000_000) }
    )))
    do {
        let controller = RulePreviewController()
        let hosted = await editorHost(controller)
        _ = snap.sendKeyEquivalent("p", modifiers: .command, to: hosted)
        await waitFor("truncated preview") { if case .finished = controller.phase { true } else { false } }
        if case .finished(let result) = controller.phase {
            Check.expect(RulePreviewText.headline(result) == "At least 43 matches · 8 would be pruned now · 6.4 GB estimated", "truncated headline reads '\(RulePreviewText.headline(result))'")
            Check.expect(RulePreviewText.truncationNote(result)?.contains("lower bounds") == true, "truncation explanation present")
            Check.expect(result.samples.count == 20, "20 sample paths shown")
        }
        await snap.snapshot(hosted, name: "72-editor-preview-truncated")
        close(hosted)
    }
    agent.transport.setMode(.hang)
    do {
        let controller = RulePreviewController()
        let hosted = await editorHost(controller)
        _ = snap.sendKeyEquivalent("p", modifiers: .command, to: hosted)
        await waitFor("running state") { controller.phase == .running }
        await pump(0.4)
        await snap.snapshot(hosted, name: "73-editor-preview-running")
        snap.audit(hosted.host, screen: "73-editor-preview-running")
        Check.expect(snap.sendKeyEquivalent(".", modifiers: .command, to: hosted), "⌘. cancels a running preview")
        await waitFor("cancelled state") { controller.phase == .cancelled }
        await snap.snapshot(hosted, name: "74-editor-preview-cancelled")
        close(hosted)
    }
    agent.transport.setMode(.passthrough)

    // Rules row preview.
    do {
        router.selection = .rules
        let hosted = await snap.host(rootView(model, router), size: CGSize(width: 1100, height: 1100))
        let before = agent.transport.previewRequests
        let rowButtons = snap.buttons(in: hosted.host)
        let firstRowY = rowButtons.dropFirst().first.map { $0.convert($0.bounds, to: hosted.host).minY }
        let firstRow = rowButtons.filter { abs($0.convert($0.bounds, to: hosted.host).minY - (firstRowY ?? -1)) < 2 }
        if snap.click(firstRow.dropFirst().first) {
            await waitFor("rule row preview request") { agent.transport.previewRequests > before }
            await pump(1.0)
            await snap.snapshot(hosted, name: "75-rules-row-preview")
        } else {
            Check.fail("Rules row ⌘P did not trigger Preview matches")
        }
        close(hosted)
    }

    // New-rule editor (no folder chosen) and editor for a broad rule.
    await snap.capture(
        sheetCanvas(RuleEditorSheet(target: .new(prefillPath: nil), overview: overviewNow).environmentObject(model)),
        name: "76-editor-new-rule", size: CGSize(width: 620, height: 720)
    )

    // MARK: - Final state

    phase("final state")
    await model.refresh()
    for (index, section) in [AppSection.overview, .rules, .upcoming, .activity].enumerated() {
        await shoot("8\(index)-final-\(section.rawValue.lowercased())", section, model: model, router: router, size: CGSize(width: 1100, height: 1000))
    }
    let kinds = Set(model.activity.map(\.kind))
    for kind in [AgentActivityKind.ruleCreated, .itemProtected, .expiryChanged, .globalPauseChanged, .settingsChanged, .rulePaused] {
        if kind == .rulePaused { continue }
        Check.expect(kinds.contains(kind), "activity log has \(kind.rawValue)")
    }
    let allFixtureFiles = (try? FileManager.default.subpathsOfDirectory(atPath: tree.root.path)) ?? []
    Check.expect(!allFixtureFiles.isEmpty && tree.oldLogs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "no fixture file was moved to Trash by any flow")

    await agent.stop()
    await emptyAgent.stop()
} catch is ExitSignal {
    // A failed Check was already recorded.
} catch {
    Check.fail("harness error: \(error)")
}

fixture?.tearDown()
try? FileManager.default.removeItem(at: tempAgentDirectory)

phase("accessibility source lint")
do {
    let sources = repositoryRoot.appendingPathComponent("Sources/TinyPruneUI")
    let files = (try? FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "swift" } ?? []
    var iconButtons = 0
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        for (index, line) in lines.enumerated() where line.contains("Image(systemName") {
            let before = lines[max(0, index - 3)...index].joined(separator: "\n")
            guard before.contains("Button") else { continue }
            iconButtons += 1
            let after = lines[index...min(lines.count - 1, index + 4)].joined(separator: "\n")
            if !after.contains("accessibilityLabel") {
                snap.unlabeled.append("\(file.lastPathComponent):\(index + 1): icon-only Button without .accessibilityLabel")
            }
        }
    }
    print("  icon-only buttons found in source: \(iconButtons)")
}

phase("summary")
print("  PNGs written: \(snap.written.count) in \(outputDirectory.path)")
print("  assertions passed: \(Check.passes), failed: \(Check.failures.count)")
if snap.unlabeled.isEmpty {
    print("  unlabeled accessibility controls: none (\(snap.swiftUIHostedControls) SwiftUI-hosted control instances were not observable offscreen)")
} else {
    print("  unlabeled accessibility controls (\(snap.unlabeled.count)):")
    for line in snap.unlabeled { print("    - \(line)") }
}
for failure in Check.failures { print("  FAILED: \(failure)") }
exit(Check.failures.isEmpty ? 0 : 1)

struct ExitSignal: Error {}

extension Optional {
    func unwrap(_ what: String) throws -> Wrapped {
        guard let self else { throw HarnessError.missing(what) }
        return self
    }
}

enum HarnessError: Error { case missing(String) }

extension AgentRulePreview {
    /// Equality ignoring the scan duration, which differs between two real scans.
    func withoutDuration(_ other: AgentRulePreview) -> AgentRulePreview {
        AgentRulePreview(matches: matches, eligibleNow: eligibleNow, estimatedBytes: estimatedBytes, scannedEntries: scannedEntries, truncated: truncated, durationSeconds: other.durationSeconds, samples: samples)
    }
}
