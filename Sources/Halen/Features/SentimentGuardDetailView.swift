import SwiftUI

struct SentimentGuardDetailView: View {
    let approvedCount: Int
    let onClearApproved: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    label("How it works")
                    Text("When you finish a sentence in any text field, Halen sends the surrounding ~800 chars to your local Gemma 4 model and asks it to classify the tone.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Only \"irritated\" and \"hostile\" classifications surface a popover. Everything else is silent.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    label("Approved fingerprints")
                    HStack {
                        Text("\(approvedCount)")
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                        Text("message\(approvedCount == 1 ? "" : "s") you've marked as fine")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                    }
                    Button("Clear approvals", action: onClearApproved)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(approvedCount == 0 ? Color.secondary.opacity(0.5) : Color.red)
                        .disabled(approvedCount == 0)
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 6) {
                    label("Model")
                    HStack(spacing: 8) {
                        Image(systemName: "cpu")
                            .foregroundStyle(.tertiary)
                        Text("Gemma 4 E4B")
                            .font(.system(.callout, design: .monospaced))
                        Spacer()
                        Text("local via Ollama")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }
}
