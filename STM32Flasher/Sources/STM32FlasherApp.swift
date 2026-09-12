import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct STM32FlasherApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @StateObject private var model = FlasherModel()
    @StateObject private var appearance = AppearanceSettings()

    var body: some Scene {
        WindowGroup {
            MinimalRootView()
                .environmentObject(model)
                .environmentObject(appearance)
                .frame(minWidth: 960, minHeight: 650)
                .onAppear {
                    appDelegate.model = model
                    appDelegate.configureInitialWindowSize()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 768)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建 C 程序") {
                    NotificationCenter.default.post(name: .newSourceRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(model.isBusy)
            }

            CommandGroup(after: .newItem) {
                Button("打开 C 文件…") {
                    NotificationCenter.default.post(name: .openSourceRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(model.isBusy)

                Button("打开文件夹…") {
                    NotificationCenter.default.post(name: .openFolderRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.isBusy)

                Divider()

                Button("保存") {
                    _ = SourceFileActions.save(model: model)
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(model.isBusy)

                Button("另存为…") {
                    _ = SourceFileActions.saveAs(model: model)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.isBusy)
            }

            CommandMenu("烧录") {
                Button("检测设备") { model.detectProbe() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(model.isBusy || !model.hasCLI)
                Button("开始烧录") { model.flash() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!model.canFlash)
                Button("停止当前操作") { model.cancel() }
                    .disabled(!model.isBusy)
            }

            CommandMenu("代码") {
                Button("编译") { model.compileSource() }
                    .keyboardShortcut("b", modifiers: [.command])
                    .disabled(!model.canCompile)
                Button("AI 一键导入、编译并烧录") {
                    model.importClipboardAndBuildAndFlash()
                }
                .disabled(!model.canImportClipboardAndFlash)
                Button("烧录") { model.flash() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!model.canFlashCompiledSource)
            }

            CommandGroup(after: .toolbar) {
                Divider()

                Button("放大代码") { appearance.zoomEditorIn() }
                    .keyboardShortcut("+", modifiers: [.command])
                    .disabled(
                        appearance.editorFontSize >= AppearanceSettings.maximumEditorFontSize
                    )
                Button("缩小代码") { appearance.zoomEditorOut() }
                    .keyboardShortcut("-", modifiers: [.command])
                    .disabled(
                        appearance.editorFontSize <= AppearanceSettings.minimumEditorFontSize
                    )
                Button("恢复默认代码字号") { appearance.resetEditorZoom() }
                    .keyboardShortcut("0", modifiers: [.command])

                Text("当前代码字号：\(Int(appearance.editorFontSize))")
            }
        }
    }
}

@MainActor
private enum SourceFileActions {
    static func save(model: FlasherModel) -> Bool {
        if model.selectedProjectFile != nil {
            guard model.currentSourceHasExternalChanges else {
                return model.saveCurrentSource()
            }

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "磁盘上的源码已经变化"
            alert.informativeText = "这个文件可能被访达、其他编辑器或 AI 修改过。"
                + "为防止覆盖外部改动，建议另存为；只有确认当前编辑器内容正确时才覆盖。"
            alert.addButton(withTitle: "另存为…")
            alert.addButton(withTitle: "仍要覆盖")
            alert.addButton(withTitle: "取消")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                return saveAs(model: model)
            case .alertSecondButtonReturn:
                return model.saveCurrentSource(allowExternalOverwrite: true)
            default:
                return false
            }
        }

        return saveAs(model: model)
    }

    static func saveAs(model: FlasherModel) -> Bool {
        let panel = NSSavePanel()
        panel.title = "保存源码文件"
        panel.prompt = "保存"
        let sourceExtension = URL(fileURLWithPath: model.sourceFileName)
            .pathExtension
            .lowercased()
        panel.nameFieldStringValue = ["c", "h"].contains(sourceExtension)
            ? model.sourceFileName
            : "main.c"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "c") ?? .plainText,
            UTType(filenameExtension: "h") ?? .plainText
        ]
        panel.directoryURL = model.selectedProjectFile?.url.deletingLastPathComponent()
            ?? model.projectDirectoryURL
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return model.saveSource(url)
    }
}

@MainActor
private final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    weak var model: FlasherModel?
    private var didConfigureInitialWindowSize = false
    private let mainWindowFrameName = NSWindow.FrameAutosaveName("STM32Flasher.MainWindow")

    func configureInitialWindowSize() {
        guard !didConfigureInitialWindowSize else { return }

        // 等 SwiftUI 完成首轮布局后再设置外框，避免系统恢复记录覆盖窗口尺寸。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self, !self.didConfigureInitialWindowSize else { return }
            guard let window = NSApp.keyWindow
                ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })
                ?? NSApp.windows.first
            else { return }

            let visibleFrame = window.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1360, height: 820)
            let targetWidth = min(1280, visibleFrame.width * 0.94)
            // hiddenTitleBar 会让屏幕上的可见窗口比 NSWindow 外框少约 18 点；
            // 这里补偿后，可见尺寸与 Steam 的 1280×800 窗口一致。
            let targetHeight = min(820, visibleFrame.height * 0.94)
            let horizontalOffset = min(14, max(0, visibleFrame.width - targetWidth))
            let topInset = min(16, max(0, visibleFrame.height - targetHeight))
            let targetFrame = NSRect(
                x: visibleFrame.midX - targetWidth / 2 + horizontalOffset,
                y: visibleFrame.maxY - targetHeight - topInset,
                width: targetWidth,
                height: targetHeight
            )

            window.contentMinSize = NSSize(width: 960, height: 650)
            window.setFrame(targetFrame, display: true, animate: false)
            window.setFrameAutosaveName(self.mainWindowFrameName)
            self.didConfigureInitialWindowSize = true
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        return UnsavedChangesPrompt.resolve(model: model) ? .terminateNow : .terminateCancel
    }
}

