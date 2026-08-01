import SwiftUI

struct AppMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.09, green: 0.54, blue: 0.34), Color(red: 0.03, green: 0.27, blue: 0.20)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "cylinder.split.1x2.fill")
                .font(.system(size: size * 0.43, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.13), radius: size * 0.12, y: size * 0.07)
    }
}

struct SectionCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.055), in: Capsule())
    }
}

extension View {
    func codeEditorStyle() -> some View {
        self
            .font(.system(.footnote, design: .monospaced))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }
}
