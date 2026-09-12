import SwiftUI

struct MoveDestinationSheet: View {
    let entry: WorkspaceEntry
    let projectRoot: URL
    let directories: [URL]
    let onMove: (URL) -> Void

    private let destinationRows: [Destination]
    private let currentDirectory: URL

    @Environment(\.dismiss) private var dismiss
    @State private var selectedDirectory: URL

    private static let maximumDisplayedDirectories = 2_000

    init(
        entry: WorkspaceEntry,
        projectRoot: URL,
        directories: [URL],
        onMove: @escaping (URL) -> Void
    ) {
        self.entry = entry
        self.projectRoot = projectRoot
        self.directories = directories
        self.onMove = onMove

        let rootURL = WorkspacePathSafety.canonical(projectRoot)
        let currentURL = WorkspacePathSafety.canonical(
            entry.url.deletingLastPathComponent()
        )
        let rows = Self.makeDestinations(
            projectRoot: rootURL,
            directories: directories,
            currentDirectory: currentURL
        )
        self.destinationRows = rows
        self.currentDirectory = currentURL
        let initialURL = rows.contains { $0.url.path == currentURL.path }
            ? currentURL
            : rootURL
        _selectedDirectory = State(initialValue: initialURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader

            Rectangle()
                .fill(CodexPalette.border)
                .frame(height: 1)

            destinationList
                .padding(18)

            Rectangle()
                .fill(CodexPalette.border)
                .frame(height: 1)

            sheetFooter
        }
        .frame(width: 480, height: 520)
        .background(CodexPalette.canvas)
        .preferredColorScheme(.light)
    }

    private var sheetHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("移动“\(entry.name)”")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(CodexPalette.primaryText)
                .lineLimit(1)

            Text("选择当前工程中的目标文件夹")
                .font(.system(size: 11))
                .foregroundStyle(CodexPalette.mutedText)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodexPalette.panel)
    }

    private var destinationList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("工程文件夹")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CodexPalette.secondaryText)
                Spacer()
                Text("\(destinationRows.count) 个位置")
                    .font(.system(size: 10))
                    .foregroundStyle(CodexPalette.faintText)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(destinationRows) { destination in
                        destinationRow(destination)
                    }
                }
                .padding(5)
            }
            .background(CodexPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(CodexPalette.border)
            }

            if !hasAlternativeDestination {
                Text("当前工程中没有其他可移动位置")
                    .font(.system(size: 10.5))
                    .foregroundStyle(CodexPalette.mutedText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func destinationRow(_ destination: Destination) -> some View {
        let isSelected = samePath(selectedDirectory, destination.url)
        let isCurrent = samePath(currentDirectory, destination.url)

        return Button {
            selectedDirectory = destination.url
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "folder.fill" : "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? CodexPalette.accent : CodexPalette.mutedText)
                    .frame(width: 16)

                Text(destination.title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(CodexPalette.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if isCurrent {
                    Text("当前位置")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(CodexPalette.mutedText)
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CodexPalette.accent)
                }
            }
            .padding(.leading, CGFloat(destination.depth) * 16 + 9)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(isSelected ? CodexPalette.selected : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(destination.relativePath)
        .accessibilityLabel(destination.accessibilityLabel)
        .accessibilityValue(isCurrent ? "当前位置" : "")
    }

    private var sheetFooter: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("移动到")
                    .font(.system(size: 9.5))
                    .foregroundStyle(CodexPalette.faintText)
                Text(selectedDestinationTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CodexPalette.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Button("取消") {
                dismiss()
            }
            .buttonStyle(QuietButtonStyle())
            .keyboardShortcut(.cancelAction)

            Button("移动") {
                moveToSelectedDirectory()
            }
            .buttonStyle(CompactPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!canMove)
        }
        .padding(.horizontal, 20)
        .frame(height: 68)
        .background(CodexPalette.panel)
    }

    private static func makeDestinations(
        projectRoot rootURL: URL,
        directories: [URL],
        currentDirectory: URL
    ) -> [Destination] {
        var seenPaths: Set<String> = [rootURL.path]
        var validURLs: [URL] = [rootURL]

        if WorkspacePathSafety.isWithinProject(
            currentDirectory,
            projectRoot: rootURL,
            allowRoot: false
        ), isExistingDirectory(currentDirectory) {
            seenPaths.insert(currentDirectory.path)
            validURLs.append(currentDirectory)
        }

        for candidate in directories.prefix(maximumDisplayedDirectories) {
            let directoryURL = WorkspacePathSafety.canonical(candidate)
            guard WorkspacePathSafety.isWithinProject(
                directoryURL,
                projectRoot: rootURL
            ), seenPaths.insert(directoryURL.path).inserted,
               isExistingDirectory(directoryURL)
            else {
                continue
            }
            validURLs.append(directoryURL)
        }

        let sortedURLs = validURLs.dropFirst().sorted {
            relativePath(for: $0, root: rootURL)
                .localizedStandardCompare(relativePath(for: $1, root: rootURL))
                == .orderedAscending
        }

        return [makeDestination(for: rootURL, root: rootURL)]
            + sortedURLs.map { makeDestination(for: $0, root: rootURL) }
    }

    private var canMove: Bool {
        let rootURL = WorkspacePathSafety.canonical(projectRoot)
        return WorkspacePathSafety.isWithinProject(
            entry.url,
            projectRoot: rootURL,
            allowRoot: false
        )
            && WorkspacePathSafety.isWithinProject(
                selectedDirectory,
                projectRoot: rootURL
            )
            && destinationRows.contains { samePath($0.url, selectedDirectory) }
            && Self.isExistingDirectory(selectedDirectory)
            && !samePath(selectedDirectory, currentDirectory)
    }

    private var hasAlternativeDestination: Bool {
        destinationRows.contains { !samePath($0.url, currentDirectory) }
    }

    private var selectedDestinationTitle: String {
        destinationRows.first(where: { samePath($0.url, selectedDirectory) })?.relativePath
            ?? "未选择"
    }

    private func moveToSelectedDirectory() {
        guard canMove else { return }
        let destinationURL = WorkspacePathSafety.canonical(selectedDirectory)
        onMove(destinationURL)
        dismiss()
    }

    private static func makeDestination(for url: URL, root: URL) -> Destination {
        let relative = relativePath(for: url, root: root)
        let isRoot = url.path == root.path
        return Destination(
            url: url,
            title: isRoot ? "\(root.lastPathComponent)（工程根目录）" : url.lastPathComponent,
            relativePath: relative,
            depth: isRoot ? 0 : relative.split(separator: "/").count,
            accessibilityLabel: isRoot ? "工程根目录 \(root.lastPathComponent)" : relative
        )
    }

    private static func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.path
        let candidatePath = WorkspacePathSafety.canonical(url).path
        guard candidatePath != rootPath else { return "工程根目录" }
        guard candidatePath.hasPrefix(rootPath + "/") else { return "" }
        return String(candidatePath.dropFirst(rootPath.count + 1))
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func samePath(_ left: URL, _ right: URL) -> Bool {
        WorkspacePathSafety.canonical(left).path == WorkspacePathSafety.canonical(right).path
    }
}

private struct Destination: Identifiable {
    let url: URL
    let title: String
    let relativePath: String
    let depth: Int
    let accessibilityLabel: String

    var id: String { url.path }
}
