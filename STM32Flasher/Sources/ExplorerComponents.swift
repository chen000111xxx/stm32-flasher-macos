import SwiftUI
import UniformTypeIdentifiers

private struct ExplorerActions {
    let openFile: (WorkspaceEntry) -> Void
    let openWith: (URL) -> Void
    let saveAs: (URL) -> Void
    let createEntry: (URL, ExplorerCreationKind, String) -> Void
    let renameEntry: (WorkspaceEntry, String) -> Void
    let moveFile: (WorkspaceEntry) -> Void
    let copyEntry: (WorkspaceEntry) -> Void
    let pasteEntry: (URL) -> Void
    let canPaste: Bool
    let revealInFinder: (URL) -> Void
    let copyRelativePath: (URL) -> Void
}

/// 资源树只持有展示和就地编辑状态；所有文件读写仍由上层模型执行。
struct ProjectExplorerTree: View {
    let root: URL
    let entries: [WorkspaceEntry]
    let selectedFile: ProjectFile?
    let sourceIsDirty: Bool
    @Binding var selectedDirectory: URL?
    @Binding var creationRequest: ExplorerCreationRequest?
    let onDropFile: (URL, URL) -> Void
    let onCloseFolder: () -> Void

    private let actions: ExplorerActions

    @State private var rootIsExpanded = true
    @State private var nodes: [ExplorerTreeNode]
    @State private var expandedNodeIDs: Set<String>
    @State private var editingEntryID: String?
    @State private var hoveredNodeID: String?
    @State private var dropTargetNodeID: String?

