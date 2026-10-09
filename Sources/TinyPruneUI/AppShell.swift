import Foundation

package func pausedLabel(_ until: Date?) -> String {
    guard let until else { return "Paused" }
    return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
}

package func endOfToday(now: Date = Date()) -> Date {
    let calendar = Calendar.current
    let tomorrow = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
    return tomorrow > now ? tomorrow : now.addingTimeInterval(3_600)
}

package func tomorrowMorning(now: Date = Date()) -> Date {
    let calendar = Calendar.current
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
    return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
}
import SwiftUI
import AppKit
import TinyPruneDomain
import TinyPruneIPC

package enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case rules = "Rules"
    case upcoming = "Upcoming"
    case activity = "Activity"
    case templates = "Templates"
    case settings = "Settings"

    package var id: String { rawValue }

    package var symbol: String {
        switch self {
        case .overview: "rectangle.grid.1x2"
        case .rules: "slider.horizontal.3"
        case .upcoming: "clock"
        case .activity: "list.bullet.rectangle"
        case .templates: "square.on.square"
        case .settings: "gearshape"
        }
    }
}

/// Cross-page navigation: "Open Rule", "Preview Matches", and `tinyprune://rule?path=` from Finder.
@MainActor
package final class AppRouter: ObservableObject {
    @Published package var selection: AppSection? = .overview
    @Published package var focusedRuleID: UUID?
    @Published package var upcomingRuleFilter: UUID?
    @Published package var pendingRulePath: String?
    @Published package var pendingFolderPath: String?
    @Published package var pendingExpiryPath: String?
    /// The Upcoming item whose "Why will this be pruned?" inspector is open.
    @Published package var inspectedItemID: AgentUpcomingItem.ID?

    package init() {}

    package func openRule(_ id: UUID) {
        focusedRuleID = id
        selection = .rules
    }

    package func previewMatches(of id: UUID) {
        upcomingRuleFilter = id
        selection = .upcoming
    }

    package func handle(_ url: URL) {
        guard url.scheme == "tinyprune",
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value,
              path.hasPrefix("/") else { return }
        switch url.host {
        case "rule":
            pendingRulePath = path
            selection = .rules
        case "folder": pendingFolderPath = path
        case "expire": pendingExpiryPath = path
        default: break
        }
    }
}