@MainActor
private enum UnsavedChangesPrompt {
    static func resolve(model: FlasherModel) -> Bool {
        guard model.sourceIsDirty else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "代码尚未保存"
        alert.informativeText = "继续操作前，要保存对 \(model.sourceFileName) 的修改吗？"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return SourceFileActions.save(model: model)

        case .alertSecondButtonReturn:
            return true

        default:
            return false
        }
    }
}

private enum Workspace: String, CaseIterable, Identifiable {
    case flash = "烧录"
    case code = "代码"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .flash: return "arrow.down.to.line.compact"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

private extension Notification.Name {
    static let newSourceRequested = Notification.Name("STM32Flasher.NewSourceRequested")
    static let openSourceRequested = Notification.Name("STM32Flasher.OpenSourceRequested")
    static let openFolderRequested = Notification.Name("STM32Flasher.OpenFolderRequested")
}

private enum WorkspaceLayoutMetrics {
    static let sidebarMinimum: CGFloat = 232
    static let sidebarDefault: CGFloat = 260
    static let sidebarMaximum: CGFloat = 310
}

private struct MinimalRootView: View {
    @EnvironmentObject private var model: FlasherModel
    @EnvironmentObject private var appearance: AppearanceSettings

    @State private var workspace: Workspace = .flash
    @State private var isDropTargeted = false
    @State private var isShowingSettings = false
    @State private var areOpenEditorsExpanded = true
    @State private var isExplorerExpanded = true
    @State private var selectedExplorerDirectory: URL?
    @State private var explorerCreationRequest: ExplorerCreationRequest?
    @State private var renamingOpenEditorID: String?
    @State private var pendingMoveEntry: WorkspaceEntry?
    @State private var sidebarWidth: CGFloat = WorkspaceLayoutMetrics.sidebarDefault
    @State private var sidebarDragStartWidth: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)

            sidebarDivider

