import SwiftUI

/// In-ride chat view.
struct ChatView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var messageText = ""
    @State private var messages: [(id: String, text: String, isMine: Bool)] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if messages.isEmpty {
                    ContentUnavailableView {
                        Label("No Messages", systemImage: "message")
                    } description: {
                        Text("Send a message to your driver")
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(messages, id: \.id) { msg in
                                HStack {
                                    if msg.isMine { Spacer() }
                                    Text(msg.text)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(msg.isMine ? Color.accentColor : Color(.systemGray5))
                                        .foregroundStyle(msg.isMine ? .white : .primary)
                                        .clipShape(RoundedRectangle(cornerRadius: 16))
                                    if !msg.isMine { Spacer() }
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    TextField("Message", text: $messageText)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(messageText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding()
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        messages.append((id: UUID().uuidString, text: text, isMine: true))
        messageText = ""
        // TODO: Publish Kind 3178 chat event via relay
    }
}
