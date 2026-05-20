import Foundation
import Observation

/// Drives the Plugin Store modal: fetches the curated registry over HTTPS,
/// tracks per-plugin install progress, and runs the install / remove pipeline.
///
/// The model deliberately holds no plugin-process state itself — installing a
/// plugin hands off to `AppCoordinator.registerInstalledPlugin(...)`, removing
/// one calls `PluginRegistry.unregister(...)` then `PluginInstaller.remove(...)`.
/// That keeps the single source of truth for "what is running" in the
/// `PluginRegistry`, exactly where the rest of the app reads it.
@Observable
@MainActor
final class PluginStoreModel {

    /// Where the curated index lives. Raw GitHub content, HTTPS, public.
    static let registryURL = URL(string:
        "https://raw.githubusercontent.com/lukataylo/halen/main/plugin-registry.json")!

    enum FetchState: Equatable {
        case idle
        case loading
        case loaded
        /// Network error, decode error, or unsupported schema version.
        case failed(String)
    }

    /// Per-entry transient state for the AVAILABLE list rows.
    enum InstallState: Equatable {
        case available
        case installing
        case failed(String)
    }

    private(set) var fetchState: FetchState = .idle
    /// Entries from the most recent successful fetch (empty until then).
    private(set) var available: [PluginRegistryEntry] = []
    /// Keyed by plugin id — only entries the user has interacted with appear.
    private(set) var installStates: [String: InstallState] = [:]

    private let registry: PluginRegistry
    /// Hands a validated, installed plugin to the coordinator for live
    /// registration. Injected so the model stays testable and AppKit-free.
    private let onInstalled: (URL, PluginManifest) -> Void

    init(registry: PluginRegistry,
         onInstalled: @escaping (URL, PluginManifest) -> Void) {
        self.registry = registry
        self.onInstalled = onInstalled
    }

    // MARK: - Registry fetch

    /// Fetch the curated index. Safe to call repeatedly — a fetch already in
    /// flight short-circuits. Surfaces offline / decode / schema errors into
    /// `fetchState` for the UI's failure card.
    func refresh() async {
        if case .loading = fetchState { return }
        fetchState = .loading
        do {
            var request = URLRequest(url: Self.registryURL)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                fetchState = .failed("Registry server returned HTTP \(http.statusCode).")
                return
            }
            let index = try JSONDecoder().decode(PluginRegistryIndex.self, from: data)
            guard index.schemaVersion == PluginRegistryIndex.supportedSchemaVersion else {
                fetchState = .failed("Registry schema v\(index.schemaVersion) isn't supported by this build of Halen.")
                return
            }
            available = index.plugins
            fetchState = .loaded
            Log.info("PluginStore: registry loaded — \(index.plugins.count) entr\(index.plugins.count == 1 ? "y" : "ies")")
        } catch let error as DecodingError {
            Log.warn("PluginStore: registry decode failed — \(error)")
            fetchState = .failed("The plugin registry is malformed and couldn't be read.")
        } catch {
            // URLError etc. — most commonly offline.
            fetchState = .failed("Couldn't reach the plugin registry. Check your connection and try again.")
        }
    }

    /// Registry entries the user doesn't already have installed.
    var notInstalled: [PluginRegistryEntry] {
        available.filter { !registry.contains($0.id) }
    }

    func state(for entry: PluginRegistryEntry) -> InstallState {
        installStates[entry.id] ?? .available
    }

    // MARK: - Install / remove

    /// Download → unpack → validate → register, all surfaced through
    /// `installStates[entry.id]`. Never throws; failures land in the state.
    func install(_ entry: PluginRegistryEntry) async {
        installStates[entry.id] = .installing
        do {
            let installed = try await PluginInstaller.install(entry)
            onInstalled(installed.directory, installed.manifest)
            installStates.removeValue(forKey: entry.id)
            Log.info("PluginStore: \(entry.id) installed and registered")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            installStates[entry.id] = .failed(message)
            Log.warn("PluginStore: install of \(entry.id) failed — \(message)")
        }
    }

    /// Stop + unregister the plugin, then delete its install directory.
    /// Returns an error message on failure, `nil` on success.
    func remove(id: String, directory: URL) -> String? {
        registry.unregister(id)
        do {
            try PluginInstaller.remove(id: id, directory: directory)
            return nil
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            Log.warn("PluginStore: remove of \(id) failed — \(message)")
            return message
        }
    }
}