            ZStack {
                flashWorkspace
                    .opacity(workspace == .flash ? 1 : 0)
                    .allowsHitTesting(workspace == .flash)
                    .accessibilityHidden(workspace != .flash)

                codeWorkspace
                    .opacity(workspace == .code ? 1 : 0)
                    .allowsHitTesting(workspace == .code)
                    .accessibilityHidden(workspace != .code)
            }
            .frame(minWidth: 720, maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(CodexPalette.canvas)
        .preferredColorScheme(.light)
        .tint(CodexPalette.accent)
        .overlay {
            if model.isShowingAlert {
                globalNotice
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(100)
            }
        }
        .animation(.easeOut(duration: 0.16), value: model.isShowingAlert)
        .sheet(isPresented: $isShowingSettings) {
            SettingsSheet()
                .environmentObject(model)
                .environmentObject(appearance)
        }
        .onAppear { model.bootstrap() }
        .onReceive(NotificationCenter.default.publisher(for: .newSourceRequested)) { _ in
            createNewSource()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSourceRequested)) { _ in
            openSource()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFolderRequested)) { _ in
            openFolder()
        }
        .onChange(of: model.projectDirectoryURL) { directoryURL in
            selectedExplorerDirectory = directoryURL
            explorerCreationRequest = nil
            renamingOpenEditorID = nil
            pendingMoveEntry = nil
        }
    }

    private var sidebarDivider: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(CodexPalette.border)
                .frame(width: 1)
        }
        .frame(width: 6)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if sidebarDragStartWidth == nil {
                        sidebarDragStartWidth = sidebarWidth
                    }
                    let startWidth = sidebarDragStartWidth ?? sidebarWidth
                    sidebarWidth = min(
                        WorkspaceLayoutMetrics.sidebarMaximum,
                        max(
                            WorkspaceLayoutMetrics.sidebarMinimum,
                            startWidth + value.translation.width
                        )
                    )
                }
                .onEnded { _ in
                    sidebarDragStartWidth = nil
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                sidebarWidth = WorkspaceLayoutMetrics.sidebarDefault
            }
        )
        .accessibilityElement()
        .accessibilityLabel("调整资源管理器宽度")
        .accessibilityValue("\(Int(sidebarWidth)) 点")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                sidebarWidth = min(
                    WorkspaceLayoutMetrics.sidebarMaximum,
                    sidebarWidth + 16
                )
            case .decrement:
                sidebarWidth = max(
                    WorkspaceLayoutMetrics.sidebarMinimum,
                    sidebarWidth - 16
                )
            @unknown default:
                break
            }
        }
        .help("拖动调整宽度，双击恢复默认")
    }

    private var globalNotice: some View {
        ZStack {
            Color.black.opacity(0.08)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: noticeSymbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(noticeColor)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.alertTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(CodexPalette.primaryText)
                        Text(model.alertMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(CodexPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack {
                    Text("点击窗口任意位置关闭")
                        .font(.system(size: 9.5))
                        .foregroundStyle(CodexPalette.faintText)
                    Spacer()
                    Button("知道了") {
                        dismissGlobalNotice()
                    }
                    .buttonStyle(CompactPrimaryButtonStyle())
                }
            }
            .padding(18)
            .frame(width: 380)
            .background(CodexPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(CodexPalette.strongBorder)
            }
            .shadow(color: Color.black.opacity(0.12), radius: 26, y: 10)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            dismissGlobalNotice()
        }
    }

    private var noticeSymbol: String {
        let title = model.alertTitle.lowercased()
        if title.contains("成功") { return "checkmark.circle.fill" }
        if title.contains("失败") || title.contains("错误") || title.contains("无法") {
            return "exclamationmark.triangle.fill"
        }
        return "info.circle.fill"
    }

    private var noticeColor: Color {
        let title = model.alertTitle.lowercased()
        if title.contains("成功") { return CodexPalette.success }
        if title.contains("失败") || title.contains("错误") || title.contains("无法") {
            return CodexPalette.danger
        }
        return CodexPalette.accent
    }

    private func dismissGlobalNotice() {
        model.isShowingAlert = false
    }

    private var sidebar: some View {
        ProportionalWidthContainer(referenceWidth: 260, minimumScale: 0.90) {
            HStack(spacing: 0) {
                activityRail
                explorerPanel
            }
            .background(CodexPalette.sidebar)
        }
    }

    private var activityRail: some View {
        VStack(spacing: 6) {
            activityButton(for: .code, title: "代码")
            activityButton(for: .flash, title: "烧录")

            Spacer()

            Button { isShowingSettings = true } label: {
                activityRailLabel(
                    symbol: "gearshape",
                    title: "设置",
                    isSelected: false
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(CodexPalette.mutedText)
            .help("设置")
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(width: 48)
        .background(CodexPalette.elevated.opacity(0.5))
        .overlay(alignment: .trailing) {
            Rectangle().fill(CodexPalette.border).frame(width: 1)
        }
    }

    private func activityButton(for item: Workspace, title: String) -> some View {
        Button {
            switchWorkspace(item)
        } label: {
            activityRailLabel(
                symbol: item.symbol,
                title: title,
                isSelected: workspace == item
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(workspace == item ? CodexPalette.primaryText : CodexPalette.mutedText)
        .help(title)
    }

    private func activityRailLabel(
        symbol: String,
        title: String,
        isSelected: Bool
    ) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(height: 18)
            Text(title)
                .font(.system(size: 9.5, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
        }
        .frame(width: 44, height: 46)
        .background(isSelected ? CodexPalette.selected : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(isSelected ? CodexPalette.accent : .clear)
                .frame(width: 2, height: 28)
        }
    }

    private var explorerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            explorerHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    explorerSectionHeader(
                        "打开的编辑器",
                        isExpanded: $areOpenEditorsExpanded
                    )
                    if areOpenEditorsExpanded {
                        openEditorsList
                    }

                    explorerSectionHeader(
                        projectExplorerTitle,
                        isExpanded: $isExplorerExpanded
                    )
                    if isExplorerExpanded {
                        projectTree
                    }
                }
                .padding(.bottom, 8)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(sidebarServiceIsReady ? CodexPalette.success : CodexPalette.warning)
                    .frame(width: 6, height: 6)
                Text(sidebarServiceText)
                    .font(.system(size: 11))
                    .foregroundStyle(CodexPalette.secondaryText)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .overlay(alignment: .top) {
                Rectangle().fill(CodexPalette.border).frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var sidebarServiceIsReady: Bool {
        workspace == .code ? model.hasCompiler : model.hasCLI
    }

    private var sidebarServiceText: String {
        if workspace == .code {
            return model.compilerName
        }
        return model.hasCLI ? "烧录引擎已就绪" : "需要安装烧录引擎"
    }

    private var explorerHeader: some View {
        HStack(spacing: 2) {
            Text("资源管理器")
                .font(.system(size: ExplorerMetrics.headerTitleFont, weight: .semibold))
                .foregroundStyle(CodexPalette.primaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer()

            Button(action: createNewSource) { Image(systemName: "doc.badge.plus") }
                .disabled(model.isBusy)
                .buttonStyle(SubtleIconButtonStyle())
                .accessibilityLabel("新建 C 文件")
                .help(newEntryLocationHelp(prefix: "新建 C 文件"))

            Button(action: beginCreatingFolder) { Image(systemName: "folder.badge.plus") }
                .disabled(model.isBusy)
                .buttonStyle(SubtleIconButtonStyle())
                .accessibilityLabel("新建文件夹")
                .help(newEntryLocationHelp(prefix: "新建文件夹"))

            Button(action: openFolder) { Image(systemName: "folder") }
                .buttonStyle(SubtleIconButtonStyle())
                .accessibilityLabel("打开工程文件夹")
                .help("打开工程文件夹")

            Menu {
                Button("新建头文件") {
                    beginCreating(.headerFile)
                }
                .disabled(model.projectDirectoryURL == nil || model.isBusy)

                Divider()

                Button("打开单个 C 文件…", action: openSource)
                Button("刷新资源管理器", action: refreshProject)
                    .disabled(model.projectDirectoryURL == nil || model.isBusy)

                Button("粘贴") {
                    guard let projectDirectoryURL = model.projectDirectoryURL else { return }
                    model.pasteCopiedProjectEntry(
                        into: selectedExplorerDirectory ?? projectDirectoryURL
                    )
                }
                .disabled(model.copiedProjectEntry == nil || model.projectDirectoryURL == nil || model.isBusy)

                Button("撤销最近文件操作", action: model.undoLastWorkspaceOperation)
                    .disabled(!model.canUndoWorkspaceOperation || model.isBusy)

                if !model.recentProjectPaths.isEmpty {
                    Divider()
                    Menu("最近打开的工程") {
                        ForEach(model.recentProjectPaths, id: \.self) { path in
                            Button(URL(fileURLWithPath: path).lastPathComponent) {
                                guard UnsavedChangesPrompt.resolve(model: model) else { return }
                                model.openRecentProject(atPath: path)
                                switchWorkspace(.code)
                            }
                            .help(path)
                        }
                    }
                }

                if let projectDirectoryURL = model.projectDirectoryURL {
                    Divider()
                    Button("在访达中显示") {
                        revealInFinder(projectDirectoryURL)
                    }
                    Button("复制工程路径") {
                        copyRelativePath(projectDirectoryURL)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("更多文件操作")
            .help("更多文件操作")
        }
        .font(.system(size: ExplorerMetrics.toolbarIconFont, weight: .medium))
        .foregroundStyle(CodexPalette.mutedText)
        .padding(.horizontal, 9)
        .frame(height: ExplorerMetrics.toolbarHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CodexPalette.border).frame(height: 1)
        }
    }

    private var openEditorsList: some View {
        VStack(spacing: 1) {
            if model.selectedProjectFile == nil {
                openEditorRow(
                    id: "untitled-editor",
                    title: untitledEditorTitle,
                    renameName: model.sourceFileName,
                    symbol: untitledEditorSymbol,
                    isSelected: true,
                    dirty: model.sourceIsDirty,
                    onSelect: { switchWorkspace(.code) },
                    onClose: nil,
                    onRename: renameUntitledSource,
                    onOpenWith: nil,
                    onSaveAs: { _ = SourceFileActions.saveAs(model: model) },
                    onReveal: nil,
                    onCopyPath: nil
                )
            }
            ForEach(model.openFiles) { file in
                openEditorRow(
                    id: file.id,
                    title: editorDisplayTitle(for: file),
                    renameName: file.name,
                    symbol: file.symbol,
                    isSelected: model.selectedProjectFile == file,
                    dirty: model.selectedProjectFile == file && model.sourceIsDirty,
                    onSelect: { selectSource(file) },
                    onClose: { closeSource(file) },
                    onRename: { renameWorkspaceEntry(WorkspaceEntry(url: file.url, isDirectory: false), to: $0) },
                    onOpenWith: { openWith(file.url) },
                    onSaveAs: { _ = SourceFileActions.saveAs(model: model) },
                    onReveal: { revealInFinder(file.url) },
                    onCopyPath: { copyRelativePath(file.url) }
                )
            }
        }
        .padding(.bottom, 5)
        .disabled(model.isBusy)
    }

    private func openEditorRow(
        id: String,
        title: String,
        renameName: String,
        symbol: String,
        isSelected: Bool,
        dirty: Bool,
        onSelect: @escaping () -> Void,
        onClose: (() -> Void)?,
        onRename: ((String) -> Void)?,
        onOpenWith: (() -> Void)?,
        onSaveAs: (() -> Void)?,
        onReveal: (() -> Void)?,
        onCopyPath: (() -> Void)?
    ) -> some View {
        HStack(spacing: 7) {
            if renamingOpenEditorID == id, let onRename {
                Image(systemName: symbol)
                    .font(.system(size: ExplorerMetrics.rowIconFont))
                    .frame(width: ExplorerMetrics.iconColumnWidth)
                    .foregroundStyle(CodexPalette.mutedText)

                ExplorerInlineNameEditor(
                    initialName: renameName,
                    accessibilityLabel: "重命名编辑器",
                    onCommit: { name in
                        renamingOpenEditorID = nil
                        onRename(name)
                    },
                    onCancel: {
                        renamingOpenEditorID = nil
                    }
                )

                if dirty {
                    Circle().fill(CodexPalette.warning).frame(width: 5, height: 5)
                }
            } else {
                Button(action: onSelect) {
                    HStack(spacing: 7) {
                        Image(systemName: symbol)
                            .font(.system(size: ExplorerMetrics.rowIconFont))
                            .frame(width: ExplorerMetrics.iconColumnWidth)
                        Text(title)
                            .font(.system(
                                size: ExplorerMetrics.rowFont,
                                weight: isSelected ? .medium : .regular
                            ))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        if dirty {
                            Circle().fill(CodexPalette.warning).frame(width: 5, height: 5)
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? CodexPalette.primaryText : CodexPalette.secondaryText)
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        guard onRename != nil else { return }
                        renamingOpenEditorID = id
                    }
                )
            }

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(CodexPalette.faintText)
            }
        }
        .padding(.leading, 15)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, minHeight: ExplorerMetrics.rowHeight)
        .background(isSelected ? CodexPalette.selected : Color.clear)
        .contentShape(Rectangle())
        .contextMenu {
            Button("打开", action: onSelect)
            if let onOpenWith {
                Button("打开方式…", action: onOpenWith)
            }
            if onRename != nil {
                Button("重命名") {
                    renamingOpenEditorID = id
                }
            }
            if let onSaveAs {
                Button("另存为…", action: onSaveAs)
            }
            if let onReveal {
                Divider()
                Button("在访达中显示", action: onReveal)
            }
            if let onCopyPath {
                Button("复制相对路径", action: onCopyPath)
            }
            if let onClose {
                Divider()
                Button("关闭编辑器", action: onClose)
            }
        }
        .help(title)
    }

    @ViewBuilder
    private func explorerSectionHeader(_ title: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            isExpanded.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: ExplorerMetrics.sectionChevronFont, weight: .semibold))
                    .frame(width: 10)
                Text(title.uppercased())
                    .font(.system(size: ExplorerMetrics.sectionTitleFont, weight: .semibold))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: ExplorerMetrics.sectionHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(CodexPalette.mutedText)
    }

    private var projectExplorerTitle: String {
        "文件夹"
    }

    private func beginCreatingFolder() {
        guard model.projectDirectoryURL != nil else {
            createProjectFolder()
            return
        }
        beginCreating(.folder)
    }

    private func beginCreating(_ kind: ExplorerCreationKind) {
        guard let projectDirectoryURL = model.projectDirectoryURL else { return }
        let selectedFileDirectory = model.selectedProjectFile?.url.deletingLastPathComponent()
        let preferredDirectory = selectedExplorerDirectory ?? selectedFileDirectory
        let destinationURL = preferredDirectory.flatMap { selected in
            WorkspacePathSafety.isWithinProject(selected, projectRoot: projectDirectoryURL)
                ? selected
                : nil
        } ?? projectDirectoryURL
        selectedExplorerDirectory = destinationURL
        explorerCreationRequest = ExplorerCreationRequest(
            parentDirectory: destinationURL,
            kind: kind
        )
    }

    private func createExplorerEntry(
        in parentDirectoryURL: URL,
        kind: ExplorerCreationKind,
        named name: String
    ) {
        switch kind {
        case .folder:
            if let folderURL = model.createFolder(named: name, in: parentDirectoryURL) {
                selectedExplorerDirectory = folderURL
            }
        case .cFile, .headerFile:
            guard UnsavedChangesPrompt.resolve(model: model) else { return }
            model.createSourceFile(
                named: name,
                expectedExtension: kind.fileExtension ?? "c",
                in: parentDirectoryURL
            )
            switchWorkspace(.code)
        }
    }

    private func createProjectFolder() {
        guard UnsavedChangesPrompt.resolve(model: model) else { return }

        let panel = NSSavePanel()
        panel.title = "新建 STM32 工程文件夹"
        panel.message = "选择保存位置并输入文件夹名称。软件会创建该文件夹和一个空的 main.c。"
        panel.prompt = "创建"
        panel.nameFieldStringValue = "STM32工程"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = true
        panel.begin { response in
            guard response == .OK, let directoryURL = panel.url else { return }
            model.createProject(at: directoryURL)
            switchWorkspace(.code)
        }
    }

    @ViewBuilder
    private var projectTree: some View {
        if let projectDirectoryURL = model.projectDirectoryURL {
            ProjectExplorerTree(
                root: projectDirectoryURL,
                entries: model.projectEntries,
                selectedDirectory: $selectedExplorerDirectory,
                creationRequest: $explorerCreationRequest,
                selectedFile: model.selectedProjectFile,
                sourceIsDirty: model.sourceIsDirty,
                onOpenFile: selectWorkspaceEntry,
                onOpenWith: openWith,
                onSaveAs: saveAsWorkspaceFile,
                onCreateEntry: createExplorerEntry,
                onRenameEntry: renameWorkspaceEntry,
                onMoveFile: moveWorkspaceEntry,
                onCopyEntry: model.copyProjectEntry,
                onPasteEntry: model.pasteCopiedProjectEntry,
                canPaste: model.copiedProjectEntry != nil,
                onDropFile: moveDroppedProjectFile,
                onRevealInFinder: revealInFinder,
                onCopyRelativePath: copyRelativePath,
                onCloseFolder: model.closeProject
            )
            .id(projectDirectoryURL.standardizedFileURL.path)
            .disabled(model.isBusy)
            .padding(.horizontal, 5)
            .sheet(item: $pendingMoveEntry) { entry in
                MoveDestinationSheet(
                    entry: entry,
                    projectRoot: projectDirectoryURL,
                    directories: model.projectEntries
                        .filter(\.isDirectory)
                        .map(\.url),
                    onMove: { destinationURL in
                        model.moveProjectEntry(entry, to: destinationURL)
                        pendingMoveEntry = nil
                    }
                )
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                Text("尚未打开文件夹")
                    .font(.system(size: ExplorerMetrics.rowFont, weight: .medium))
                    .foregroundStyle(CodexPalette.secondaryText)
                Text("打开文件夹后，在这里显示完整工程树。")
                    .font(.system(size: 11))
                    .foregroundStyle(CodexPalette.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开文件夹", action: openFolder)
                    .buttonStyle(TextOnlyButtonStyle())
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private var flashWorkspace: some View {
        VStack(spacing: 0) {
            pageHeader(
                title: "烧录程序",
                subtitle: "选择程序，然后写入 STM32F103C8T6"
            ) {
                StatusChip(
                    title: model.probeStatus.title,
                    symbol: model.probeStatus.symbol,
                    color: model.probeStatus.color
                )
            }

            ScrollView {
                VStack(spacing: 12) {
                    if !model.hasCLI {
                        backendNotice
                    }

                    WhiteCard(title: "固件与设备", caption: "擦除 · 写入 · 校验 · 复位") {
                        stepLabel(number: "1", title: "选择程序")

                        firmwarePicker

                        if model.isBinaryFirmware {
                            HStack(spacing: 10) {
                                Text("BIN 起始地址")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(CodexPalette.mutedText)
                                TextField("0x08000000", text: $model.binaryAddress)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12, design: .monospaced))
                                    .padding(.horizontal, 10)
                                    .frame(width: 150, height: 30)
                                    .background(CodexPalette.elevated)
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                Spacer()
                            }
                        }

                        Rectangle()
                            .fill(CodexPalette.border)
                            .frame(height: 1)

                        stepLabel(number: "2", title: "检测设备")

                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(model.probeStatus.color.opacity(0.10))
                                Image(systemName: model.probeStatus.symbol)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(model.probeStatus.color)
                            }
                            .frame(width: 42, height: 42)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.probeDisplayName)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(CodexPalette.primaryText)
                                Text(model.probeDiagnosticTitle)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(CodexPalette.secondaryText)
                                Text(model.probeDiagnosticDetail)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(CodexPalette.mutedText)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button {
                                model.detectProbe()
                            } label: {
                                Label(model.isDetecting ? "检测中" : "检测设备", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(model.isBusy || !model.hasCLI)
                        }

                        Rectangle()
                            .fill(CodexPalette.border)
                            .frame(height: 1)

                        stepLabel(number: "3", title: "开始烧录")

                        if model.isBusy {
                            VStack(alignment: .leading, spacing: 7) {
                                ProgressView()
                                    .progressViewStyle(.linear)
                                    .tint(CodexPalette.accent)
                                HStack {
                                    Text(model.operationText)
                                    Spacer()
                                    Text("请勿断开设备")
                                }
                                .font(.system(size: 10.5))
                                .foregroundStyle(CodexPalette.mutedText)
                            }
                        }

                        Button {
                            model.flash()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.down.to.line.compact")
                                Text(model.isFlashing ? "正在烧录…" : "开始烧录")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!model.canFlash)

                        if !model.canFlash {
                            HStack {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(CodexPalette.faintText)
                                Text(model.flashReadinessText)
                                Spacer()
                                if model.isBusy {
                                    Button("停止") { model.cancel() }
                                        .buttonStyle(TextOnlyButtonStyle())
                                }
                            }
                            .font(.system(size: 10.5))
                            .foregroundStyle(CodexPalette.mutedText)
                        }
                    }

                    WhiteCard(title: "结果", caption: model.lastResultText) {
                        ConsoleText(text: model.logText)
                            .frame(height: 118)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9)
                                    .strokeBorder(CodexPalette.border)
                            }

                        HStack {
                            Text("日志最多保留 200,000 字符")
                                .font(.system(size: 9.5))
                                .foregroundStyle(CodexPalette.faintText)
                            Spacer()
                            Button("复制") { model.copyLog() }
                                .buttonStyle(TextOnlyButtonStyle())
                            Button("清空") { model.clearLog() }
                                .buttonStyle(TextOnlyButtonStyle())
                        }
                    }
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .background(CodexPalette.canvas)
        }
    }

    private var backendNotice: some View {
        WhiteCard(title: "需要 STM32CubeProgrammer") {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(CodexPalette.warning)
                Text("安装 ST 官方烧录引擎后即可使用。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(CodexPalette.secondaryText)
                Spacer()
                Button("选择已安装的引擎") { chooseCLI() }
                    .buttonStyle(QuietButtonStyle())
                Button("官方下载") { model.openCubeProgrammerDownload() }
                    .buttonStyle(QuietButtonStyle())
            }
        }
    }

    private var firmwarePicker: some View {
        Button(action: chooseFirmware) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            model.firmwareURL == nil
                                ? CodexPalette.elevated
                                : CodexPalette.success.opacity(0.09)
                        )
                    Image(systemName: model.firmwareURL == nil ? "doc.badge.plus" : "doc.badge.checkmark")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(
                            model.firmwareURL == nil
                                ? CodexPalette.mutedText
                                : CodexPalette.success
                        )
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.firmwareName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CodexPalette.primaryText)
                        .lineLimit(1)
                    Text(model.firmwareDescription)
                        .font(.system(size: 10.5))
                        .foregroundStyle(CodexPalette.mutedText)
                        .lineLimit(1)
                }

                Spacer()

                Text(model.firmwareURL == nil ? "选择文件" : "更换")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CodexPalette.secondaryText)
            }
            .padding(13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(CodexPalette.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(
                    isDropTargeted ? CodexPalette.accent : CodexPalette.strongBorder,
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            model.handleDrop(providers)
        }
    }

    private var codeWorkspace: some View {
        VStack(spacing: 0) {
            pageHeader(
                title: model.projectName,
                subtitle: "\(model.sourceFileName) · \(model.sourceLineCount) 行"
            ) {
                HStack(spacing: 6) {
                    Button {
                        model.detectProbe()
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(model.probeStatus.color)
                                .frame(width: 7, height: 7)
                            Text(model.isDetecting ? "检测中" : model.probeStatus.title)
                        }
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(model.isBusy || !model.hasCLI)
                    .help("检测 ST-Link")

                    Button(action: createNewSource) {
                        Label("新建", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(model.isBusy)
                    .help("新建 C 程序（⌘N）")

                    Button(action: openSource) {
                        Label("打开", systemImage: "folder")
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(model.isBusy)
                    .help("打开 C 文件（⌘O）")

                    Button(action: saveSource) {
                        Label("保存", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(model.isBusy)
                    .help("保存（⌘S）")

                    Rectangle()
                        .fill(CodexPalette.border)
                        .frame(width: 1, height: 18)
                        .padding(.horizontal, 2)

                    Button {
                        model.compileSource()
                    } label: {
                        Label(model.isCompiling ? "编译中" : "编译", systemImage: "hammer")
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!model.canCompile)
                    .help(model.compileUnavailableReason ?? "使用 ARM GCC 编译当前工程")

                    Button {
                        model.flash()
                    } label: {
                        Label(model.isFlashing ? "烧录中" : "烧录", systemImage: "arrow.down.to.line.compact")
                    }
                    .buttonStyle(CompactPrimaryButtonStyle())
                    .disabled(!model.canFlashCompiledSource)
                    .help(
                        model.hasFreshBuild
                            ? model.flashReadinessText
                            : "请先成功编译，再检测设备并烧录"
                    )

                    Button {
                        model.importClipboardAndBuildAndFlash()
                    } label: {
                        MinimalRocketGlyph()
                            .frame(width: 14, height: 17)
                            .accessibilityLabel("AI 一键导入、编译并烧录")
                    }
                    .buttonStyle(RocketToolbarButtonStyle())
                    .disabled(!model.canImportClipboardAndFlash)
                    .help(
                        model.aiOneClickUnavailableReason
                            ?? "从剪贴板导入 AI 代码，编译成功后自动烧录"
                    )
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    if model.selectedProjectFile == nil {
                        EditorTab(
                            title: untitledEditorTitle,
                            symbol: untitledEditorSymbol,
                            selected: true,
                            dirty: model.sourceIsDirty,
                            onSelect: { switchWorkspace(.code) },
                            onClose: nil
                        )
                        .disabled(model.isBusy)
                    }

                    ForEach(model.openFiles) { file in
                        EditorTab(
                            title: editorDisplayTitle(for: file),
                            symbol: file.symbol,
                            selected: model.selectedProjectFile == file,
                            dirty: model.selectedProjectFile == file && model.sourceIsDirty,
                            onSelect: { selectSource(file) },
                            onClose: { closeSource(file) }
                        )
                        .disabled(model.isBusy)
                    }
                }
            }
            .frame(height: 38)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CodexPalette.panel)
            .overlay(alignment: .bottom) {
                Rectangle().fill(CodexPalette.border).frame(height: 1)
            }

            SyntaxHighlightedCodeEditor(
                text: $model.sourceCode,
                onTextChange: { model.markSourceDirty() },
                fontSize: appearance.editorFontSize,
                wrapsLines: appearance.wrapsEditorLines,
                themeID: IDETheme.codexLight.rawValue,
                requestedLine: model.requestedSourceLine
            )
            .background(CodexPalette.editor)
            .disabled(model.isScanningProject)
            .overlay {
                if model.isScanningProject {
                    ZStack {
                        CodexPalette.editor.opacity(0.90)
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在读取工程文件，当前代码已锁定以防丢失")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(CodexPalette.secondaryText)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(CodexPalette.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(CodexPalette.border)
                        }
                    }
                }
            }

            buildOutput

            HStack(spacing: 12) {
                if let reason = model.compileUnavailableReason,
                   !model.isCompiling {
                    Label(reason, systemImage: "info.circle")
                        .foregroundStyle(CodexPalette.mutedText)
                        .lineLimit(1)
                } else {
                    Text(model.lastBuildText)
                        .lineLimit(1)
                }
                Spacer()
                if model.hasFreshBuild {
                    UsageMeter(label: "FLASH", value: model.flashUsageText, progress: model.flashUsage)
                    UsageMeter(label: "RAM", value: model.ramUsageText, progress: model.ramUsage)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(CodexPalette.mutedText)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(CodexPalette.sidebar)
            .overlay(alignment: .top) {
                Rectangle().fill(CodexPalette.border).frame(height: 1)
            }
        }
        .background(CodexPalette.panel)
    }

    private var buildOutput: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    appearance.showsBuildOutput.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: appearance.showsBuildOutput ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                        Text("编译输出")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(CodexPalette.secondaryText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(appearance.showsBuildOutput ? "收起编译输出" : "展开编译输出")
                if model.buildErrorCount > 0 {
                    Text("\(model.buildErrorCount) 个错误")
                        .foregroundStyle(CodexPalette.danger)
                }
                if model.buildWarningCount > 0 {
                    Text("\(model.buildWarningCount) 个警告")
                        .foregroundStyle(CodexPalette.warning)
                }
                Spacer()
                Button("输出目录") { model.revealBuildFolder() }
                    .buttonStyle(TextOnlyButtonStyle())
                Button("清空") { model.clearBuildLog() }
                    .buttonStyle(TextOnlyButtonStyle())
            }
            .font(.system(size: 9.5))
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(CodexPalette.sidebar)

            if appearance.showsBuildOutput {
                if !model.buildIssues.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.buildIssues) { issue in
                                Button {
                                    model.navigateToBuildIssue(issue)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: issue.severity == .error
                                            ? "xmark.circle.fill"
                                            : (issue.severity == .warning
                                                ? "exclamationmark.triangle.fill"
                                                : "info.circle.fill"))
                                            .foregroundStyle(issue.severity == .error
                                                ? CodexPalette.danger
                                                : (issue.severity == .warning
                                                    ? CodexPalette.warning
                                                    : CodexPalette.mutedText))
                                        Text(issue.message)
                                            .lineLimit(1)
                                            .foregroundStyle(CodexPalette.secondaryText)
                                        Spacer(minLength: 8)
                                        Text("\(issue.fileURL.lastPathComponent):\(issue.line):\(issue.column)")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(CodexPalette.faintText)
                                            .fixedSize()
                                    }
                                    .padding(.horizontal, 13)
                                    .frame(height: 28)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 112)
                    .background(CodexPalette.elevated.opacity(0.45))
                }
                ConsoleText(text: model.buildLog)
                    .frame(height: model.buildIssues.isEmpty ? 146 : 96)
            }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(CodexPalette.border).frame(height: 1)
        }
    }

    private func pageHeader<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Content
    ) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(CodexPalette.primaryText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(CodexPalette.mutedText)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            trailing()
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 22)
        .frame(height: 68)
        .background(CodexPalette.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CodexPalette.border).frame(height: 1)
        }
    }

    private func stepLabel(number: String, title: String) -> some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CodexPalette.secondaryText)
                .frame(width: 22, height: 22)
                .background(CodexPalette.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(CodexPalette.border)
                }
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(CodexPalette.secondaryText)
        }
    }

    private func switchWorkspace(_ destination: Workspace) {
        guard destination != workspace else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        workspace = destination
    }

    private func chooseFirmware() {
        let panel = NSOpenPanel()
        panel.title = "选择 STM32 程序"
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.selectFirmware(url)
        }
    }

    private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.title = "选择 STM32_Programmer_CLI"
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.allowedContentTypes = [.data, .unixExecutable]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.selectCLI(url)
        }
    }

    private func openSource() {
        guard UnsavedChangesPrompt.resolve(model: model) else { return }

        let panel = NSOpenPanel()
        panel.title = "打开 C 程序"
        panel.prompt = "打开"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "c") ?? .plainText, .plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.openSource(url)
            switchWorkspace(.code)
        }
    }

    private func openFolder() {
        guard UnsavedChangesPrompt.resolve(model: model) else { return }

        let panel = NSOpenPanel()
        panel.title = "打开 STM32 工程文件夹"
        panel.prompt = "打开"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder]
        panel.resolvesAliases = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.openProject(url)
            switchWorkspace(.code)
        }
    }

    private func refreshProject() {
        model.refreshProjectFiles()
    }

    private func selectSource(_ file: ProjectFile) {
        guard model.selectedProjectFile != file else {
            switchWorkspace(.code)
            return
        }
        guard UnsavedChangesPrompt.resolve(model: model) else { return }
        model.openProjectFile(file)
        switchWorkspace(.code)
    }

    private func selectWorkspaceEntry(_ entry: WorkspaceEntry) {
        guard entry.isEditableSource else {
            model.reportUnsupportedWorkspaceFile(entry)
            return
        }
        selectSource(ProjectFile(url: entry.url))
    }

    private func moveWorkspaceEntry(_ entry: WorkspaceEntry) {
        guard model.projectDirectoryURL != nil, !entry.isDirectory else { return }
        pendingMoveEntry = entry
    }

    private func moveDroppedProjectFile(_ sourceURL: URL, _ destinationURL: URL) {
        model.moveDroppedProjectFile(at: sourceURL, to: destinationURL)
    }

    private func renameWorkspaceEntry(_ entry: WorkspaceEntry, to newName: String) {
        model.renameProjectEntry(entry, to: newName)
    }

    private func renameUntitledSource(to newName: String) {
        model.renameUntitledSource(to: newName)
    }

    private func revealInFinder(_ url: URL) {
        if url == model.projectDirectoryURL {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func openWith(_ url: URL) {
        let panel = NSOpenPanel()
        panel.title = "选择打开方式"
        panel.message = "选择一个 macOS 应用打开 (url.lastPathComponent)。"
        panel.prompt = "打开"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        panel.begin { response in
            guard response == .OK, let applicationURL = panel.url else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: applicationURL,
                configuration: configuration
            )
        }
    }

    /// 从资源管理器右键“另存为”时，先把目标文件设为当前编辑器，
    /// 防止用户在非当前文件上操作时误保存了另一份源码。
    private func saveAsWorkspaceFile(_ url: URL) {
        let file = ProjectFile(url: url)
        guard model.selectedProjectFile == file || UnsavedChangesPrompt.resolve(model: model) else {
            return
        }

        if model.selectedProjectFile != file {
            model.openProjectFile(file)
            switchWorkspace(.code)
        }

        // 等 SwiftUI 完成当前选中文件切换后再打开 NSSavePanel。
        DispatchQueue.main.async {
            _ = SourceFileActions.saveAs(model: model)
        }
    }

    private func copyRelativePath(_ url: URL) {
        let path: String
        if let projectDirectoryURL = model.projectDirectoryURL,
           WorkspacePathSafety.isWithinProject(url, projectRoot: projectDirectoryURL) {
            let rootPath = WorkspacePathSafety.canonical(projectDirectoryURL).path
            let candidatePath = WorkspacePathSafety.canonical(url).path
            path = candidatePath == rootPath
                ? rootPath
                : String(candidatePath.dropFirst(rootPath.count + 1))
        } else {
            path = url.path
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func closeSource(_ file: ProjectFile) {
        if model.selectedProjectFile == file {
            guard UnsavedChangesPrompt.resolve(model: model) else { return }
        }
        model.closeOpenFile(file)
    }

    private func createNewSource() {
        if model.projectDirectoryURL != nil {
            beginCreating(.cFile)
            return
        }
        guard UnsavedChangesPrompt.resolve(model: model) else { return }
        model.newSource()
        switchWorkspace(.code)
    }

    private var untitledEditorTitle: String {
        model.sourceFileName == "main.c" ? "未命名-1" : model.sourceFileName
    }

    private var untitledEditorSymbol: String {
        URL(fileURLWithPath: model.sourceFileName).pathExtension.lowercased() == "h"
            ? "h.square"
            : "c.square"
    }

    private func editorDisplayTitle(for file: ProjectFile) -> String {
        let labels = WorkspacePathPresentation.displayLabels(
            for: model.openFiles.map(\.url),
            projectRoot: model.projectDirectoryURL
        )
        let path = WorkspacePathSafety.canonical(file.url).path
        return labels[path]?.combined ?? file.name
    }

    private func newEntryLocationHelp(prefix: String) -> String {
        guard let projectDirectoryURL = model.projectDirectoryURL else {
            return prefix.contains("文件夹") ? "新建工程文件夹" : "新建未命名 C 程序"
        }
        let destination = selectedExplorerDirectory
            ?? model.selectedProjectFile?.url.deletingLastPathComponent()
            ?? projectDirectoryURL
        return "\(prefix) · \(destination.lastPathComponent)"
    }

    private func saveSource() {
        _ = SourceFileActions.save(model: model)
    }
}

private struct EditorTab: View {
    let title: String
    let symbol: String
    let selected: Bool
    let dirty: Bool
    let onSelect: () -> Void
    let onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onSelect) {
                HStack(spacing: 7) {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(CodexPalette.mutedText)
                    Text(title)
                        .font(.system(size: 10.5, weight: selected ? .medium : .regular))
                        .foregroundStyle(CodexPalette.primaryText)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            if dirty {
                Circle()
                    .fill(CodexPalette.warning)
                    .frame(width: 6, height: 6)
            } else if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(CodexPalette.faintText)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(selected ? CodexPalette.editor : CodexPalette.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(CodexPalette.border)
                .frame(width: 1)
        }
        .overlay(alignment: .top) {
            if selected {
                Rectangle()
                    .fill(CodexPalette.accent)
                    .frame(height: 2)
            }
        }
    }
}

private struct SettingsSheet: View {
    @EnvironmentObject private var model: FlasherModel
    @EnvironmentObject private var appearance: AppearanceSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("设置")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(CodexPalette.primaryText)
                    Text("只保留会影响日常使用的选项")
                        .font(.system(size: 10.5))
                        .foregroundStyle(CodexPalette.mutedText)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(CompactPrimaryButtonStyle())
            }
            .padding(22)

            Rectangle()
                .fill(CodexPalette.border)
                .frame(height: 1)

            Form {
                Section("代码") {
                    HStack {
                        Text("字体大小")
                        Slider(
                            value: appearance.editorFontSizeBinding,
                            in: (
                                AppearanceSettings.minimumEditorFontSize
                                    ... AppearanceSettings.maximumEditorFontSize
                            ),
                            step: 1
                        )
                        Text("\(Int(appearance.editorFontSize))")
                            .monospacedDigit()
                            .frame(width: 24)
                    }
                    Toggle("自动换行", isOn: $appearance.wrapsEditorLines)
                    Toggle("显示编译输出", isOn: $appearance.showsBuildOutput)
                }

                Section("烧录") {
                    Toggle("烧录前全片擦除", isOn: $model.eraseBeforeFlash)
                    Toggle("完成后复位运行", isOn: $model.resetAfterFlash)
                    Picker("连接速度", selection: $model.swdFrequency) {
                        ForEach([4000, 2000, 1000, 400, 100], id: \.self) { value in
                            Text("\(value) kHz").tag(value)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("恢复默认") {
                        appearance.reset()
                        model.eraseBeforeFlash = true
                        model.resetAfterFlash = true
                        model.swdFrequency = 4000
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .frame(width: 500, height: 440)
        .background(CodexPalette.canvas)
        .preferredColorScheme(.light)
    }
}
