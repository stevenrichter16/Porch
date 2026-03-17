import SwiftUI

struct InputBar: View {
    @Binding var text: String
    let isStreaming: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message your model", text: $text, axis: .vertical)
                .focused($isFocused)
                .lineLimit(1 ... 6)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Button(action: buttonAction) {
                Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(isStreaming ? Color.red : Color.blue)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isStreaming && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func buttonAction() {
        if isStreaming {
            onStop()
        } else {
            onSend()
        }
    }
}
