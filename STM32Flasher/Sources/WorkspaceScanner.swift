import Darwin
import Foundation

struct WorkspaceEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let isDirectory: Bool

    var id: String {
        url.standardizedFileURL.path
    }

    var name: String {
        url.lastPathComponent
    }

    var fileExtension: String {
        url.pathExtension.lowercased()
    }

    var isEditableSource: Bool {
        !isDirectory && ["c", "h"].contains(fileExtension)
    }

    var isCompileSource: Bool {
        !isDirectory && fileExtension == "c"
    }

    var symbol: String {
        if isDirectory { return "folder" }
        switch fileExtension {
        case "c": return "c.square.fill"
        case "h": return "h.square.fill"
        case "s": return "s.square.fill"
        case "ld": return "link"
        case "json": return "curlybraces"
        case "md": return "text.document"
        case "txt": return "doc.plaintext"
        default: return "doc"
        }
    }
}

struct WorkspaceScanResult: Sendable {
    let entries: [WorkspaceEntry]
    let inspectedCount: Int
    let isTruncated: Bool
    let isCancelled: Bool
    let failureCount: Int
    let issues: [WorkspaceScanIssue]
}

struct WorkspaceScanIssue: Equatable, Sendable {
    let path: String
    let message: String
}

/// 扫描错误只保留少量诊断样本，同时单独累计完整失败次数，避免错误风暴占满内存。
struct WorkspaceScanIssueCollector {
    static let defaultMaximumRetainedIssues = 8
    static let hardMaximumRetainedIssues = 32
    static let maximumPathCharacters = 512
    static let maximumMessageCharacters = 256

    let maximumRetainedIssues: Int
    private(set) var failureCount = 0
    private(set) var issues: [WorkspaceScanIssue] = []

    init(maximumRetainedIssues: Int = defaultMaximumRetainedIssues) {
        self.maximumRetainedIssues = min(
            max(0, maximumRetainedIssues),
            Self.hardMaximumRetainedIssues
        )
    }

    mutating func record(path: String, message: String) {
        if failureCount < Int.max {
            failureCount += 1
        }
        guard issues.count < maximumRetainedIssues else { return }
        issues.append(
            WorkspaceScanIssue(
                path: String(path.prefix(Self.maximumPathCharacters)),
                message: String(message.prefix(Self.maximumMessageCharacters))
            )
        )
    }

    mutating func record(url: URL, error: Error) {
        record(path: url.path, message: error.localizedDescription)
    }
}

enum WorkspaceScanner {
    static func scan(directory: URL, maximumEntries: Int) -> WorkspaceScanResult {
        guard maximumEntries > 0 else {
            return WorkspaceScanResult(
                entries: [],
                inspectedCount: 0,
                isTruncated: true,
                isCancelled: false,
                failureCount: 0,
                issues: []
            )
        }

        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isHiddenKey
        ]
        var entries: [WorkspaceEntry] = []
        var inspectedCount = 0
        var isTruncated = false
        var issueCollector = WorkspaceScanIssueCollector()

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                issueCollector.record(url: url, error: error)
                return true
            }
        ) else {
            issueCollector.record(
                path: directory.path,
                message: "无法创建目录枚举器。"
            )
            return WorkspaceScanResult(
                entries: [],
                inspectedCount: 0,
                isTruncated: false,
                isCancelled: false,
                failureCount: issueCollector.failureCount,
                issues: issueCollector.issues
            )
        }

        for case let entryURL as URL in enumerator {
            if Task.isCancelled {
                return WorkspaceScanResult(
                    entries: [],
                    inspectedCount: inspectedCount,
                    isTruncated: false,
                    isCancelled: true,
                    failureCount: issueCollector.failureCount,
                    issues: issueCollector.issues
                )
            }

            guard inspectedCount < maximumEntries else {
                isTruncated = true
                break
            }
            inspectedCount += 1

            do {
                let values = try entryURL.resourceValues(forKeys: keys)
                if values.isDirectory == true {
                    entries.append(WorkspaceEntry(url: entryURL, isDirectory: true))
                } else if values.isRegularFile == true {
                    entries.append(WorkspaceEntry(url: entryURL, isDirectory: false))
                }
            } catch {
                issueCollector.record(url: entryURL, error: error)
            }
        }

        entries.sort { left, right in
            left.url.path.localizedStandardCompare(right.url.path) == .orderedAscending
        }

        return WorkspaceScanResult(
            entries: entries,
            inspectedCount: inspectedCount,
            isTruncated: isTruncated,
            isCancelled: false,
            failureCount: issueCollector.failureCount,
            issues: issueCollector.issues
        )
    }
}

enum BuildScope: Equatable, Sendable {
    case singleFile
    case project
}

enum BuildScopeResolver {
    static func resolve(
        projectRoot: URL?,
        selectedFile: URL?,
        projectFiles: [URL]
    ) -> BuildScope {
        guard let projectRoot, let selectedFile else { return .singleFile }
        let rootPath = projectRoot.standardizedFileURL.path + "/"
        let selectedPath = selectedFile.standardizedFileURL.path
        guard selectedPath.hasPrefix(rootPath) else { return .singleFile }
        return projectFiles.contains {
            $0.standardizedFileURL.path == selectedPath
        } ? .project : .singleFile
    }
}

enum WorkspaceFolderNameValidator {
    static func normalized(_ rawName: String) -> String? {
        WorkspaceEntryNameValidator.normalized(rawName)
    }
}

