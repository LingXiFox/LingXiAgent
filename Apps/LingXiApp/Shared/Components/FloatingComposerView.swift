import SwiftUI

public struct FloatingComposerView: View {
    @ObservedObject public var model: ComposerModel
    public let onSend: (String, String, [AttachmentPresentation]) -> Void

    public init(
        model: ComposerModel,
        onSend: @escaping (String, String, [AttachmentPresentation]) -> Void
    ) {
        self.model = model
        self.onSend = onSend
    }

    public var body: some View {
        VStack(spacing: 8) {
            // Attachment chips
            if !model.attachments.isEmpty {
                HStack {
                    ForEach(model.attachments) { att in
                        HStack(spacing: 4) {
                            Image(systemName: att.thumbnailSymbol)
                                .font(.system(size: 9))
                            Text(att.filename)
                                .font(.system(size: 11))
                            Button(action: {
                                model.attachments.removeAll { $0.id == att.id }
                            }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .lingXiGlass(tier: .card, cornerRadius: 4)
                    }
                    Spacer()
                }
            }

            // Input Bar
            HStack(alignment: .center, spacing: 10) {
                // Mode Selector
                Picker("", selection: $model.selectedMode) {
                    Text("Build").tag("build")
                    Text("Plan").tag("plan")
                    Text("Ask").tag("ask")
                    Text("Review").tag("review")
                }
                .pickerStyle(.segmented)
                .frame(width: 190)

                // Text Input
                TextField("✦ Ask LingXi... (⌘↵ to send)", text: $model.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(LingXiGlass.Palette.textPrimary)
                    .onSubmit {
                        submit()
                    }

                // Attach Button
                Button(action: {
                    let sampleAtt = AttachmentPresentation(
                        filename: "context_\(Int.random(in: 100...999)).json",
                        mediaType: "application/json",
                        byteCount: 2048
                    )
                    model.attachments.append(sampleAtt)
                }) {
                    Image(systemName: "paperclip")
                        .foregroundColor(LingXiGlass.Palette.textSecondary)
                }
                .buttonStyle(.plain)

                // Send Button
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? LingXiGlass.Palette.textTertiary : LingXiGlass.Palette.cyberCyan)
                }
                .buttonStyle(.plain)
                .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .lingXiGlass(tier: .floating, cornerRadius: 16, ambientColor: LingXiGlass.Palette.cyberCyan)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private func submit() {
        let trimmed = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed, model.selectedMode, model.attachments)
    }
}
