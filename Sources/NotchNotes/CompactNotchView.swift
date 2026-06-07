import SwiftUI

struct CompactNotchView: View {
    let layout: NotchLayout

    var body: some View {
        Image(systemName: "note.text")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.82))
            .frame(width: layout.compactSize.width, height: layout.compactSize.height)
            .background(Color.notchBackground)
            .clipShape(TopAttachedRoundedShape(radius: 12))
            .overlay(
                TopAttachedRoundedShape(radius: 12)
                    .stroke(.white.opacity(0.09), lineWidth: 1)
            )
            .pointingHandCursor()
    }
}
