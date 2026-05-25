import SwiftUI

/// Two-tab detail view for the merged Word Replacements plugin. Hosts the
/// existing TypoFixerDetailView and StyleGuideDetailView verbatim — the
/// tabs are just the entry surface; everything below remains the same UI
/// users had before the merge, so muscle memory carries over.
@MainActor
struct WordReplacementsDetailView: View {
    @Bindable var typoStore: TypoStore
    @Bindable var styleStore: StyleRulesStore

    private enum Tab: Hashable { case typos, preferences }
    @State private var tab: Tab = .typos

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Auto-typos").tag(Tab.typos)
                Text("My preferences").tag(Tab.preferences)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider().opacity(0.4)

            // The two halves keep their own ScrollView so each tab's
            // content scrolls independently — wrapping them in a single
            // outer ScrollView would nest scroll containers and break
            // section-level focus restoration when switching tabs.
            switch tab {
            case .typos:
                TypoFixerDetailView(store: typoStore)
            case .preferences:
                StyleGuideDetailView(store: styleStore)
            }
        }
    }
}
