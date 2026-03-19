import SwiftUI

/// Floating toast notification for errors and status messages.
struct ToastView: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundColor(isError ? Color.rfError : Color.rfOnline)
            Text(message)
                .font(RFFont.body(14))
                .foregroundColor(Color.rfOnSurface)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.rfSurfaceContainerHighest)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .rfAmbientShadow(color: isError ? .rfError : .rfOnline, radius: 16, opacity: 0.1)
        .padding(.horizontal, 24)
    }
}

/// Toast modifier — attach to any view to show floating toasts.
struct ToastModifier: ViewModifier {
    @Binding var message: String?
    var isError: Bool = true
    var duration: TimeInterval = 3.0

    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content

            if let message {
                ToastView(message: message, isError: isError)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
                    .padding(.top, 8)
                    .onAppear {
                        Task {
                            try? await Task.sleep(for: .seconds(duration))
                            withAnimation(.easeInOut(duration: 0.3)) {
                                self.message = nil
                            }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: message)
    }
}

extension View {
    func toast(_ message: Binding<String?>, isError: Bool = true, duration: TimeInterval = 3.0) -> some View {
        modifier(ToastModifier(message: message, isError: isError, duration: duration))
    }
}
