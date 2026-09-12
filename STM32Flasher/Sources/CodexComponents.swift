import SwiftUI
import UniformTypeIdentifiers

enum CodexPalette {
    private static let palette = IDETheme.codexLight.palette

    static let canvas = palette.canvas
    static let sidebar = palette.sidebar
    static let panel = palette.panel
    static let elevated = palette.elevated
    static let editor = palette.editor
    static let console = palette.console
    static let selected = palette.selected
    static let hover = palette.hover
    static let border = palette.border
    static let strongBorder = palette.strongBorder
    static let primaryText = palette.primaryText
    static let secondaryText = palette.secondaryText
    static let mutedText = palette.mutedText
    static let faintText = palette.faintText
    static let accent = palette.accent
    static let success = palette.success
    static let warning = palette.warning
    static let danger = palette.danger
}

/// Keeps compact tool panels visually stable when the split view gets narrow.
///
/// SwiftUI normally recomputes the panel layout at every width, which can make
/// labels wrap and toolbar controls stack. Below the reference width, this
/// container lays its content out at a stable width and scales the whole panel
/// uniformly instead.
struct ProportionalWidthContainer<Content: View>: View {
    let referenceWidth: CGFloat
    let minimumScale: CGFloat
    private let content: Content

    init(
        referenceWidth: CGFloat,
        minimumScale: CGFloat = 0.7,
        @ViewBuilder content: () -> Content
    ) {
        self.referenceWidth = max(referenceWidth, 1)
        self.minimumScale = min(max(minimumScale, 0.1), 1)
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            let widthScale = proxy.size.width / referenceWidth
            let scale = min(1, max(minimumScale, widthScale))
            let layoutWidth = proxy.size.width / scale
            let layoutHeight = proxy.size.height / scale

            content
                .frame(
                    width: layoutWidth,
                    height: layoutHeight,
                    alignment: .topLeading
                )
                .scaleEffect(scale, anchor: .topLeading)
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height,
                    alignment: .topLeading
                )
        }
        .clipped()
    }
}

struct WhiteCard<Content: View>: View {
    let title: String
    let caption: String?
    private let content: Content

    init(
        title: String,
        caption: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CodexPalette.primaryText)
                Spacer()
                if let caption {
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(CodexPalette.mutedText)
                        .lineLimit(1)
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(CodexPalette.border)
        }
    }
}

struct StatusChip: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(title)
                .foregroundStyle(CodexPalette.secondaryText)
        }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.06))
            .clipShape(Capsule())
            .overlay { Capsule().strokeBorder(color.opacity(0.14)) }
    }
}

struct ConsoleText: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(CodexPalette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(CodexPalette.console)
    }
}

struct UsageMeter: View {
    let label: String
    let value: String
    let progress: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(CodexPalette.mutedText)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(CodexPalette.accent)
                .frame(width: 54)
            Text(value)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(CodexPalette.mutedText)
        }
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isEnabled ? CodexPalette.secondaryText : CodexPalette.faintText)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(configuration.isPressed ? CodexPalette.selected : CodexPalette.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(CodexPalette.border)
            }
    }
}

struct SubtleIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(isEnabled ? CodexPalette.mutedText : CodexPalette.faintText)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? CodexPalette.selected : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct ToolbarIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isEnabled ? CodexPalette.secondaryText : CodexPalette.faintText)
            .frame(width: 32, height: 32)
            .background(configuration.isPressed ? CodexPalette.selected : CodexPalette.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(CodexPalette.border)
            }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white.opacity(isEnabled ? 1 : 0.72))
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                CodexPalette.primaryText.opacity(
                    isEnabled ? (configuration.isPressed ? 0.80 : 1) : 0.32
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct CompactPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(isEnabled ? 1 : 0.72))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                CodexPalette.primaryText.opacity(
                    isEnabled ? (configuration.isPressed ? 0.80 : 1) : 0.32
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct RocketToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? CodexPalette.secondaryText : CodexPalette.faintText)
            .frame(width: 32, height: 32)
            .background(
                configuration.isPressed ? CodexPalette.selected : CodexPalette.elevated
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(CodexPalette.border)
            }
    }
}

/// A deliberately reduced rocket silhouette for the AI build-and-flash action.
/// It keeps only the pointed body and two fins so it remains clear at toolbar size.
struct MinimalRocketGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let x = rect.minX
        let y = rect.minY
        let width = rect.width
        let height = rect.height
        var path = Path()

        path.move(to: CGPoint(x: x + width * 0.50, y: y + height * 0.04))
        path.addCurve(
            to: CGPoint(x: x + width * 0.70, y: y + height * 0.68),
            control1: CGPoint(x: x + width * 0.65, y: y + height * 0.19),
            control2: CGPoint(x: x + width * 0.71, y: y + height * 0.44)
        )
        path.addLine(to: CGPoint(x: x + width * 0.57, y: y + height * 0.86))
        path.addLine(to: CGPoint(x: x + width * 0.43, y: y + height * 0.86))
        path.addLine(to: CGPoint(x: x + width * 0.30, y: y + height * 0.68))
        path.addCurve(
            to: CGPoint(x: x + width * 0.50, y: y + height * 0.04),
            control1: CGPoint(x: x + width * 0.29, y: y + height * 0.44),
            control2: CGPoint(x: x + width * 0.35, y: y + height * 0.19)
        )
        path.closeSubpath()

        path.move(to: CGPoint(x: x + width * 0.32, y: y + height * 0.54))
        path.addLine(to: CGPoint(x: x + width * 0.08, y: y + height * 0.80))
        path.addLine(to: CGPoint(x: x + width * 0.35, y: y + height * 0.73))
        path.closeSubpath()

        path.move(to: CGPoint(x: x + width * 0.68, y: y + height * 0.54))
        path.addLine(to: CGPoint(x: x + width * 0.92, y: y + height * 0.80))
        path.addLine(to: CGPoint(x: x + width * 0.65, y: y + height * 0.73))
        path.closeSubpath()

        return path
    }
}

struct TextOnlyButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isEnabled ? CodexPalette.mutedText : CodexPalette.faintText)
            .opacity(configuration.isPressed ? 0.62 : 1)
    }
}

extension UTType {
    static let unixExecutable = UTType(filenameExtension: "") ?? .data
}
