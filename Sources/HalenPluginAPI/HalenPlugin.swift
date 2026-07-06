import Foundation
import SwiftUI

/// Every Halen feature — first-party or not — is a `HalenPlugin`. In-process
/// plugins conform directly (compiled against this module only); external
/// plugins are wrapped by the host's stdio adapter, which conforms on their
/// behalf. Either way the host sees one shape.
///
/// Identity, display metadata, and requested capabilities all come from the
/// plugin's `manifest` — one declaration, visible up front, shown verbatim in
/// the permissions screen.
///
/// Lifecycle:
///   - `start()` is called when the plugin is enabled by the user (or at
///     startup if it was enabled previously). Subscribe to
///     `context.events`, register hotkeys, etc. here.
///   - `stop()` must clean up everything: cancel tasks, close panels,
///     unregister hotkeys (`context.hotkeys?.unregisterAll()`). The plugin
///     can be enabled again later via `start()`. The host also restarts a
///     plugin when the user changes one of its capability grants, so a
///     fresh `start()` always sees the current context.
@MainActor
public protocol HalenPlugin: AnyObject {
    /// The up-front declaration: identity, display metadata, observed event
    /// topics, and requested capabilities. Stable — `manifest.id` keys
    /// UserDefaults persistence and on-disk storage paths.
    var manifest: PluginManifest { get }

    func start()
    func stop()

    /// Optional detail / settings view shown when the user taps the plugin
    /// row. Default is a generic "no settings" placeholder.
    @MainActor
    func makeDetailView() -> AnyView
}

public extension HalenPlugin {
    var id: String { manifest.id }
    var name: String { manifest.name }
    var summary: String { manifest.summary ?? "" }
    var icon: String { manifest.icon ?? "puzzlepiece.extension" }
    var category: PluginCategory {
        PluginCategory(rawValue: manifest.category ?? "") ?? .productivity
    }

    func makeDetailView() -> AnyView {
        AnyView(EmptyPluginDetailView(plugin: self))
    }
}

/// Default detail content for plugins without a custom view. Reads naturally as
/// "this plugin has nothing to configure" without looking broken or empty.
@MainActor
public struct EmptyPluginDetailView: View {
    let plugin: any HalenPlugin

    public init(plugin: any HalenPlugin) {
        self.plugin = plugin
    }

    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: plugin.icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text("Nothing to configure")
                .font(.system(.callout, weight: .medium))
            Text("\(plugin.name) runs automatically when enabled. There are no per-plugin settings yet.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }
}

public enum PluginCategory: String, CaseIterable, Sendable {
    case writing
    case voice
    case scheduling
    case focus
    case productivity
    case agents

    public var label: String {
        switch self {
        case .writing: return "Writing"
        case .voice: return "Voice"
        case .scheduling: return "Scheduling"
        case .focus: return "Focus"
        case .productivity: return "Productivity"
        case .agents: return "Agents"
        }
    }
}