    init(
        root: URL,
        entries: [WorkspaceEntry],
        selectedDirectory: Binding<URL?>,
        creationRequest: Binding<ExplorerCreationRequest?>,
        selectedFile: ProjectFile?,
        sourceIsDirty: Bool,
        onOpenFile: @escaping (WorkspaceEntry) -> Void,
        onOpenWith: @escaping (URL) -> Void,
        onSaveAs: @escaping (URL) -> Void,
        onCreateEntry: @escaping (URL, ExplorerCreationKind, String) -> Void,
        onRenameEntry: @escaping (WorkspaceEntry, String) -> Void,
        onMoveFile: @escaping (WorkspaceEntry) -> Void,
        onCopyEntry: @escaping (WorkspaceEntry) -> Void,
        onPasteEntry: @escaping (URL) -> Void,
        canPaste: Bool,
        onDropFile: @escaping (URL, URL) -> Void,
        onRevealInFinder: @escaping (URL) -> Void,
        onCopyRelativePath: @escaping (URL) -> Void,
        onCloseFolder: @escaping () -> Void
    ) {
        let initialNodes = ExplorerTreeBuilder.make(root: root, entries: entries)
        self.root = root
        self.entries = entries
        self.selectedFile = selectedFile
        self.sourceIsDirty = sourceIsDirty
        _selectedDirectory = selectedDirectory
        _creationRequest = creationRequest
        self.actions = ExplorerActions(
            openFile: onOpenFile,
            openWith: onOpenWith,
            saveAs: onSaveAs,
            createEntry: onCreateEntry,
            renameEntry: onRenameEntry,
            moveFile: onMoveFile,
            copyEntry: onCopyEntry,
            pasteEntry: onPasteEntry,
            canPaste: canPaste,
            revealInFinder: onRevealInFinder,
            copyRelativePath: onCopyRelativePath
        )
        self.onDropFile = onDropFile
        self.onCloseFolder = onCloseFolder
        _nodes = State(initialValue: initialNodes)
        _expandedNodeIDs = State(initialValue: Self.initialExpandedIDs(in: initialNodes))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            rootRow

            if rootIsExpanded {
                if let request = rootCreationRequest {
                    creationRow(for: request, depth: 0)
                }

                ExplorerTreeRows(
                    root: root,
                    nodes: nodes,
                    depth: 0,
                    expandedNodeIDs: $expandedNodeIDs,
                    selectedDirectory: $selectedDirectory,
                    creationRequest: $creationRequest,
                    editingEntryID: $editingEntryID,
                    hoveredNodeID: $hoveredNodeID,
                    dropTargetNodeID: $dropTargetNodeID,
                    selectedFile: selectedFile,
                    sourceIsDirty: sourceIsDirty,
                    actions: actions,
                    onDropProviders: acceptDrop
                )
            }
        }
        .onAppear {
            if let creationRequest {
                prepareForCreation(creationRequest)
            }
        }
        .onChange(of: entries) { newEntries in
            let refreshedNodes = ExplorerTreeBuilder.make(root: root, entries: newEntries)
            let validFolderIDs = Set(Self.folderIDs(in: refreshedNodes))
            let rootPath = explorerPath(root)
            let validDirectoryPaths = Set(
                newEntries.lazy
                    .filter(\.isDirectory)
                    .map { explorerPath($0.url) }
            )
            nodes = refreshedNodes
            expandedNodeIDs.formIntersection(validFolderIDs)
            if let editingEntryID,
               !newEntries.contains(where: { explorerPath($0.url) == editingEntryID }) {
                self.editingEntryID = nil
            }
            if let selectedDirectory {
                let selectedPath = explorerPath(selectedDirectory)
                if selectedPath != rootPath, !validDirectoryPaths.contains(selectedPath) {
                    self.selectedDirectory = root
                }
            }
            if let creationRequest {
                let parentPath = explorerPath(creationRequest.parentDirectory)
                if parentPath != rootPath, !validDirectoryPaths.contains(parentPath) {
                    self.creationRequest = nil
                }
            }
        }
        .onChange(of: creationRequest) { newRequest in
            if let newRequest {
                prepareForCreation(newRequest)
            }
        }
    }

    private var rootRow: some View {
        HStack(spacing: 7) {
            Button {
                rootIsExpanded.toggle()
            } label: {
                Image(systemName: rootIsExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: ExplorerMetrics.disclosureFont, weight: .semibold))
                    .frame(width: 12, height: ExplorerMetrics.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(CodexPalette.faintText)
            .help(rootIsExpanded ? "收起文件夹" : "展开文件夹")

            HStack(spacing: 7) {
                Image(systemName: rootIsExpanded ? "folder.fill" : "folder")
                    .font(.system(size: ExplorerMetrics.rootIconFont))
                    .foregroundStyle(CodexPalette.accent)

                Text(root.lastPathComponent)
                    .font(.system(size: ExplorerMetrics.rowFont, weight: .semibold))
                    .foregroundStyle(CodexPalette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Text("\(entries.count)")
                    .font(.system(size: ExplorerMetrics.countFont, design: .monospaced))
                    .foregroundStyle(CodexPalette.faintText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(minWidth: 24, alignment: .trailing)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, minHeight: ExplorerMetrics.rowHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedDirectory = root
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background(rootBackground)
        .overlay {
            if dropTargetNodeID == rootDropID {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(CodexPalette.accent, lineWidth: 1.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { isHovering in
            updateHover(rootDropID, isHovering: isHovering)
        }
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: dropBinding(for: rootDropID)
        ) { providers in
            acceptDrop(providers, root)
        }
        .contextMenu {
            creationMenu(for: root)
            Divider()
            Button {
                actions.pasteEntry(root)
            } label: {
                Label("粘贴", systemImage: "doc.on.clipboard")
            }
            .disabled(!actions.canPaste)
            Divider()
            Button {
                actions.revealInFinder(root)
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }
            Button {
                actions.copyRelativePath(root)
            } label: {
                Label("复制相对路径", systemImage: "doc.on.doc")
            }
            Divider()
            Button {
                if rootIsExpanded {
                    rootIsExpanded = false
                } else {
                    rootIsExpanded = true
                }
            } label: {
                Label(
                    rootIsExpanded ? "收起根目录" : "展开根目录",
                    systemImage: rootIsExpanded ? "chevron.up" : "chevron.down"
                )
            }
            Button {
                rootIsExpanded = true
                expandedNodeIDs = Set(folderIDs)
            } label: {
                Label("展开所有文件夹", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            Button {
                rootIsExpanded = false
                expandedNodeIDs.removeAll()
            } label: {
                Label("全部收起", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Divider()
            Button(action: onCloseFolder) {
                Label("关闭文件夹", systemImage: "xmark")
            }
        }
    }

    private var rootBackground: Color {
        if isSelectedDirectory(root) {
            return CodexPalette.selected
        }
        if hoveredNodeID == rootDropID {
            return CodexPalette.elevated.opacity(0.58)
        }
        return Color.clear
    }

    @ViewBuilder
    private func creationMenu(for directoryURL: URL) -> some View {
        ForEach(ExplorerCreationKind.allCases) { kind in
            Button {
                beginCreation(kind, in: directoryURL)
            } label: {
                Label(kind.menuTitle, systemImage: kind.symbol)
            }
        }
    }

    private func creationRow(
        for request: ExplorerCreationRequest,
        depth: Int
    ) -> some View {
        ExplorerCreationInputRow(
            kind: request.kind,
            depth: depth,
            onCommit: { name in
                guard creationRequest?.id == request.id else { return }
                creationRequest = nil
                if request.kind != .folder {
                    selectedDirectory = nil
                }
                actions.createEntry(request.parentDirectory, request.kind, name)
            },
            onCancel: {
                guard creationRequest?.id == request.id else { return }
                creationRequest = nil
            }
        )
        .id(request.id)
    }

    private var rootCreationRequest: ExplorerCreationRequest? {
        guard let creationRequest,
              sameExplorerPath(creationRequest.parentDirectory, root)
        else {
            return nil
        }
        return creationRequest
    }

    private var folderIDs: [String] {
        Self.folderIDs(in: nodes)
    }

    private var rootDropID: String {
        "root:\(explorerPath(root))"
    }

    private func beginCreation(_ kind: ExplorerCreationKind, in directoryURL: URL) {
        editingEntryID = nil
        creationRequest = ExplorerCreationRequest(
            parentDirectory: directoryURL,
            kind: kind
        )
    }

    private func prepareForCreation(_ request: ExplorerCreationRequest) {
        let rootPath = explorerPath(root)
        let destinationPath = explorerPath(request.parentDirectory)
        guard destinationPath == rootPath || destinationPath.hasPrefix(rootPath + "/") else {
            return
        }

        editingEntryID = nil
        rootIsExpanded = true
        selectedDirectory = request.parentDirectory
        for folderID in folderIDs
        where destinationPath == folderID || destinationPath.hasPrefix(folderID + "/") {
            expandedNodeIDs.insert(folderID)
        }
    }

    private func isSelectedDirectory(_ directoryURL: URL) -> Bool {
        guard let selectedDirectory else { return false }
        return sameExplorerPath(selectedDirectory, directoryURL)
    }

    private func updateHover(_ nodeID: String, isHovering: Bool) {
        if isHovering {
            hoveredNodeID = nodeID
        } else if hoveredNodeID == nodeID {
            hoveredNodeID = nil
        }
    }

    private func dropBinding(for nodeID: String) -> Binding<Bool> {
        Binding(
            get: { dropTargetNodeID == nodeID },
            set: { isTargeted in
                if isTargeted {
                    dropTargetNodeID = nodeID
                } else if dropTargetNodeID == nodeID {
                    dropTargetNodeID = nil
                }
            }
        )
    }

    private func acceptDrop(_ providers: [NSItemProvider], _ destinationURL: URL) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else {
            return false
        }

        provider.loadItem(
            forTypeIdentifier: UTType.fileURL.identifier,
            options: nil
        ) { item, _ in
            let sourceURL: URL?
            if let data = item as? Data {
                sourceURL = URL(dataRepresentation: data, relativeTo: nil)
            } else if let url = item as? URL {
                sourceURL = url
            } else if let url = item as? NSURL {
                sourceURL = url as URL
            } else {
                sourceURL = nil
            }

            guard let sourceURL else { return }
            Task { @MainActor in
                onDropFile(sourceURL, destinationURL)
            }
        }
        return true
    }

    private static func initialExpandedIDs(in nodes: [ExplorerTreeNode]) -> Set<String> {
        Set(nodes.filter { $0.children != nil }.map(\.id))
    }

    private static func folderIDs(in nodes: [ExplorerTreeNode]) -> [String] {
        nodes.flatMap { node in
            let nested = folderIDs(in: node.children ?? [])
            return node.children == nil ? nested : [node.id] + nested
        }
    }
}

private struct ExplorerTreeRows: View {
    let root: URL
    let nodes: [ExplorerTreeNode]
    let depth: Int
    @Binding var expandedNodeIDs: Set<String>
    @Binding var selectedDirectory: URL?
    @Binding var creationRequest: ExplorerCreationRequest?
    @Binding var editingEntryID: String?
    @Binding var hoveredNodeID: String?
    @Binding var dropTargetNodeID: String?
    let selectedFile: ProjectFile?
    let sourceIsDirty: Bool
    let actions: ExplorerActions
    let onDropProviders: ([NSItemProvider], URL) -> Bool

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                folderRow(node, children: children)
                if expandedNodeIDs.contains(node.id) {
                    if let request = creationRequest(for: node) {
                        creationRow(for: request)
                    }

                    ExplorerTreeRows(
                        root: root,
                        nodes: children,
                        depth: depth + 1,
                        expandedNodeIDs: $expandedNodeIDs,
                        selectedDirectory: $selectedDirectory,
                        creationRequest: $creationRequest,
                        editingEntryID: $editingEntryID,
                        hoveredNodeID: $hoveredNodeID,
                        dropTargetNodeID: $dropTargetNodeID,
                        selectedFile: selectedFile,
                        sourceIsDirty: sourceIsDirty,
                        actions: actions,
                        onDropProviders: onDropProviders
                    )
                }
            } else if let entry = node.entry {
                fileRow(node, entry: entry)
            }
        }
    }

    private func folderRow(
        _ node: ExplorerTreeNode,
        children: [ExplorerTreeNode]
    ) -> some View {
        let directoryURL = folderURL(for: node)
        let entry = node.entry ?? WorkspaceEntry(url: directoryURL, isDirectory: true)

        return HStack(spacing: 7) {
            Button {
                toggle(node.id)
            } label: {
                Image(systemName: expandedNodeIDs.contains(node.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: ExplorerMetrics.disclosureFont, weight: .semibold))
                    .foregroundStyle(CodexPalette.faintText)
                    .frame(width: 10, height: ExplorerMetrics.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expandedNodeIDs.contains(node.id) ? "收起文件夹" : "展开文件夹")

            Image(systemName: expandedNodeIDs.contains(node.id) ? "folder.fill" : "folder")
                .font(.system(size: ExplorerMetrics.rowIconFont))
                .foregroundStyle(CodexPalette.mutedText)
                .frame(width: ExplorerMetrics.iconColumnWidth)

            if editingEntryID == node.id {
                ExplorerInlineNameEditor(
                    initialName: node.name,
                    accessibilityLabel: "重命名文件夹",
                    onCommit: { name in
                        editingEntryID = nil
                        actions.renameEntry(entry, name)
                    },
                    onCancel: {
                        editingEntryID = nil
                    }
                )
                .id("rename:\(node.id)")
            } else {
                HStack(spacing: 6) {
                    Text(node.name)
                        .font(.system(size: ExplorerMetrics.rowFont, weight: .medium))
                        .foregroundStyle(CodexPalette.primaryText)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if children.isEmpty {
                        Text("空")
                            .font(.system(size: ExplorerMetrics.minorFont))
                            .foregroundStyle(CodexPalette.faintText)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: ExplorerMetrics.rowHeight)
                .contentShape(Rectangle())
                .gesture(
                    TapGesture(count: 2)
                        .exclusively(before: TapGesture(count: 1))
                        .onEnded { result in
                            switch result {
                            case .first:
                                beginRename(entry)
                            case .second:
                                selectedDirectory = directoryURL
                            }
                        }
                )
                .help("单击选择，双击重命名，右键查看更多操作")
            }
        }
        .padding(.leading, CGFloat(depth) * 14 + 7)
        .padding(.trailing, 7)
        .frame(maxWidth: .infinity, minHeight: ExplorerMetrics.rowHeight)
        .background(rowBackground(node.id, selected: isSelectedDirectory(directoryURL)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { isHovering in
            updateHover(node.id, isHovering: isHovering)
        }
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: dropBinding(for: node.id)
        ) { providers in
            onDropProviders(providers, directoryURL)
        }
        .contextMenu {
            ForEach(ExplorerCreationKind.allCases) { kind in
                Button {
                    beginCreation(kind, in: directoryURL)
                } label: {
                    Label(kind.menuTitle, systemImage: kind.symbol)
                }
            }
            Divider()
            Button {
                beginRename(entry)
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Divider()
            Button {
                actions.copyEntry(entry)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            Button {
                actions.pasteEntry(directoryURL)
            } label: {
                Label("粘贴到此文件夹", systemImage: "doc.on.clipboard")
            }
            .disabled(!actions.canPaste)
            Divider()
            Button {
                actions.revealInFinder(directoryURL)
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }
            Button {
                actions.copyRelativePath(directoryURL)
            } label: {
                Label("复制相对路径", systemImage: "doc.on.doc")
            }
        }
    }

    private func fileRow(_ node: ExplorerTreeNode, entry: WorkspaceEntry) -> some View {
        HStack(spacing: 7) {
            Color.clear.frame(width: 10, height: 1)

            Image(systemName: entry.symbol)
                .font(.system(size: ExplorerMetrics.rowIconFont))
                .foregroundStyle(CodexPalette.mutedText)
                .frame(width: ExplorerMetrics.iconColumnWidth)

            if editingEntryID == node.id {
                ExplorerInlineNameEditor(
                    initialName: node.name,
                    accessibilityLabel: "重命名文件",
                    onCommit: { name in
                        editingEntryID = nil
                        actions.renameEntry(entry, name)
                    },
                    onCancel: {
                        editingEntryID = nil
                    }
                )
                .id("rename:\(node.id)")
            } else {
                HStack(spacing: 6) {
                    Text(node.name)
                        .font(.system(
                            size: ExplorerMetrics.rowFont,
                            weight: isCurrentFile(entry) ? .medium : .regular
                        ))
                        .foregroundStyle(CodexPalette.primaryText)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if isCurrentFile(entry), sourceIsDirty {
                        Circle()
                            .fill(CodexPalette.warning)
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: ExplorerMetrics.rowHeight)
                .contentShape(Rectangle())
                .gesture(
                    TapGesture(count: 2)
                        .exclusively(before: TapGesture(count: 1))
                        .onEnded { result in
                            switch result {
                            case .first:
                                beginRename(entry)
                            case .second:
                                selectedDirectory = nil
                                actions.openFile(entry)
                            }
                        }
                )
                .help("单击打开，双击重命名，右键查看更多操作")
            }
        }
        .padding(.leading, CGFloat(depth) * 14 + 7)
        .padding(.trailing, 7)
        .frame(maxWidth: .infinity, minHeight: ExplorerMetrics.rowHeight)
        .background(rowBackground(node.id, selected: isSelectedFile(entry)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { isHovering in
            updateHover(node.id, isHovering: isHovering)
        }
        .onDrag {
            NSItemProvider(object: entry.url as NSURL)
        }
        .contextMenu {
            Button {
                selectedDirectory = nil
                actions.openFile(entry)
            } label: {
                Label("打开", systemImage: "doc.text")
            }
            Button {
                actions.openWith(entry.url)
            } label: {
                Label("打开方式…", systemImage: "app.badge")
            }
            Button {
                actions.saveAs(entry.url)
            } label: {
                Label("另存为…", systemImage: "square.and.arrow.down")
            }
            Button {
                beginRename(entry)
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button {
                actions.moveFile(entry)
            } label: {
                Label("移动到…", systemImage: "folder")
            }
            Divider()
            Button {
                actions.copyEntry(entry)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            Divider()
            Button {
                actions.revealInFinder(entry.url)
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }
            Button {
                actions.copyRelativePath(entry.url)
            } label: {
                Label("复制相对路径", systemImage: "doc.on.doc")
            }
        }
    }

    private func creationRow(for request: ExplorerCreationRequest) -> some View {
        ExplorerCreationInputRow(
            kind: request.kind,
            depth: depth + 1,
            onCommit: { name in
                guard creationRequest?.id == request.id else { return }
                creationRequest = nil
                if request.kind != .folder {
                    selectedDirectory = nil
                }
                actions.createEntry(request.parentDirectory, request.kind, name)
            },
            onCancel: {
                guard creationRequest?.id == request.id else { return }
                creationRequest = nil
            }
        )
        .id(request.id)
    }

    private func creationRequest(for node: ExplorerTreeNode) -> ExplorerCreationRequest? {
        guard let creationRequest,
              sameExplorerPath(creationRequest.parentDirectory, folderURL(for: node))
        else {
            return nil
        }
        return creationRequest
    }

    private func beginCreation(_ kind: ExplorerCreationKind, in directoryURL: URL) {
        editingEntryID = nil
        selectedDirectory = directoryURL
        expandedNodeIDs.insert(explorerPath(directoryURL))
        creationRequest = ExplorerCreationRequest(
            parentDirectory: directoryURL,
            kind: kind
        )
    }

    private func beginRename(_ entry: WorkspaceEntry) {
        creationRequest = nil
        selectedDirectory = entry.isDirectory ? entry.url : nil
        editingEntryID = explorerPath(entry.url)
    }

    private func toggle(_ nodeID: String) {
        if expandedNodeIDs.contains(nodeID) {
            expandedNodeIDs.remove(nodeID)
        } else {
            expandedNodeIDs.insert(nodeID)
        }
    }

    private func folderURL(for node: ExplorerTreeNode) -> URL {
        node.entry?.url ?? URL(fileURLWithPath: node.id, isDirectory: true)
    }

    private func rowBackground(_ nodeID: String, selected: Bool) -> Color {
        if dropTargetNodeID == nodeID {
            return CodexPalette.selected
        }
        if selected {
            return CodexPalette.selected
        }
        if hoveredNodeID == nodeID {
            return CodexPalette.elevated.opacity(0.58)
        }
        return Color.clear
    }

    private func isSelectedDirectory(_ directoryURL: URL) -> Bool {
        guard let selectedDirectory else { return false }
        return sameExplorerPath(selectedDirectory, directoryURL)
    }

    private func isCurrentFile(_ entry: WorkspaceEntry) -> Bool {
        selectedFile.map { sameExplorerPath($0.url, entry.url) } ?? false
    }

    private func isSelectedFile(_ entry: WorkspaceEntry) -> Bool {
        selectedDirectory == nil && isCurrentFile(entry)
    }

    private func updateHover(_ nodeID: String, isHovering: Bool) {
        if isHovering {
            hoveredNodeID = nodeID
        } else if hoveredNodeID == nodeID {
            hoveredNodeID = nil
        }
    }

    private func dropBinding(for nodeID: String) -> Binding<Bool> {
        Binding(
            get: { dropTargetNodeID == nodeID },
            set: { isTargeted in
                if isTargeted {
                    dropTargetNodeID = nodeID
                } else if dropTargetNodeID == nodeID {
                    dropTargetNodeID = nil
                }
            }
        )
    }
}

private func explorerPath(_ url: URL) -> String {
    url.standardizedFileURL.path
}

private func sameExplorerPath(_ left: URL, _ right: URL) -> Bool {
    explorerPath(left) == explorerPath(right)
}
