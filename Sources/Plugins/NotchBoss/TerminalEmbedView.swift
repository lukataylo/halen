import SwiftUI
import SwiftTerm
import AppKit

/// SwiftUI wrapper for SwiftTerm's LocalProcessTerminalView.
/// Embeds a full terminal emulator in the notch panel.
struct TerminalEmbedView: NSViewRepresentable {
    let terminalView: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0).cgColor

        // Guard against re-parenting: remove from previous parent if SwiftUI recreates the host
        if terminalView.superview != nil {
            terminalView.removeFromSuperview()
        }

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminalView)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: container.topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Terminal view is persistent — no updates needed on SwiftUI re-render
    }
}

/// A view that shows the terminal if available, or a placeholder.
struct TerminalSessionView: View {
    let sessionId: UUID

    var body: some View {
        Group {
            if let view = PTYSessionManager.shared.terminalView(for: sessionId) {
                TerminalEmbedView(terminalView: view)
            } else {
                terminalPlaceholder
            }
        }
    }

    private var terminalPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.2))
            Text("Terminal not available")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
    }
}
