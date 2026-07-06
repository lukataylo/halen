import Foundation
import Combine

class ProviderManager {
    static var shared: ProviderManager?

    let state: NotchState
    private var controllers: [ProviderID: any AgentProviderController] = [:]
    private var startedProviderIDs: Set<ProviderID> = []
    private var registryObserver: AnyCancellable?
    private var hasStarted = false

    init(state: NotchState) {
        self.state = state
        Self.shared = self
        registryObserver = ProviderRegistry.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.syncEnabledProviders()
            }
        }
    }

    // MARK: - Registration

    func register(_ controller: any AgentProviderController) {
        let id = controller.descriptor.id
        ProviderRegistry.shared.register(controller.descriptor)
        controllers[id] = controller
    }

    // MARK: - Lifecycle

    func start() {
        hasStarted = true
        syncEnabledProviders()
    }

    func cleanup() {
        for id in startedProviderIDs {
            controllers[id]?.cleanup()
        }
        startedProviderIDs.removeAll()
        hasStarted = false
    }

    // MARK: - Accessors

    var providers: [any AgentProviderController] {
        ProviderRegistry.shared.enabledPluginIDs.compactMap { controllers[$0] }
    }

    func controller(for id: ProviderID) -> (any AgentProviderController)? {
        guard ProviderRegistry.shared.isEnabled(id) else { return nil }
        return controllers[id]
    }

    func controller(for session: AgentSession?) -> (any AgentProviderController)? {
        if let session { return controller(for: session.providerID) }
        return controller(for: AppSettings.shared.defaultProviderID)
    }

    // MARK: - Actions

    func installIntegration(for session: AgentSession? = nil) -> Bool {
        controller(for: session)?.installIntegration() ?? false
    }

    func removeIntegration(for session: AgentSession? = nil) -> Bool {
        controller(for: session)?.removeIntegration() ?? false
    }

    func approve(requestId: String, session: AgentSession) {
        controller(for: session)?.approveAction(requestId: requestId, sessionId: session.id)
    }

    func reject(requestId: String, session: AgentSession) {
        controller(for: session)?.rejectAction(requestId: requestId, sessionId: session.id)
    }

    /// Approve this request and auto-approve this tool category for the rest of the session
    func allowAll(requestId: String, toolName: String, session: AgentSession) {
        let category = ToolApprovalCategory.fromToolName(toolName)
        // Enable auto-approve for this category in global settings
        switch category {
        case .read:       AppSettings.shared.autoApproveReads = true
        case .edit:       AppSettings.shared.autoApproveEdits = true
        case .command:    AppSettings.shared.autoApproveBash = true
        case .agent:      AppSettings.shared.autoApproveAgents = true
        case .management:   AppSettings.shared.autoApproveManagement = true
        case .interactive:  break  // Never auto-approve interactive tools
        case .unknown:      session.autoApproveAll = true
        }
        approve(requestId: requestId, session: session)
    }

    /// Approve this request and auto-approve everything for this session
    func bypass(requestId: String, session: AgentSession) {
        session.autoApproveAll = true
        approve(requestId: requestId, session: session)
    }

    func activeProviderDescriptor(for session: AgentSession? = nil) -> ProviderDescriptor? {
        if let session {
            return ProviderRegistry.shared.descriptor(for: session.providerID)
        }
        return ProviderRegistry.shared.descriptor(for: AppSettings.shared.defaultProviderID)
    }

    private func syncEnabledProviders() {
        guard hasStarted else { return }

        let enabledProviderIDs = Set(ProviderRegistry.shared.enabledPluginIDs)

        for id in startedProviderIDs.subtracting(enabledProviderIDs) {
            controllers[id]?.cleanup()
            startedProviderIDs.remove(id)
            state.removeSessions(for: id)
        }

        for id in enabledProviderIDs.subtracting(startedProviderIDs) {
            controllers[id]?.start()
            startedProviderIDs.insert(id)
        }
    }
}
