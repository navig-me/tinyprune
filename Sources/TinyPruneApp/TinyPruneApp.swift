import SwiftUI
import TinyPruneUI

@main
struct TinyPruneApp: App {
    @StateObject private var model = AgentViewModel()
    @StateObject private var router = AppRouter()
    @StateObject private var updater = AppUpdater()
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

        MenuBarExtra("TinyPrune", systemImage: "leaf.fill", isInserted: $showMenuBarIcon) {
            MenuBarContent()
                .environmentObject(model)
                .environmentObject(router)
        }
    }
}
