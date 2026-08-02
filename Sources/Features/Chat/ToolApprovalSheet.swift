import SwiftUI

/// Asks the user to sign for one exact tool call.
///
/// The whole design premise is that an approval prompt saying only "allow tool call?" gets tapped
/// through, and the case actually worth catching survives that habit: a well-formed call whose
/// arguments were shaped by a document the app retrieved rather than by the model's own reasoning.
/// So provenance is not a footnote here — when it is untrusted it is the loudest thing on screen.
struct ToolApprovalSheet: View {
    let prompt: ToolApprovalPrompt
    let onApprove: () -> Void
    let onDecline: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                if prompt.isUntrusted {
                    Section {
                        Label {
                            Text(
                                "These arguments came from retrieved content, not from the "
                                    + "model's own reasoning. Approve only if you recognise them."
                            )
                            .font(Theme.Typeface.caption)
                        } icon: {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundStyle(Theme.Palette.refusal)
                        }
                        .accessibilityIdentifier("approvalUntrustedWarning")
                    }
                }

                Section {
                    LabeledContent("Tool", value: prompt.tool)
                        .accessibilityIdentifier("approvalTool")
                    LabeledContent("Resource", value: prompt.resource)
                        .accessibilityIdentifier("approvalResource")
                    LabeledContent("Arguments source", value: prompt.provenance)
                        .accessibilityIdentifier("approvalProvenance")
                } header: {
                    Text("The call")
                }

                Section {
                    // Shown in full rather than summarised: the arguments are the thing being
                    // signed for, and a truncated view of them is a signature on something the
                    // user did not read.
                    Text(prompt.arguments.isEmpty ? "{}" : prompt.arguments)
                        .font(Theme.Typeface.metric)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("approvalArguments")
                } header: {
                    Text("Arguments")
                }

                Section {
                    Button("Approve and run", action: onApprove)
                        .accessibilityIdentifier("approvalApprove")
                    Button("Don't run", role: .destructive, action: onDecline)
                        .accessibilityIdentifier("approvalDecline")
                } footer: {
                    Text(
                        "Approving signs this exact call. An identical call later needs its own "
                            + "approval — a signature is spent when it is used."
                    )
                }
            }
            .navigationTitle("Approval needed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDecline)
                        .accessibilityIdentifier("approvalCancel")
                }
            }
        }
        .accessibilityIdentifier("toolApprovalSheet")
    }
}
