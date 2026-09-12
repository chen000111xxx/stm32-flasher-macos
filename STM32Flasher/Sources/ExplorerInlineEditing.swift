import SwiftUI
import AppKit

enum ExplorerMetrics {
    static let headerTitleFont: CGFloat = 13
    static let toolbarIconFont: CGFloat = 12.5
    static let toolbarHeight: CGFloat = 42
    static let sectionTitleFont: CGFloat = 11.5
    static let sectionChevronFont: CGFloat = 8.5
    static let sectionHeight: CGFloat = 29
    static let rowFont: CGFloat = 12.5
    static let rowIconFont: CGFloat = 11.75
    static let rootIconFont: CGFloat = 12
    static let countFont: CGFloat = 10.5
    static let minorFont: CGFloat = 9.5
    static let disclosureFont: CGFloat = 8.25
    static let rowHeight: CGFloat = 29
    static let iconColumnWidth: CGFloat = 16
}

enum ExplorerCreationKind: String, CaseIterable, Identifiable, Sendable {
    case cFile
    case headerFile
    case folder

    var id: String { rawValue }

    var defaultName: String {
        switch self {
        case .cFile: return "未命名.c"
        case .headerFile: return "未命名.h"
        case .folder: return "新建文件夹"
        }
    }

    var symbol: String {
        switch self {
        case .cFile: return "c.square.fill"
        case .headerFile: return "h.square.fill"
        case .folder: return "folder"
        }
    }

    var fileExtension: String? {
        switch self {
        case .cFile: return "c"
        case .headerFile: return "h"
        case .folder: return nil
        }
    }

    var menuTitle: String {
        switch self {
        case .cFile: return "新建 C 文件"
        case .headerFile: return "新建头文件"
        case .folder: return "新建文件夹"
        }
    }
}

struct ExplorerCreationRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let parentDirectory: URL
    let kind: ExplorerCreationKind

    init(
        parentDirectory: URL,
        kind: ExplorerCreationKind,
        id: UUID = UUID()
    ) {
        self.id = id
        self.parentDirectory = parentDirectory
        self.kind = kind
    }
}

struct ExplorerCreationInputRow: View {
    let kind: ExplorerCreationKind
    let depth: Int
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Color.clear.frame(width: 10, height: 1)

            Image(systemName: kind.symbol)
                .font(.system(size: ExplorerMetrics.rowIconFont))
                .foregroundStyle(CodexPalette.accent)
                .frame(width: ExplorerMetrics.iconColumnWidth)

            ExplorerInlineNameEditor(
                initialName: kind.defaultName,
                accessibilityLabel: kind.menuTitle,
                onCommit: onCommit,
                onCancel: onCancel
            )
        }
        .padding(.leading, CGFloat(depth) * 14 + 7)
        .padding(.trailing, 7)
        .frame(maxWidth: .infinity, minHeight: ExplorerMetrics.rowHeight)
        .background(CodexPalette.selected.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct ExplorerInlineNameEditor: View {
    let accessibilityLabel: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @State private var didRequestFocus = false
    @State private var isFinished = false
    @FocusState private var isFocused: Bool

    init(
        initialName: String,
        accessibilityLabel: String,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.onCommit = onCommit
        self.onCancel = onCancel
        _text = State(initialValue: initialName)
    }

    var body: some View {
        TextField("", text: $text)
            .font(.system(size: ExplorerMetrics.rowFont))
            .textFieldStyle(.plain)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 24)
            .background(Color.white)
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(CodexPalette.accent, lineWidth: 1)
            }
            .focused($isFocused)
            .accessibilityLabel(accessibilityLabel)
            .onSubmit {
                submit()
            }
            .onExitCommand {
                cancel()
            }
            .onChange(of: isFocused) { hasFocus in
                if !hasFocus, didRequestFocus {
                    submit()
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    guard !isFinished else { return }
                    didRequestFocus = true
                    isFocused = true
                    DispatchQueue.main.async {
                        NSApp.sendAction(
                            #selector(NSText.selectAll(_:)),
                            to: nil,
                            from: nil
                        )
                    }
                }
            }
    }

    private func submit() {
        guard !isFinished else { return }
        isFinished = true
        onCommit(text)
    }

    private func cancel() {
        guard !isFinished else { return }
        isFinished = true
        onCancel()
    }
}
