import SwiftUI

/// Two-tab detail view for the merged Writing Coach plugin. Each tab
/// re-uses the engine's existing makeDetailView() — that view is the same
/// content the user had before the merge, so muscle memory carries over.
@MainActor
struct WritingCoachDetailView: View {
    let sentiment: SentimentGuard
    let clarity: ClarityChecker

    private enum Tab: Hashable { case tone, clarity }
    @State private var tab: Tab = .tone

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Tone").tag(Tab.tone)
                Text("Clarity").tag(Tab.clarity)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider().opacity(0.4)

            // Defer to the engines' own detail views. They each maintain
            // their own ScrollView so per-tab scrolling stays independent.
            switch tab {
            case .tone:
                sentiment.makeDetailView()
            case .clarity:
                clarity.makeDetailView()
            }
        }
    }
}
