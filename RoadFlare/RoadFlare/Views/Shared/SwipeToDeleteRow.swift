import SwiftUI

/// A row that supports swipe-left-to-reveal-delete in a ScrollView context.
/// Works outside of List (where .swipeActions isn't available).
struct SwipeToDeleteRow<Content: View>: View {
    let onTap: () -> Void
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var showDelete = false

    private let deleteWidth: CGFloat = 72

    var body: some View {
        ZStack(alignment: .trailing) {
            // Delete button behind the content
            if showDelete || offset < 0 {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        onDelete()
                        offset = 0
                        showDelete = false
                    }
                } label: {
                    Image(systemName: "trash.fill")
                        .foregroundColor(.white)
                        .frame(width: deleteWidth)
                        .frame(maxHeight: .infinity)
                }
                .background(Color.rfError)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            // Main content
            content()
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            let translation = value.translation.width
                            if translation < 0 {
                                offset = max(translation, -deleteWidth)
                            } else if showDelete {
                                offset = min(0, -deleteWidth + translation)
                            }
                        }
                        .onEnded { value in
                            withAnimation(.easeOut(duration: 0.2)) {
                                if offset < -deleteWidth / 2 {
                                    offset = -deleteWidth
                                    showDelete = true
                                } else {
                                    offset = 0
                                    showDelete = false
                                }
                            }
                        }
                )
                .onTapGesture {
                    if showDelete {
                        withAnimation(.easeOut(duration: 0.2)) {
                            offset = 0
                            showDelete = false
                        }
                    } else {
                        onTap()
                    }
                }
        }
        .clipped()
    }
}
