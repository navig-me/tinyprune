import SwiftUI
import TinyPruneIPC
import TinyPruneUI

@main
struct TinyPruneApp: App {
    @StateObject private var model: AgentViewModel
    @StateObject private var router = AppRouter()
    @StateObject private var updater: AppUpdater

    @MainActor
    init() {
        let model = AgentViewModel(probeTransport: TinyPruneAgentClient(timeout: 3))
        let updater = AppUpdater()
        // The updater's pruning halt is shown in Overview, the header, and the menu bar.
        updater.bind(to: model)
        // Menu-bar state stays fresh without a window: timer plus app activation.
        model.startBackgroundRefresh()
        _model = StateObject(wrappedValue: model)
        _updater = StateObject(wrappedValue: updater)
    }
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        WindowGroup(id: "main") {
            TinyPruneRootView()
                .environmentObject(model)
                .environmentObject(router)
                .frame(minWidth: 900, minHeight: 600)
                .tinyPruneWindowStyle()
                .onOpenURL { router.handle($0) }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                UpdateCommand(updater: updater)
            }
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarContent()
                .environmentObject(model)
                .environmentObject(router)
        } label: {
            Image(nsImage: BrandMark.menuBarImage)
                .accessibilityLabel("TinyPrune")
        }
        .menuBarExtraStyle(.window)
    }
}
