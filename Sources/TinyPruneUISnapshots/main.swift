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
do {
    let canonical = try String(contentsOf: repositoryRoot.appendingPathComponent("website/assets/tinyprune-plum.svg"), encoding: .utf8)
    Check.expect(canonical.trimmingCharacters(in: .whitespacesAndNewlines) == BrandMark.svg.trimmingCharacters(in: .whitespacesAndNewlines), "in-app brand mark is identical to the canonical website/app-icon SVG")
}

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
var fixtureTrashPaths: [String] = []

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
        // Onboarding is reactive: an empty, loaded policy needs it until it is completed.
        Check.expect(model.needsOnboarding, "an empty loaded policy needs onboarding")
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
            MenuBarContent().environmentObject(model).environmentObject(router),
            name: "19-menubar-empty", size: CGSize(width: 320, height: 380)
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
        try await model.addRules(rules, folders: [folder])
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
    snap.colorScheme = .dark
    for section in [AppSection.overview, .rules, .upcoming, .activity, .templates, .settings] {
        await shoot("36-dark-\(section.rawValue.lowercased())", section, model: model, router: router)
    }
    await snap.capture(
        OnboardingFlow(initialStep: 0, finish: {}).environmentObject(model).background(PrunePalette.canvas).tinyPruneWindowStyle(),
        name: "36-dark-onboarding", size: CGSize(width: 900, height: 640)
    )
    snap.colorScheme = .light

    phase("sidebar selection")
    do {
        router.selection = .rules
        let hosted = await snap.host(rootView(model, router), size: CGSize(width: 1100, height: 760))
        await pump(0.8)
        for (index, section) in AppSection.allCases.enumerated() {
            let key = String(index + 1)
            Check.expect(snap.sendKeyEquivalent(key, modifiers: .command, to: hosted), "sidebar shortcut ⌘\(key) is available")
            await pump(0.15)
            Check.expect(router.selection == section, "sidebar shortcut navigates to \(section.rawValue)")
        }
        router.selection = .overview
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
            Check.fail("Why and Upcoming disagree: \(listed.resolution)")
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
            // Which hosted view receives the click depends on the macOS SwiftUI version, so a missing request is a note.
            // The item-size contract itself is asserted by TinyPruneEngineCheck.
            _ = await waitUntil(timeout: 3) { agent.transport.requests { if case .itemSize = $0 { true } else { false } } > sizeRequests }
            let sizeSent = agent.transport.requests { if case .itemSize = $0 { true } else { false } } > sizeRequests
            print(sizeSent ? "  ok   Calculate size sends an itemSize request" : "  note: click did not reach Calculate size on this macOS; size contract is covered by TinyPruneEngineCheck")
        } else {
            print("  note: Calculate size is not an AppKit-backed button; size not driven")
        }
        await pump(0.5)
        await snap.snapshot(hosted, name: "42-upcoming-why-inspector")
        snap.colorScheme = .dark
        let darkInspector = await snap.host(rootView(model, router), size: CGSize(width: 1180, height: 780))
        await snap.snapshot(darkInspector, name: "42-dark-upcoming-why-inspector")
        darkInspector.window.contentView = nil
        darkInspector.window.close()
        snap.colorScheme = .light
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
    Check.expect(model.overview?.upcoming.contains(where: { $0.explanation.candidateIdentity.pathHint == itemPath }) == true, "custom-expiry item stays visible in Upcoming")
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
        MenuBarContent().environmentObject(model).environmentObject(router),
        name: "51-menubar-paused", size: CGSize(width: 320, height: 460)
    )
    try await model.setGlobalPause(false)
    Check.expect(model.policy?.globallyPaused == false, "resume clears the pause")
    await snap.capture(
        MenuBarContent().environmentObject(model).environmentObject(router),
        name: "52-menubar-running", size: CGSize(width: 320, height: 460)
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

        // Save a real exported backup, remove one disposable rule, then restore through the review sheet.
        let backupPolicy = try model.policy.unwrap("backup policy")
        let backupURL = tree.root.appendingPathComponent("rules-backup.yml")
        let fullExport = try ConfigExportReview(policy: backupPolicy)
        Check.expect(fullExport.exportedCount == 0 && fullExport.skippedCount == backupPolicy.rules.count, "multi-root config export honestly reports all unrepresentable rules as skipped")
        Check.expect(fullExport.omissions.contains { $0.contains("Stale logs") && $0.contains("not to every root") }, "partial export explains the skipped rule name and subset-of-roots reason")
        let backedUpRule = try backupPolicy.rules.first { $0.name == "Stale logs" }.unwrap("backed-up rule")
        let supportedPolicy = AgentPolicySnapshot(
            rules: [backedUpRule], overrides: [],
            managedRoots: backupPolicy.managedRoots.filter { $0.path == tree.projects.path }, globallyPaused: false
        )
        let supportedExport = try ConfigExportReview(policy: supportedPolicy)
        Check.expect(supportedExport.exportedCount == 1 && supportedExport.skippedCount == 0, "supported one-root export reports exactly one restorable rule")
        try supportedExport.text.write(to: backupURL, atomically: true, encoding: .utf8)
        try await model.delete(backedUpRule)
        let backupDocument = try ConfigDocument.parse(String(contentsOf: backupURL, encoding: .utf8), homeDirectory: NSHomeDirectory())
        try backupDocument.validate()
        let current = try model.policy.unwrap("restore policy")
        let restorePlan = try ConfigPlan.make(document: backupDocument, currentRules: current.rules, currentRoots: current.managedRoots, currentOverrides: current.overrides, activate: false)
        Check.expect(restorePlan.isApplicable && restorePlan.added.contains { $0.name == "Stale logs" }, "exported backup restores the missing rule")
        var imported = false
        let restoreHost = await snap.host(
            sheetCanvas(ConfigImportSheet(preview: ImportPreview(fileName: backupURL.lastPathComponent, plan: restorePlan)) { imported = true }.environmentObject(model)),
            size: CGSize(width: 650, height: 600)
        )
        Check.expect(model.policy?.rules.contains { $0.name == "Stale logs" } == false, "reviewing a backup does not overwrite rules before confirmation")
        await snap.snapshot(restoreHost, name: "63-sheet-restore-export")
        Check.expect(snap.sendKeyEquivalent("\r", modifiers: [], to: restoreHost), "Return confirms the reviewed rule backup")
        await waitFor("backup restore") { imported }
        Check.expect(model.policy?.rules.first { $0.name == "Stale logs" }?.state == .preview, "confirmed backup restores the rule in Preview")
        restoreHost.window.contentView = nil
        restoreHost.window.close()
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
            }
            await snap.snapshot(hosted, name: "71-editor-preview-result")
            snap.audit(hosted.host, screen: "71-editor-preview-result")
            snap.colorScheme = .dark
            let darkPreviewHost = await editorHost(controller)
            Check.expect(snap.sendKeyEquivalent("p", modifiers: .command, to: darkPreviewHost), "dark editor supports keyboard Preview")
            await waitFor("dark editor preview result") { if case .finished = controller.phase { true } else { false } }
            await snap.snapshot(darkPreviewHost, name: "71-dark-editor-preview-result")
            close(darkPreviewHost)
            snap.colorScheme = .light
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
            let driven = await waitUntil(timeout: 3) { agent.transport.previewRequests > before }
            if driven {
                await pump(1.0)
                await snap.snapshot(hosted, name: "75-rules-row-preview")
            } else {
                print("  note: row click did not reach Preview on this macOS; keyboard Preview is asserted in the editor flow")
            }
        } else {
            print("  note: Rules row buttons are not AppKit-backed on this macOS; keyboard Preview is asserted in the editor flow")
        }
        close(hosted)
    }

    // New-rule editor (no folder chosen) and editor for a broad rule.
    await snap.capture(
        sheetCanvas(RuleEditorSheet(target: .new(prefillPath: nil), overview: overviewNow).environmentObject(model)),
        name: "76-editor-new-rule", size: CGSize(width: 620, height: 720)
    )

    // MARK: - Broad rules, atomic editor save, conflicts

    phase("broad rules, atomic save, conflicts")
    do {
        let everything = try LifetimeRule(
            name: "Everything", scope: RuleScope(path: tree.projects.path, recursive: true),
            matcher: ItemMatcher(itemKind: .fileOrDirectory, exactNames: [], globPatterns: []),
            expiryBasis: .modified, lifetime: RuleDuration(seconds: 86_400), action: .trashItem, state: .preview
        )
        Check.expect(everything.isBroad && !everything.isVeryBroad, "an empty matcher over a recursive scope is broad, not very broad")
        let homeRule = try LifetimeRule(
            name: "Home", scope: RuleScope(path: NSHomeDirectory(), recursive: true),
            matcher: ItemMatcher(itemKind: .file, exactNames: [], globPatterns: ["*.tinyprune-never"]),
            expiryBasis: .modified, lifetime: RuleDuration(seconds: 86_400), action: .trashItem, state: .preview
        )
        Check.expect(homeRule.isVeryBroad && homeRule.isBroad, "a rule over the home folder is very broad (no Active option)")
        Check.expect(!staleLogs.isVeryBroad, "a specific project folder is not very broad")

        // One atomic editor save: the rule edit and its exception land together; removing the exception is atomic too.
        let exceptionPath = try tree.oldLogs.first.unwrap("an old log").path
        let edited = try LifetimeRule(
            id: staleLogs.id, name: "Stale logs (edited)", scope: staleLogs.scope, matcher: staleLogs.matcher,
            expiryBasis: staleLogs.expiryBasis, lifetime: staleLogs.lifetime, gracePeriod: staleLogs.gracePeriod,
            action: staleLogs.action, state: staleLogs.state, matchMode: staleLogs.matchMode
        )
        try await model.saveRule(edited, folder: nil, keepPaths: [exceptionPath], unkeepPaths: [])
        Check.expect(model.policy?.rules.first { $0.id == staleLogs.id }?.name == "Stale logs (edited)", "saveRule stored the edited rule")
        Check.expect(model.overrides(under: staleLogs.scope.path).contains { $0.path == exceptionPath }, "saveRule stored the exception; the editor can load it back")
        Check.expect(model.policy?.rules.first { $0.id == staleLogs.id }?.state == staleLogs.state, "editing preserves the rule's state (no silent demotion)")

        // Stale revisions are retried transparently up to three times, then surfaced.
        agent.transport.injectPolicyConflicts(2)
        try await model.saveRule(staleLogs, folder: nil, keepPaths: [], unkeepPaths: [exceptionPath])
        Check.expect(model.policy?.rules.first { $0.id == staleLogs.id }?.name == staleLogs.name, "saveRule retries past two policy conflicts")
        Check.expect(!model.overrides(under: staleLogs.scope.path).contains { $0.path == exceptionPath }, "removing an exception is part of the same save")
        agent.transport.injectPolicyConflicts(10)
        do {
            try await model.saveRule(edited, folder: nil, keepPaths: [], unkeepPaths: [])
            Check.fail("saveRule should surface persistent policy conflicts")
        } catch {
            Check.expect(model.policy?.rules.first { $0.id == staleLogs.id }?.name == staleLogs.name, "a failed save leaves the stored rule untouched")
        }
        agent.transport.injectPolicyConflicts(0)

        // A failed refresh keeps the last good overview instead of blanking the UI.
        agent.transport.setOverviewFailing(true)
        await model.refresh()
        Check.expect(model.overview != nil && model.connectionIssue != nil, "a failed refresh keeps the last good overview and reports a connection issue")
        agent.transport.setOverviewFailing(false)
        await model.refresh()
        Check.expect(model.connectionIssue == nil, "the connection issue clears after a successful refresh")

        // Cancelling a preview reaches the agent.
        agent.transport.setMode(.hang)
        let cancelController = RulePreviewController()
        cancelController.start(staleLogs, model: model)
        await waitFor("hanging preview to start") { cancelController.phase == .running }
        let cancelsBefore = agent.transport.requests { if case .cancelPreview = $0 { true } else { false } }
        cancelController.cancel()
        await waitFor("cancelPreview request") { agent.transport.requests { if case .cancelPreview = $0 { true } else { false } } > cancelsBefore }
        Check.expect(cancelController.phase == .cancelled, "cancelling a preview stops it and asks the agent to cancel")
        agent.transport.setMode(.passthrough)

        // Export counts rules once, not once per root.
        let exportPolicy = try model.policy.unwrap("export policy")
        let exportReview = try ConfigExportReview(policy: exportPolicy)
        Check.expect(exportReview.exportedCount + exportReview.skippedCount == exportPolicy.rules.count, "export review accounts for every rule exactly once")
    }
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

    // A separate operational fixture drives the actual UI model through due cleanup and restart.
    phase("native model Preview to active Trash and restart")
    let cleanupRoot = tree.root.appendingPathComponent("Acceptance-" + String(repeating: "long-path-", count: 14) + "é", isDirectory: true)
    try FileManager.default.createDirectory(at: cleanupRoot, withIntermediateDirectories: true)
    let expiredFile = cleanupRoot.appendingPathComponent("expired.tmp")
    let keptFile = cleanupRoot.appendingPathComponent("kept.tmp")
    for file in [expiredFile, keptFile] {
        try Data("disposable acceptance fixture".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: file.path)
    }
    let cleanupDirectory = tempAgentDirectory.appendingPathComponent("acceptance")
    let cleanupAgent = try await LiveAgent(directory: cleanupDirectory)
    let cleanupModel = cleanupAgent.model(services: services)
    await cleanupModel.refresh()
    let cleanupFolder = try ChosenFolder.make(from: cleanupRoot)
    let previewRule = try LifetimeRule(
        name: "Acceptance only", scope: RuleScope(path: cleanupRoot.path, recursive: false),
        matcher: ItemMatcher(itemKind: .file, exactNames: [], globPatterns: ["*.tmp"]),
        expiryBasis: .modified, lifetime: RuleDuration(seconds: 10), action: .trashItem, state: .preview
    )
    try await cleanupModel.addRules([previewRule], folders: [cleanupFolder])
    await waitFor("due Preview audit") {
        await cleanupModel.refresh()
        return cleanupModel.activity.contains { $0.kind == .previewSkipped && $0.identity?.pathHint == expiredFile.path }
    }
    Check.expect(FileManager.default.fileExists(atPath: expiredFile.path), "due Preview preserves the actual fixture file")
    try await cleanupModel.keep(path: keptFile.path, protectDescendants: false)
    try await cleanupModel.setState(.active, for: previewRule)
    await waitFor("active cleanup and Activity outcome") {
        await cleanupModel.refresh()
        return cleanupModel.activity.contains { $0.kind == .movedToTrash && $0.identity?.pathHint == expiredFile.path }
    }
    fixtureTrashPaths = cleanupModel.activity.filter { $0.kind == .movedToTrash }.compactMap(\.detail)
    Check.expect(!FileManager.default.fileExists(atPath: expiredFile.path), "active rule removed the due item from its original location")
    Check.expect(fixtureTrashPaths.count == 1 && fixtureTrashPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) }, "exactly one item is present in real macOS Trash")
    Check.expect(FileManager.default.fileExists(atPath: keptFile.path), "Keep survives the active cleanup")
    let trashEvent = try cleanupModel.activity.first { $0.kind == .movedToTrash }.unwrap("Trash event")
    let trashPath = try trashEvent.detail.unwrap("Trash destination")
    var revealed: [URL] = []
    let revealAction = ActivityTrashReveal(reveal: { revealed = $0 })
    Check.expect(revealAction.show(trashEvent) && revealed == [URL(fileURLWithPath: trashPath)], "Show in Trash selects the actual audited destination, not the original path")
    let summary = ActivitySummary(events: cleanupModel.activity)
    Check.expect(summary.movedCount == 1 && summary.lastCleanup == trashEvent.occurredAt, "loaded Activity summary records one move and its last cleanup time")
    Check.expect(summary.safetySkippedCount == cleanupModel.activity.filter { $0.kind == .safetySkipped }.count, "Activity safety count uses only loaded safety-skip events")
    let emptySummary = ActivitySummary(events: [])
    Check.expect(emptySummary.movedCount == 0 && emptySummary.safetySkippedCount == 0 && emptySummary.lastCleanup == nil, "empty Activity does not invent a cleanup time")
    revealed = []
    let recoveryHost = await snap.host(
        sheetCanvas(ActivityTrashRecovery(item: trashEvent, action: revealAction, shortcut: KeyboardShortcut("r", modifiers: [.command, .shift]))),
        size: CGSize(width: 760, height: 320)
    )
    Check.expect(snap.sendKeyEquivalent("r", modifiers: [.command, .shift], to: recoveryHost), "keyboard action activates the real Trash reveal button")
    Check.expect(revealed == [URL(fileURLWithPath: trashPath)], "Activity row reveals only the actual Trash destination")
    await snap.snapshot(recoveryHost, name: "89-trash-recovery")
    recoveryHost.window.contentView = nil
    recoveryHost.window.close()
    await shoot("89-real-trash-activity-available", .activity, model: cleanupModel, router: router)
    // Remove only the known disposable fixture destination to model an emptied/restored item.
    try FileManager.default.removeItem(atPath: trashPath)
    revealed = []
    Check.expect(!revealAction.show(trashEvent) && revealed.isEmpty, "missing Trash destination never opens Finder or reveals the original path")
    await snap.capture(sheetCanvas(ActivityTrashRecovery(item: trashEvent, action: revealAction)), name: "89-trash-no-longer-present", size: CGSize(width: 760, height: 320))
    await shoot("90-real-trash-activity", .activity, model: cleanupModel, router: router)
    await cleanupAgent.stop()
    let restartedAgent = try await LiveAgent(directory: cleanupDirectory)
    let restartedModel = restartedAgent.model(services: services)
    await restartedModel.refresh()
    let recovered = try await restartedModel.explain(path: keptFile.path)
    if case .protected = recovered.resolution {
        Check.expect(FileManager.default.fileExists(atPath: keptFile.path), "restart preserves Keep and its file")
    } else {
        Check.fail("restart lost Keep: \(recovered.resolution)")
    }
    Check.expect(restartedModel.activity.contains { $0.kind == .movedToTrash && $0.identity?.pathHint == expiredFile.path }, "Trash Activity survives agent restart")
    await shoot("91-restarted-overview", .overview, model: restartedModel, router: router)
    phase("revoked folder access")
    let unreadable = cleanupRoot.appendingPathComponent("unreadable", isDirectory: true)
    try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
    try Data("permission fixture".utf8).write(to: unreadable.appendingPathComponent("item.tmp"))
    let unreadableRule = try LifetimeRule(
        name: "Permission acceptance", scope: RuleScope(path: unreadable.path, recursive: true),
        matcher: ItemMatcher(itemKind: .file, exactNames: [], globPatterns: ["*.tmp"]),
        expiryBasis: .modified, lifetime: RuleDuration(seconds: 10), action: .trashItem, state: .preview
    )
    do {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path) }
        let controller = RulePreviewController()
        let hosted = await snap.host(
            sheetCanvas(RuleEditorSheet(target: .edit(unreadableRule), overview: try restartedModel.overview.unwrap("restarted overview"), preview: controller).environmentObject(restartedModel)),
            size: CGSize(width: 660, height: 800)
        )
        Check.expect(snap.sendKeyEquivalent("p", modifiers: .command, to: hosted), "keyboard Preview starts the unreadable-folder flow")
        await waitFor("preview permission error") { if case .failed = controller.phase { true } else { false } }
        await snap.snapshot(hosted, name: "92-editor-permission-error")
        snap.audit(hosted.host, screen: "92-editor-permission-error")
        hosted.window.contentView = nil
        hosted.window.close()
    }
    let restored = try await restartedModel.previewRule(unreadableRule)
    Check.expect(restored.matches == 1 && !restored.truncated, "restored folder access produces a complete preview")
    snap.colorScheme = .dark
    snap.increasedContrast = true
    await shoot("93-dark-high-contrast-long-path", .overview, model: restartedModel, router: router, size: CGSize(width: 1000, height: 760))
    await snap.capture(
        sheetCanvas(RuleEditorSheet(target: .edit(unreadableRule), overview: try restartedModel.overview.unwrap("restarted overview")).environmentObject(restartedModel)),
        name: "94-dark-high-contrast-editor", size: CGSize(width: 660, height: 800)
    )
    snap.colorScheme = .light
    snap.increasedContrast = false
    await restartedAgent.stop()
} catch is ExitSignal {
    // A failed Check was already recorded.
} catch {
    Check.fail("harness error: \(error)")
}

fixture?.tearDown()
for path in fixtureTrashPaths { try? FileManager.default.removeItem(atPath: path) }
try? FileManager.default.removeItem(at: tempAgentDirectory)


phase("summary")
print("  PNGs written: \(snap.written.count) in \(outputDirectory.path)")
print("  assertions passed: \(Check.passes), failed: \(Check.failures.count)")
if snap.unlabeled.isEmpty {
    print("  observable AppKit controls missing labels: none")
    print("  SwiftUI-hosted control instances not observable offscreen: \(snap.swiftUIHostedControls); real VoiceOver verification remains required")
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
