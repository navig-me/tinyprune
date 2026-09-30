import SwiftUI
import TinyPruneDomain
import TinyPruneIPC

@main
struct TinyPruneApp: App {
    var body: some Scene {
        WindowGroup {
            TinyPruneWindow()
                .frame(minWidth: 820, minHeight: 560)
                .tint(PrunePalette.plum)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

private enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case rules = "Rules"
    case upcoming = "Upcoming"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "rectangle.grid.1x2"
        case .rules: "slider.horizontal.3"
        case .upcoming: "clock"
        }
    }
}

private enum PrunePalette {
    static let plum = Color(red: 0.29, green: 0.12, blue: 0.24)
    static let canvas = Color(red: 0.985, green: 0.975, blue: 0.96)
    static let sidebar = Color(red: 0.955, green: 0.94, blue: 0.92)
}

@MainActor
private final class AgentViewModel: ObservableObject {
    @Published private(set) var overview: AgentOverviewSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var refreshedAt: Date?

    private let client = TinyPruneAgentClient()

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await client.request(AgentRequest(operation: .loadOverview))
            switch response.payload {
            case .overview(let overview):
                self.overview = overview
                errorMessage = nil
                refreshedAt = Date()
            case .failure(let error):
                overview = nil
                errorMessage = "The TinyPrune agent could not load local state: \(error)"
            default:
                overview = nil
                errorMessage = "The TinyPrune agent returned an unexpected response."
            }
        } catch {
            overview = nil
            errorMessage = "The local TinyPrune agent is unavailable."
        }
    }
}

private struct TinyPruneWindow: View {
    @StateObject private var model = AgentViewModel()
    @State private var selection: AppSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(AppSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.symbol)
                            .tag(section as AppSection?)
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top, spacing: 0) {
                Label("TinyPrune", systemImage: "leaf.fill")
                    .font(.headline)
                    .foregroundStyle(PrunePalette.plum)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
            }
            .background(PrunePalette.sidebar)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            .background(PrunePalette.canvas)
        }
        .navigationSplitViewStyle(.balanced)
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(selection?.rawValue ?? "Overview")
                    .font(.system(size: 30, weight: .regular, design: .serif))
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
            VStack(alignment: .leading, spacing: 12) {
                Label("Agent unavailable", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(errorMessage)
                    .foregroundStyle(.secondary)
                Button("Retry") { Task { await model.refresh() } }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let overview = model.overview {
            switch selection ?? .overview {
            case .overview: OverviewPage(overview: overview)
            case .rules: RulesPage(rules: overview.policy.rules)
            case .upcoming: UpcomingPage(items: overview.upcoming)
            }
        } else {
            ContentUnavailableView("No local state", systemImage: "leaf", description: Text("Refresh to load TinyPrune rules."))
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

private struct OverviewPage: View {
    let overview: AgentOverviewSnapshot

    private var places: [String] {
        Array(Set(overview.policy.rules.filter { $0.matchMode != .template }.map(\.scope.path))).sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 16) {
                    metric("Managed scopes", value: "\(places.count)")
                    metric("Rules", value: "\(overview.policy.rules.count)")
                    metric("Preview", value: "\(overview.policy.rules.filter { $0.state == .preview }.count)")
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Managed places").font(.system(size: 22, weight: .regular, design: .serif))
                    if places.isEmpty {
                        Text("No rules or managed scopes are configured yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(places, id: \.self) { path in
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundStyle(PrunePalette.plum)
                                Text(path).font(.system(.body, design: .monospaced))
                                Spacer()
                                Text("\(overview.policy.rules.filter { $0.matchMode != .template && $0.scope.path == path }.count) rules")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Next to prune").font(.system(size: 22, weight: .regular, design: .serif))
                    if let next = overview.upcoming.first {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(next.explanation.candidateIdentity.pathHint)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Text("\(next.explanation.scheduledAt.formatted(date: .abbreviated, time: .shortened)) · \(next.explanation.matchedRuleName) · \(next.explanation.disposition.rawValue.capitalized)")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No items are scheduled.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.system(size: 28, weight: .regular, design: .serif))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct RulesPage: View {
    let rules: [LifetimeRule]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if rules.isEmpty {
                    Text("No rules configured.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                }
                ForEach(rules) { rule in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(rule.name)
                                .font(.system(size: 20, weight: .regular, design: .serif))
                            Spacer()
                            Text(rule.state.rawValue.capitalized)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(PrunePalette.sidebar, in: Capsule())
                        }
                        Text(description(for: rule))
                        Text(rule.scope.path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(32)
        }
    }

    private func description(for rule: LifetimeRule) -> String {
        let names = (rule.matcher.exactNames.sorted() + rule.matcher.globPatterns.sorted()).joined(separator: ", ")
        let target = names.isEmpty ? rule.matcher.itemKind.rawValue : names
        let scope = rule.matchMode == .template ? "all managed places" : rule.scope.path
        let action: String
        switch rule.action {
        case .trashItem: action = "move the item to Trash"
        case .emptyContents: action = "empty the folder contents to Trash"
        case .trashMatchingChildren: action = "move matching children to Trash"
        }
        let stateText = rule.state == .preview ? "Preview only: would" : rule.state == .paused ? "Paused: would" : "When due, will"
        return "\(stateText) match \(target) inside \(scope), based on \(rule.expiryBasis.rawValue) for \(duration(rule.lifetime.seconds)), then \(action)."
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let day: TimeInterval = 86_400
        if seconds.truncatingRemainder(dividingBy: day) == 0 { return "\(Int(seconds / day)) days" }
        if seconds.truncatingRemainder(dividingBy: 3_600) == 0 { return "\(Int(seconds / 3_600)) hours" }
        return "\(Int(seconds)) seconds"
    }
}

private struct UpcomingPage: View {
    let items: [AgentUpcomingItem]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    Text("No items are scheduled.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.explanation.candidateIdentity.pathHint)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Text("\(item.explanation.scheduledAt.formatted(date: .abbreviated, time: .shortened)) · \(item.explanation.matchedRuleName) · \(item.explanation.disposition.rawValue.capitalized)")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 14)
                    Divider()
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
