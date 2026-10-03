import SwiftUI

/// Pip's pixel speech bubble.
struct PetBubbleView: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PIP").font(.system(size: 10, weight: .heavy, design: .monospaced)).foregroundStyle(PipSprite.accent)
            Text(text).font(.system(size: 13)).lineLimit(8).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: 260)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Rectangle().strokeBorder(PipSprite.accent, lineWidth: 3))
        .onTapGesture { onClose() }
        .help("Click to close")
    }
}
