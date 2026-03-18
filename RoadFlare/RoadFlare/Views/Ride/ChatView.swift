import SwiftUI

/// In-ride chat view wired to the RideCoordinator.
struct WiredChatView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var messageText = ""

    private var coordinator: RideCoordinator? { appState.rideCoordinator }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let messages = coordinator?.chatMessages, !messages.isEmpty {
                    ScrollViewReader { proxy in
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
                                    .id(msg.id)
                                }
                            }
                            .padding(.vertical)
                        }
                        .onChange(of: coordinator?.chatMessages.count) {
                            if let lastId = coordinator?.chatMessages.last?.id {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label("No Messages", systemImage: "message")
                    } description: {
                        Text("Send a message to your driver")
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
        messageText = ""
        Task {
            await coordinator?.sendChatMessage(text)
        }
    }
}
