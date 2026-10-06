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
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @State private var onboardingLatched = false

    package init() {}

    package var body: some View {
        NavigationSplitView {
            TinyPruneSidebar(selection: $router.selection)
        } detail: {
            VStack(spacing: 0) {
                if showsOnboarding {
                    OnboardingFlow { onboardingCompleted = true }
                } else {
                    header
                    Divider()
                    content
                }
            }
            .background(PrunePalette.canvas)
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: Binding(
            get: { router.pendingExpiryPath.map(PathItem.init) },
            set: { if $0 == nil { router.pendingExpiryPath = nil } }
        )) { CustomExpirySheet(path: $0.path) }
        .sheet(item: Binding(
            get: { router.pendingFolderPath.map(PathItem.init) },
            set: { if $0 == nil { router.pendingFolderPath = nil } }
        )) { TemplateApplySheet(template: .temporaryWorkspace, prefillPath: $0.path) }
        .task {
            model.refreshRegistrationStatus()
            await model.refresh()
            if !onboardingCompleted, let policy = model.policy, policy.rules.isEmpty, policy.managedRoots.isEmpty {
                onboardingLatched = true
            }
        }
    }

    private var showsOnboarding: Bool { !onboardingCompleted && onboardingLatched }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(router.selection?.rawValue ?? "Overview")
                    .font(Typography.display(size: 30))
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.policy?.globallyPaused == true {
                Pill(text: pausedLabel(model.policy?.pausedUntil), color: PrunePalette.caution)
            }
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoading)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.overview == nil {
            ProgressView("Connecting to the local agent")
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
            ContentUnavailableView {
                Label { Text("No local state") } icon: { BrandMarkView(size: 44) }
            } description: {
                Text("Refresh to load TinyPrune rules.")
            }
        }
    }

    private var statusText: String {
        if model.isLoading { return "Refreshing local state" }
        if let refreshedAt = model.refreshedAt {
            return "Local agent connected · Updated \(refreshedAt.formatted(date: .omitted, time: .shortened))"
        }
        return "Local-first file lifetimes"
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
            case .notRegistered:
                Button("Install background agent") { Task { await model.registerAgent() } }
            case .requiresApproval:
                Button("Open Login Items") { model.openLoginItems() }
            case .notFound:
                Text("This development executable has no embedded LaunchAgent. Package and open TinyPrune.app to install the helper.")
                    .foregroundStyle(.secondary)
            case .enabled:
                EmptyView()
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
        if let overview = model.overview {
            Text(overview.policy.globallyPaused ? pausedLabel(overview.policy.pausedUntil) : "Running quietly")
            Divider()
            Text("Upcoming: \(overview.upcoming.count) item\(overview.upcoming.count == 1 ? "" : "s")")
            if let next = overview.upcoming.first {
                Text("Next: \(URL(fileURLWithPath: next.explanation.candidateIdentity.pathHint).lastPathComponent) · \(next.explanation.scheduledAt.formatted(date: .omitted, time: .shortened))")
            }
            Divider()
            if overview.policy.globallyPaused {
                Button("Resume") { Task { try? await model.setGlobalPause(false) } }
            } else {
                Menu("Pause") {
                    Button("1 hour") { Task { try? await model.pause(until: Date().addingTimeInterval(3_600)) } }
                    Button("Today") { Task { try? await model.pause(until: endOfToday()) } }
                    Button("Until tomorrow") { Task { try? await model.pause(until: tomorrowMorning()) } }
                    Button("Until I resume") { Task { try? await model.setGlobalPause(true) } }
                }
            }
        } else {
            Text(model.errorMessage ?? "Connecting…")
        }
        Divider()
        Button("Refresh") { Task { await model.refresh() } }
        Button("Open TinyPrune") {
            NSApp.activate(ignoringOtherApps: true)
            router.selection = .overview
            if NSApp.windows.allSatisfy({ !$0.isVisible }) { openWindow(id: "main") }
        }
        Divider()
        Button("Quit TinyPrune") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
            .help("Quits this app. The background agent keeps applying your rules.")
    }
}

extension View {
    /// Tint and base typeface applied to every TinyPrune window, shared by the app and the snapshot harness.
    package func tinyPruneWindowStyle() -> some View {
        tint(PrunePalette.plum).font(Typography.body(size: 13))
    }
}

package struct TinyPruneSidebar: View {
    @Binding var selection: AppSection?

    package init(selection: Binding<AppSection?>) { _selection = selection }

    package var body: some View {
        List(selection: $selection) {
            ForEach(AppSection.allCases) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                BrandMarkView(size: 24)
                Text("TinyPrune")
                    .font(Typography.display(size: 17))
                    .foregroundStyle(PrunePalette.plum)
            }
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .background(PrunePalette.sidebar)
    }
}
