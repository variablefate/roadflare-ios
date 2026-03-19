import SwiftUI

struct WiredChatView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var messageText = ""

    private var coordinator: RideCoordinator? { appState.rideCoordinator }

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()
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
                                                .font(RFFont.body(15))
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 10)
                                                .background(msg.isMine ? Color.rfPrimary : Color.rfSurfaceContainerHigh)
                                                .foregroundColor(msg.isMine ? .black : Color.rfOnSurface)
                                                .clipShape(RoundedRectangle(cornerRadius: 18))
                                            if !msg.isMine { Spacer() }
                                        }
                                        .padding(.horizontal, 16)
                                        .id(msg.id)
                                    }
                                }
                                .padding(.vertical, 12)
                            }
                            .onChange(of: coordinator?.chatMessages.count) {
                                if let lastId = coordinator?.chatMessages.last?.id {
                                    proxy.scrollTo(lastId, anchor: .bottom)
                                }
                            }
                        }
                    } else {
                        VStack(spacing: 16) {
                            Spacer()
                            Image(systemName: "message")
                                .font(.system(size: 40))
                                .foregroundColor(Color.rfOnSurfaceVariant)
                            Text("No messages yet")
                                .font(RFFont.body(15))
                                .foregroundColor(Color.rfOnSurfaceVariant)
                            Spacer()
                        }
                    }

                    // Input bar
                    Rectangle().fill(Color.rfSurfaceContainerHigh).frame(height: 1)

                    HStack(spacing: 10) {
                        TextField("Message", text: $messageText)
                            .font(RFFont.body())
                            .padding(10)
                            .background(Color.rfSurfaceContainerLow)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .foregroundColor(Color.rfOnSurface)

                        Button { sendMessage() } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(
                                    messageText.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? Color.rfOffline : Color.rfPrimary
                                )
                        }
                        .disabled(messageText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .navigationTitle("Chat")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color.rfSurface, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.foregroundColor(Color.rfPrimary)
                    }
                }
            }
        }
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        messageText = ""
        Task { await coordinator?.sendChatMessage(text) }
    }
}
