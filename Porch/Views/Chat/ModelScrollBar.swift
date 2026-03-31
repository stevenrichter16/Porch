import SwiftUI

struct ModelScrollBar: View {
    let models: [RemoteModel]
    let isEnabled: Bool
    let onSelectModel: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(models) { model in
                    ModelTile(name: model.id) {
                        onSelectModel(model.id)
                    }
                    .disabled(!isEnabled)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

private struct ModelTile: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(PorchTheme.accent)

                Text(shortName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 72, height: 72)
            .background(PorchTheme.inputFieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New chat with \(name)")
    }

    private var shortName: String {
        // Show a concise label: take the last path component or the full name if short
        let components = name.split(separator: "/")
        let base = String(components.last ?? Substring(name))
        // Truncate to keep the tile compact
        if base.count > 10 {
            return String(base.prefix(9)) + "…"
        }
        return base
    }
}