package struct TinyPruneRootView: View {
    @EnvironmentObject private var model: AgentViewModel
    @EnvironmentObject private var router: AppRouter
    /// Observed so finishing onboarding re-evaluates the view; the model reads the same key.
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false

    package init() {}

    package var body: some View {
        HStack(spacing: 0) {
            TinyPruneSidebar(selection: $router.selection).frame(width: 220)
            Divider()
            VStack(spacing: 0) {
                if showsOnboarding {
                    OnboardingFlow { onboardingCompleted = true }
                } else {
                    header
                    Divider()
                    banners
                    content
                }
            }
            .background(PrunePalette.canvas)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: Binding(
            get: { showsOnboarding ? nil : router.pendingExpiryPath.map(PathItem.init) },
            set: { if $0 == nil { router.pendingExpiryPath = nil } }
        )) { CustomExpirySheet(path: $0.path) }
        .sheet(item: Binding(
            get: { showsOnboarding || router.pendingExpiryPath != nil ? nil : router.pendingFolderPath.map(PathItem.init) },
            set: { if $0 == nil { router.pendingFolderPath = nil } }
        )) { TemplateApplySheet(template: .temporaryWorkspace, prefillPath: $0.path) }
        .task {
            model.refreshRegistrationStatus()
            await model.refresh()
            model.startBackgroundRefresh()
        }
        .onChange(of: router.selection) { _, _ in Task { await model.refresh() } }
    }

    /// Reactive: follows every policy refresh. Completing onboarding (or any managed folder or rule appearing) ends it.
    private var showsOnboarding: Bool { !onboardingCompleted && model.needsOnboarding }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(router.selection?.rawValue ?? "Overview")
                    .font(Typography.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.pruningHaltedReason != nil {
                Pill(text: "Pruning stopped", color: PrunePalette.caution)
            } else if model.policy?.globallyPaused == true {
                Pill(text: pausedLabel(model.policy?.pausedUntil), color: PrunePalette.caution)
            }
            RefreshButton()
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
    }

    @ViewBuilder
    private var banners: some View {
        if let reason = model.pruningHaltedReason {
            Banner(
                title: "Pruning is stopped",
                message: reason,
                symbol: "exclamationmark.octagon",
                actionTitle: model.pruningHaltResolution?.title,
                action: model.pruningHaltResolution.map { resolution in { resolution.perform() } }
            )
        }
        if let notice = model.updateNotice {
            UpdateBanner(notice: notice) { model.updateNotice = nil }
        }
        if model.overview != nil, let issue = model.connectionIssue {
            Banner(
                title: "Showing the last known state",
                message: "\(issue) Changes you see may be out of date.",
                symbol: "bolt.horizontal.circle",
                actionTitle: "Retry",
                action: { Task { await model.refresh() } }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.overview == nil {
            VStack(spacing: 18) {
                BrandMarkView(size: 44)
                ProgressView("Connecting to the local agent").controlSize(.small)
                Text(model.startupNote ?? "Loading rules and schedules from this Mac.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = model.errorMessage {
            AgentUnavailableView(message: errorMessage)
        } else if let overview = model.overview {
            switch router.selection ?? .overview {
            case .overview: OverviewPage(overview: overview)
            case .rules: RulesPage(overview: overview)
            case .upcoming: UpcomingPage(overview: overview)
            case .activity: ActivityPage()
            case .templates: TemplatesPage()
            case .settings: SettingsPage(overview: overview)
            }
        } else {
            PruneEmptyState(title: "No local state", message: "Refresh to load TinyPrune rules from the local agent.", symbol: "arrow.clockwise")
                .padding(32)
        }
    }

    private var statusText: String {
        if model.isLoading { return "Connecting to the local agent" }
        if model.overview != nil, model.connectionIssue != nil {
            return "Agent unreachable · Last updated \(model.refreshedAt?.formatted(date: .omitted, time: .shortened) ?? "earlier")"
        }
        if let refreshedAt = model.refreshedAt {
            return "Local agent connected · Updated \(refreshedAt.formatted(date: .omitted, time: .shortened))"
        }
        return "Local-first file lifetimes"
    }
}

/// Manual refresh with its own short-lived feedback, so background refreshes never flicker the header.
private struct RefreshButton: View {
    @EnvironmentObject private var model: AgentViewModel
    @State private var working = false

    var body: some View {
        Button {
            working = true
            Task {
                await model.refresh()
                // Long enough to read as an acknowledgement even when the agent answers instantly.
                try? await Task.sleep(for: .milliseconds(600))
                working = false
            }
        } label: {
            if working {
                Label { Text("Refreshing") } icon: { ProgressView().controlSize(.small) }
            } else {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .disabled(working || model.isLoading)
        .accessibilityLabel("Refresh local state")
    }
}

/// A prominent notice above the page content.
private struct Banner: View {
    let title: String
    let message: String
    let symbol: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(PrunePalette.caution).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .accessibilityElement(children: .contain)
        .padding(.horizontal, 32)
        .padding(.vertical, 12)
        .background(PrunePalette.caution.opacity(0.12))
    }
}

/// Offers a newer release. Calm and dismissible: it never interrupts and never installs anything itself.
private struct UpdateBanner: View {
    let notice: UpdateNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "arrow.down.circle").foregroundStyle(PrunePalette.plum).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("TinyPrune \(notice.version) is available").font(.headline)
                Text(notice.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Skip This Version") { notice.skipVersion(); dismiss() }
            Button("Later") { notice.remindLater(); dismiss() }
            if let secondary = notice.secondary {
                Button(secondary.title) { secondary.perform() }
            }
            Button(notice.primary.title) { notice.primary.perform() }
                .keyboardShortcut(.defaultAction)
        }
        .accessibilityElement(children: .contain)
        .padding(.horizontal, 32)
        .padding(.vertical, 12)
        .background(PrunePalette.plum.opacity(0.10))
    }
}

private struct AgentUnavailableView: View {
    @EnvironmentObject private var model: AgentViewModel
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Agent unavailable", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(PrunePalette.caution)
            Text(message).foregroundStyle(.secondary)
            switch model.registrationStatus {
            // macOS reports .notFound for an agent that has simply never been registered (observed on macOS 26 with the
            // shipped bundle: status .notFound, then register() succeeds), so it gets the same install action.
            case .notRegistered, .notFound:
                Button("Install background agent") { Task { await model.registerAgent() } }
            case .requiresApproval:
                Button("Open Login Items") { model.openLoginItems() }
            case .enabled:
                Button("Restart background agent") { Task { await model.restartAgent() } }
            @unknown default:
                EmptyView()
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

package struct MenuBarContent: View {
    @EnvironmentObject private var model: AgentViewModel
    @EnvironmentObject private var router: AppRouter
    @Environment(\.openWindow) private var openWindow

    package init() {}

    package var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                BrandMarkView(size: 28)
                Text("TinyPrune").font(Typography.panelTitle).foregroundStyle(PrunePalette.plum)
                Spacer()
                if let overview = model.overview {
                    let badge = badge(overview)
                    Pill(text: badge.text, color: badge.color)
                }
            }
            if let overview = model.overview {
                summary(overview)
                actions(overview).pruneEntrance(2)
            } else {
                Text(model.startupNote ?? model.errorMessage ?? "Connecting…").foregroundStyle(.secondary)
                Button("Open TinyPrune", action: openMainWindow)
                    .buttonStyle(PruneButtonStyle(prominent: true))
                if model.errorMessage != nil {
                    Button("Restart background agent") { Task { await model.restartAgent() } }
                        .buttonStyle(PruneButtonStyle())
                }
            }
            HStack {
                Spacer()
                Button("Quit TinyPrune") { NSApp.terminate(nil) }
                    .buttonStyle(PruneLinkStyle())
                    .keyboardShortcut("q")
                    .help("Quits this app. The background agent keeps applying your rules.")
            }
            .font(Typography.body(size: 12, weight: .medium))
        }
        .padding(18)
        .frame(width: 340, alignment: .leading)
        .background(PrunePalette.canvas)
        .tinyPruneWindowStyle()
        .task { await model.refresh() }
    }

    @ViewBuilder
    private func summary(_ overview: AgentOverviewSnapshot) -> some View {
        let active = model.activeUpcoming
        let preview = model.previewUpcoming
        VStack(alignment: .leading, spacing: 10) {
            if model.pruningHaltedReason != nil || overview.policy.globallyPaused {
                Text(statusLine(overview)).font(.callout).foregroundStyle(.secondary)
            }
            if overview.policy.rules.isEmpty {
                templatesHero.pruneEntrance(1)
            } else {
                PopoverTally(active: active, previewCount: preview.count, now: model.currentDate) {
                    showMainWindow(section: .upcoming)
                }
                .pruneEntrance(1)
            }
            if let issue = model.connectionIssue {
                notice("Showing last known state. \(issue)")
            }
            if let reason = model.pruningHaltedReason {
                notice(reason)
                if let resolution = model.pruningHaltResolution {
                    Button(resolution.title) { resolution.perform() }
                }
            }
            if let update = model.updateNotice {
                notice("TinyPrune \(update.version) is available")
                Button(update.primary.title) { update.primary.perform() }
            }
            if model.needsAttention {
                Button("A cleanup needs a look…") { openActivity() }
                    .buttonStyle(PruneLinkStyle())
            }
            if let failure = model.actionError {
                notice("Could not change pause: \(failure)")
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(PrunePalette.caution)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func actions(_ overview: AgentOverviewSnapshot) -> some View {
        VStack(spacing: 8) {
            Button(action: openMainWindow) {
                Text("Open TinyPrune").frame(maxWidth: .infinity)
            }
            .buttonStyle(PruneButtonStyle(prominent: true))
            if !overview.policy.rules.isEmpty {
            HStack(spacing: 8) {
                Button { showMainWindow(section: .templates) } label: {
                    Label("Templates", systemImage: AppSection.templates.symbol).frame(maxWidth: .infinity)
                }
                .buttonStyle(PruneButtonStyle())
                .help("Ready-made rules for Downloads, screenshots, developer caches and more. You choose the folder and can start in Preview.")
                if overview.policy.globallyPaused {
                    Button { Task { await model.perform { try await model.setGlobalPause(false) } } } label: {
                        Label("Resume", systemImage: "play").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PruneButtonStyle())
                } else {
                    Menu {
                        Button("For 1 hour") { Task { await model.perform { try await model.pause(until: model.currentDate.addingTimeInterval(3_600)) } } }
                        Button("For today") { Task { await model.perform { try await model.pause(until: endOfToday(now: model.currentDate)) } } }
                        Button("Until tomorrow") { Task { await model.perform { try await model.pause(until: tomorrowMorning(now: model.currentDate)) } } }
                        Button("Until I resume") { Task { await model.perform { try await model.setGlobalPause(true) } } }
                    } label: {
                        Label("Pause", systemImage: "pause").frame(maxWidth: .infinity)
                    }
                    .menuStyle(.button)
                    .buttonStyle(PruneButtonStyle())
                    .menuIndicator(.hidden)
                }
            }
            }
        }
    }

    /// First-run hero: with no rules there is nothing to count, so point at the easy way in.
    private var templatesHero: some View {
        Button { showMainWindow(section: .templates) } label: {
            HStack(spacing: 12) {
                Image(systemName: AppSection.templates.symbol).font(.system(size: 20, weight: .light))
                    .foregroundStyle(PrunePalette.plum).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start from a template").font(Typography.body(size: 14, weight: .semibold))
                    Text("Pick ready-made rules, preview them, then turn them on.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PrunePalette.plum.opacity(0.5)).accessibilityHidden(true)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(PrunePalette.row, in: RoundedRectangle(cornerRadius: PruneDesign.Radius.row))
            .overlay(RoundedRectangle(cornerRadius: PruneDesign.Radius.row).strokeBorder(PrunePalette.plum.opacity(0.18), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: PruneDesign.Radius.row))
        }
        .buttonStyle(.plain)
        .pruneHover()
    }

    private func openMainWindow() { showMainWindow(section: .overview) }

    /// Brings the main window in front of everything, whether it is open behind other apps, minimized, or closed.
    /// A menu-bar popover is not a main-capable window, so a plain `activate` was not enough to raise it.
    private func showMainWindow(section: AppSection) {
        router.selection = section
        let raise = {
            NSApp.activate(ignoringOtherApps: true)
            guard let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) else { return false }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return true
        }
        if !raise() {
            openWindow(id: "main")
            DispatchQueue.main.async { _ = raise() }
        }
    }

    private func badge(_ overview: AgentOverviewSnapshot) -> (text: String, color: Color) {
        if model.pruningHaltedReason != nil { return ("Stopped", PrunePalette.caution) }
        if overview.policy.globallyPaused { return ("Paused", PrunePalette.caution) }
        let rules = overview.policy.rules
        if rules.isEmpty { return ("No rules", .secondary) }
        if rules.contains(where: { $0.state == .active }) { return ("Running", PrunePalette.safe) }
        if rules.contains(where: { $0.state == .preview }) { return ("Preview", PrunePalette.caution) }
        return ("Paused", PrunePalette.caution)
    }

    private func openActivity() { showMainWindow(section: .activity) }

    /// Says what TinyPrune is really doing: Preview rules never move files.
    private func statusLine(_ overview: AgentOverviewSnapshot) -> String {
        if model.pruningHaltedReason != nil { return "Pruning is stopped" }
        if overview.policy.globallyPaused { return pausedLabel(overview.policy.pausedUntil) }
        let rules = overview.policy.rules
        if rules.isEmpty { return "No rules yet" }
        if rules.contains(where: { $0.state == .active }) {
            return rules.contains(where: { $0.state == .preview }) ? "Running · some rules are Preview only" : "Running quietly"
        }
        if rules.contains(where: { $0.state == .preview }) { return "Preview only · nothing is moved" }
        return "All rules are paused"
    }
}

extension View {
    /// Tint and base typeface applied to every TinyPrune window, shared by the app and the snapshot harness.
    package func tinyPruneWindowStyle() -> some View {
        tint(PrunePalette.plum).font(Typography.body(size: 13))
            .buttonStyle(PruneButtonStyle())
    }
}

package struct TinyPruneSidebar: View {
    @Binding var selection: AppSection?
    @EnvironmentObject private var model: AgentViewModel
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Namespace private var selectionIndicator
    @Environment(\.colorSchemeContrast) private var contrast

    package init(selection: Binding<AppSection?>) { _selection = selection }

    package var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                BrandMarkView(size: 30)
                Text("TinyPrune").font(Typography.brand).foregroundStyle(PrunePalette.plum)
            }
            .padding(.horizontal, 12).padding(.top, 28).padding(.bottom, 24)
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element.id) { index, section in
                Button { selection = section } label: {
                HStack(spacing: 10) {
                    Image(systemName: section.symbol).frame(width: 18)
                    Text(section.rawValue)
                    Spacer(minLength: 4)
                    if let count = badge(for: section), count > 0 {
                        PruneCount(count).font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(PrunePalette.plum.opacity(0.08), in: Capsule())
                    }
                }
                .padding(.vertical, 10).padding(.horizontal, 12)
                .background {
                    if selection == section {
                        RoundedRectangle(cornerRadius: PruneDesign.Radius.row)
                            .fill(PrunePalette.plum.opacity(0.09))
                            .matchedGeometryEffect(id: "selectionWash", in: selectionIndicator)
                    }
                }
                .overlay(alignment: .leading) {
                    if selection == section {
                        Capsule().fill(PrunePalette.plum).frame(width: 3, height: 18)
                            .offset(x: 2)
                            .matchedGeometryEffect(id: "selection", in: selectionIndicator)
                    }
                }
                .overlay {
                    if selection == section && contrast == .increased {
                        RoundedRectangle(cornerRadius: PruneDesign.Radius.row).strokeBorder(PrunePalette.plum)
                    }
                }
                .pruneHover()
                .foregroundStyle(selection == section ? PrunePalette.plum : .primary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .accessibilityLabel(section.rawValue)
                .accessibilityAddTraits(selection == section ? [.isSelected] : [])
            }
            Spacer()
            Label("Local by design", systemImage: "externaldrive")
                .font(.caption).foregroundStyle(.secondary)
                .padding(12)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .animation(PruneDesign.motion(reduced), value: selection)
        .background(PrunePalette.sidebar)
    }

    private func badge(for section: AppSection) -> Int? {
        switch section {
        case .rules: model.policy?.rules.count
        case .upcoming: model.overview?.upcoming.count
        case .activity: model.attentionItems.count
        default: nil
        }
    }
}
