import SwiftUI
import TinyPruneDomain

private struct TidyChoice: Identifiable {
    let id: String
    let title: String
    let detail: String
    let template: RuleTemplate
    let directory: URL?
}

package struct OnboardingFlow: View {
    @EnvironmentObject private var model: AgentViewModel
    @AppStorage("previewBroadByDefault") private var previewByDefault = true
    let finish: () -> Void

    @State private var step: Int
    @State private var folders: [String: ChosenFolder] = [:]
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let fileManager = FileManager.default

    package init(initialStep: Int = 0, finish: @escaping () -> Void) {
        _step = State(initialValue: initialStep)
        self.finish = finish
    }

    private var choices: [TidyChoice] {
        [
            TidyChoice(id: "downloads", title: "Downloads", detail: "Installers after 7 days, archives after 14, the rest after 30.",
                       template: .downloads, directory: fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first),
            TidyChoice(id: "screenshots", title: "Screenshots", detail: "Screenshots 7 days after they are created.",
                       template: .screenshots, directory: fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first),
            TidyChoice(id: "developer", title: "Developer junk", detail: "Dependencies, environments, caches, and build output once a project goes quiet.",
                       template: .developerCleanup, directory: nil),
            TidyChoice(id: "folder", title: "Choose a folder", detail: "Anything placed there expires after 3 days.",
                       template: .temporaryWorkspace, directory: nil),
        ]
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    switch step {
                    case 0: intro
                    case 1: chooser
                    default: reassurance
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("Step \(step + 1) of 3").foregroundStyle(.secondary)
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                if step < 2 {
                    Button("Continue") { step += 1 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(folders.isEmpty ? "Start with no rules" : "Start TinyPrune") { Task { await apply() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSaving)
                }
            }
            .disabled(isSaving)
        }
        .padding(48)
        .frame(maxWidth: 680, maxHeight: .infinity, alignment: .leading)
        .frame(maxWidth: .infinity)
        .alert("Setup problem", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "leaf.fill").font(.system(size: 34)).foregroundStyle(PrunePalette.plum)
                .accessibilityHidden(true)
            Text("Files don’t all need to live forever.")
                .font(Typography.display(size: 40))
                .accessibilityAddTraits(.isHeader)
            Text("TinyPrune quietly moves files to Trash once they are no longer useful.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What would you like to keep tidy?")
                .font(Typography.display(size: 32))
                .accessibilityAddTraits(.isHeader)
            ForEach(choices) { choice in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(choice.title).font(.headline)
                        Text(choice.detail).foregroundStyle(.secondary)
                        if let folder = folders[choice.id] { PathText(path: folder.root.path) }
                    }
                    Spacer()
                    if folders[choice.id] != nil {
                        Button("Remove") { folders[choice.id] = nil }
                            .accessibilityLabel("Remove \(choice.title) folder")
                    }
                    Button(folders[choice.id] == nil ? "Choose folder…" : "Change…") { pick(choice) }
                        .accessibilityLabel("\(folders[choice.id] == nil ? "Choose" : "Change") folder for \(choice.title)")
                }
                Divider()
            }
        }
    }

    private var reassurance: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "arrow.uturn.backward.circle").font(.system(size: 34)).foregroundStyle(PrunePalette.safe)
                .accessibilityHidden(true)
            Text("Always recoverable.")
                .font(Typography.display(size: 40))
                .accessibilityAddTraits(.isHeader)
            Text("TinyPrune moves items to Trash. It does not permanently delete them.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Toggle("Start broad rules in Preview mode", isOn: $previewByDefault)
            Text(previewByDefault
                 ? "Rules will list what they would prune in Upcoming, and touch nothing until you activate them."
                 : "Rules you create now will be active immediately and move due items to Trash.")
                .font(.callout)
                .foregroundStyle(previewByDefault ? PrunePalette.safe : PrunePalette.caution)
        }
    }

    private func pick(_ choice: TidyChoice) {
        do {
            if let folder = try ChosenFolder.choose(startingAt: choice.directory) { folders[choice.id] = folder }
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func apply() async {
        isSaving = true
        defer { isSaving = false }
        do {
            for choice in choices {
                guard let folder = folders[choice.id] else { continue }
                let state: RuleState = (previewByDefault || folder.isVeryBroad) ? .preview : .active
                let rules = try choice.template.rules(in: folder.root.path, state: state)
                try await model.addRules(rules, in: folder)
            }
            finish()
        } catch { errorMessage = error.localizedDescription }
    }
}
