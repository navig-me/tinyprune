import SwiftUI

@main
struct TinyPruneApp: App {
    var body: some Scene {
        WindowGroup {
            FoundationView()
                .frame(minWidth: 720, minHeight: 500)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

private struct FoundationView: View {
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Label("TinyPrune", systemImage: "leaf.fill")
                    .font(.headline)
                    .foregroundStyle(Color(red: 0.19, green: 0.04, blue: 0.15))
                Divider()
                Label("Overview", systemImage: "rectangle.grid.1x2")
                Label("Rules", systemImage: "slider.horizontal.3")
                Label("Upcoming", systemImage: "clock")
                Spacer()
            }
            .padding(24)
            .frame(width: 190, alignment: .leading)
            .background(Color(red: 0.96, green: 0.94, blue: 0.92))

            VStack(alignment: .leading, spacing: 18) {
                Text("TinyPrune")
                    .font(.system(size: 38, weight: .semibold, design: .serif))
                Text("Your local lifecycle rule service is ready to be configured.")
                    .font(.title3)
                Divider()
                Text("Safety first")
                    .font(.headline)
                Text("Rules will begin in Preview. Nothing moves until an active rule passes its final safety check.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(48)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(red: 0.985, green: 0.975, blue: 0.96))
    }
}