/// 所有资源管理器写操作均通过此策略校验，避免符号链接或路径跳转离开工程目录。
enum WorkspacePathSafety {
    static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    static func isWithinProject(_ candidate: URL, projectRoot: URL, allowRoot: Bool = true) -> Bool {
        let candidatePath = canonical(candidate).path
        let rootPath = canonical(projectRoot).path
        if allowRoot && candidatePath == rootPath {
            return true
        }
        return candidatePath.hasPrefix(rootPath + "/")
    }
}

enum WorkspaceFileMoveError: LocalizedError {
    case outsideProject
    case symbolicLinkNotAllowed
    case sourceIsNotFile
    case destinationIsNotDirectory
    case destinationAlreadyExists

    var errorDescription: String? {
        switch self {
        case .outsideProject:
            return "只能在当前工程目录及其子文件夹内移动文件。"
        case .symbolicLinkNotAllowed:
            return "为防止路径越界或误移动链接目标，不能移动符号链接。"
        case .sourceIsNotFile:
            return "拖动项目不是可移动的普通文件。"
        case .destinationIsNotDirectory:
            return "拖放目标不是有效文件夹。"
        case .destinationAlreadyExists:
            return "目标文件夹中已存在同名文件，为防止覆盖已取消移动。"
        }
    }
}

enum WorkspaceFileMover {
    static func moveFile(
        at sourceURL: URL,
        to destinationDirectoryURL: URL,
        projectRoot: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let originalSourceURL = sourceURL.standardizedFileURL
        var sourceInfo = stat()
        let sourceStatus = originalSourceURL.path.withCString {
            Darwin.lstat($0, &sourceInfo)
        }
        guard sourceStatus == 0 else {
            throw WorkspaceFileMoveError.sourceIsNotFile
        }
        if (sourceInfo.st_mode & S_IFMT) == S_IFLNK {
            throw WorkspaceFileMoveError.symbolicLinkNotAllowed
        }

        let rootURL = WorkspacePathSafety.canonical(projectRoot)
        let sourceURL = WorkspacePathSafety.canonical(originalSourceURL)
        let destinationURL = WorkspacePathSafety.canonical(destinationDirectoryURL)

        guard WorkspacePathSafety.isWithinProject(
            sourceURL,
            projectRoot: rootURL,
            allowRoot: false
        ), WorkspacePathSafety.isWithinProject(destinationURL, projectRoot: rootURL) else {
            throw WorkspaceFileMoveError.outsideProject
        }

        var sourceIsDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDirectory),
              !sourceIsDirectory.boolValue
        else {
            throw WorkspaceFileMoveError.sourceIsNotFile
        }

        var destinationIsDirectory = ObjCBool(false)
        guard fileManager.fileExists(
            atPath: destinationURL.path,
            isDirectory: &destinationIsDirectory
        ), destinationIsDirectory.boolValue else {
            throw WorkspaceFileMoveError.destinationIsNotDirectory
        }

        let movedURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
        if movedURL.standardizedFileURL.path == sourceURL.standardizedFileURL.path {
            return sourceURL
        }
        guard !fileManager.fileExists(atPath: movedURL.path) else {
            throw WorkspaceFileMoveError.destinationAlreadyExists
        }

        try fileManager.moveItem(at: sourceURL, to: movedURL)
        return movedURL
    }
}

struct ExplorerTreeNode: Identifiable, Sendable {
    let id: String
    let name: String
    let entry: WorkspaceEntry?
    let children: [ExplorerTreeNode]?
}

private final class MutableExplorerNode {
    let name: String
    let path: String
    var entry: WorkspaceEntry?
    var children: [String: MutableExplorerNode] = [:]

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

enum ExplorerTreeBuilder {
    static func make(root: URL, entries: [WorkspaceEntry]) -> [ExplorerTreeNode] {
        let rootPath = root.standardizedFileURL.path
        let mutableRoot = MutableExplorerNode(name: root.lastPathComponent, path: rootPath)

        for entry in entries {
            let entryPath = entry.url.standardizedFileURL.path
            guard entryPath.hasPrefix(rootPath + "/") else { continue }

            let relativePath = String(entryPath.dropFirst(rootPath.count + 1))
            let components = relativePath.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }

            var current = mutableRoot
            for (index, component) in components.enumerated() {
                let childPath = current.path + "/" + component
                let child: MutableExplorerNode
                if let existing = current.children[component] {
                    child = existing
                } else {
                    child = MutableExplorerNode(name: component, path: childPath)
                    current.children[component] = child
                }

                if index == components.count - 1 {
                    child.entry = entry
                }
                current = child
            }
        }

        return materialize(mutableRoot)
    }

    private static func materialize(_ node: MutableExplorerNode) -> [ExplorerTreeNode] {
        node.children.values
            .sorted { left, right in
                let leftIsFolder = left.entry?.isDirectory ?? !left.children.isEmpty
                let rightIsFolder = right.entry?.isDirectory ?? !right.children.isEmpty
                if leftIsFolder != rightIsFolder {
                    return leftIsFolder
                }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
            .map { child in
                let isFolder = child.entry?.isDirectory ?? !child.children.isEmpty
                return ExplorerTreeNode(
                    id: child.path,
                    name: child.name,
                    entry: child.entry,
                    children: isFolder ? materialize(child) : nil
                )
            }
    }
}
