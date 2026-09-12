import Darwin
import Foundation

/// 资源管理器中由用户输入的单个文件或文件夹名称。
///
/// 这里有意只接受单个可见路径分量，避免通过名称输入跨目录、创建隐藏项，
/// 或把控制字符带进编辑器标签和构建命令。
enum WorkspaceEntryNameValidator {
    static let maximumUTF8Bytes = 120

    static func normalized(_ rawName: String) -> String? {
        let name = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping

        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.hasPrefix("."),
              name.utf8.count <= maximumUTF8Bytes,
              !name.contains("/"),
              !name.contains(":"),
              name.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            return nil
        }
        return name
    }
}

struct WorkspaceFileRevision: Equatable, Sendable {
    let modificationDate: Date?
    let fileSize: Int64
    let resourceIdentifier: String?
}

enum WorkspaceFileRevisionReader {
    static func read(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> WorkspaceFileRevision? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let systemNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let identifier = systemNumber.flatMap { system in
            fileNumber.map { file in "\(system):\(file)" }
        }
        return WorkspaceFileRevision(
            modificationDate: attributes[.modificationDate] as? Date,
            fileSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            resourceIdentifier: identifier
        )
    }
}

enum WorkspaceSourceFileKind: String, CaseIterable, Sendable {
    case c
    case header = "h"

    var fileExtension: String { rawValue }

    var defaultName: String {
        switch self {
        case .c:
            return "untitled.c"
        case .header:
            return "untitled.h"
        }
    }
}

enum WorkspaceFileOperationError: LocalizedError, Equatable {
    case invalidName
    case invalidSourceExtension(expected: String)
    case projectRootIsNotDirectory
    case parentOutsideProject
    case parentIsNotDirectory
    case sourceOutsideProject
    case cannotRenameProjectRoot
    case sourceDoesNotExist
    case unsupportedSourceType
    case symbolicLinkNotAllowed
    case destinationAlreadyExists
    case createFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "名称无效。请输入普通文件名或文件夹名，不能包含 /、:、控制字符或以 . 开头。"
        case let .invalidSourceExtension(expected):
            return "文件扩展名必须是 .\(expected)。"
        case .projectRootIsNotDirectory:
            return "当前工程根目录不存在或不是文件夹。"
        case .parentOutsideProject:
            return "只能在当前工程目录及其子文件夹中创建项目。"
        case .parentIsNotDirectory:
            return "所选创建位置不存在或不是文件夹。"
        case .sourceOutsideProject:
            return "只能重命名当前工程目录内的文件或文件夹。"
        case .cannotRenameProjectRoot:
            return "不能在资源管理器中重命名工程根目录。"
        case .sourceDoesNotExist:
            return "要重命名的文件或文件夹不存在。"
        case .unsupportedSourceType:
            return "只能重命名普通文件或文件夹。"
        case .symbolicLinkNotAllowed:
            return "为防止路径越界，不能通过资源管理器修改符号链接。"
        case .destinationAlreadyExists:
            return "同一文件夹中已存在同名项目，为防止覆盖已取消操作。"
        case let .createFailed(code):
            return "无法创建文件（系统错误 \(code)）。"
        }
    }
}

enum WorkspaceSourceFileCreator {
    /// 在工程内创建一个真正的空 `.c` 或 `.h` 文件。
    ///
    /// 使用 `O_EXCL` 保证即使检查和写入之间发生竞争，也绝不会截断或覆盖已有文件。
    static func createEmptyFile(
        named rawName: String,
        kind: WorkspaceSourceFileKind,
        in parentDirectoryURL: URL,
        projectRoot: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let rootURL = WorkspacePathSafety.canonical(projectRoot)
        guard directoryExists(rootURL, fileManager: fileManager) else {
            throw WorkspaceFileOperationError.projectRootIsNotDirectory
        }

        let parentURL = WorkspacePathSafety.canonical(parentDirectoryURL)
        guard WorkspacePathSafety.isWithinProject(
            parentURL,
            projectRoot: rootURL
        ) else {
            throw WorkspaceFileOperationError.parentOutsideProject
        }
        guard directoryExists(parentURL, fileManager: fileManager) else {
            throw WorkspaceFileOperationError.parentIsNotDirectory
        }

        guard var name = WorkspaceEntryNameValidator.normalized(rawName) else {
            throw WorkspaceFileOperationError.invalidName
        }
        if URL(fileURLWithPath: name).pathExtension.isEmpty {
            name += ".\(kind.fileExtension)"
        }
        guard let normalizedName = WorkspaceEntryNameValidator.normalized(name) else {
            throw WorkspaceFileOperationError.invalidName
        }
        guard URL(fileURLWithPath: normalizedName).pathExtension.lowercased()
                == kind.fileExtension
        else {
            throw WorkspaceFileOperationError.invalidSourceExtension(
                expected: kind.fileExtension
            )
        }

        let fileURL = parentURL.appendingPathComponent(
            normalizedName,
            isDirectory: false
        )
        guard WorkspacePathSafety.isWithinProject(
            fileURL,
            projectRoot: rootURL,
            allowRoot: false
        ) else {
            throw WorkspaceFileOperationError.parentOutsideProject
        }
        guard !fileManager.fileExists(atPath: fileURL.path) else {
            throw WorkspaceFileOperationError.destinationAlreadyExists
        }

        let permissions = mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        let descriptor = fileURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, permissions)
        }
        guard descriptor >= 0 else {
            let errorCode = errno
            if errorCode == EEXIST {
                throw WorkspaceFileOperationError.destinationAlreadyExists
            }
            throw WorkspaceFileOperationError.createFailed(code: errorCode)
        }
        Darwin.close(descriptor)
        return fileURL
    }
}

enum WorkspaceEntryRenamer {
    private static let maximumTemporaryNameAttempts = 16

    /// 重命名工程内的普通文件或文件夹，不允许修改工程根目录或覆盖现有项目。
    static func rename(
        at sourceURL: URL,
        to rawName: String,
        projectRoot: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let rootURL = WorkspacePathSafety.canonical(projectRoot)
        guard directoryExists(rootURL, fileManager: fileManager) else {
            throw WorkspaceFileOperationError.projectRootIsNotDirectory
        }

        let originalSourceURL = sourceURL.standardizedFileURL
        if isSymbolicLink(originalSourceURL) {
            throw WorkspaceFileOperationError.symbolicLinkNotAllowed
        }
        let sourceURL = WorkspacePathSafety.canonical(originalSourceURL)
        guard sourceURL.path != rootURL.path else {
            throw WorkspaceFileOperationError.cannotRenameProjectRoot
        }
        guard WorkspacePathSafety.isWithinProject(
            sourceURL,
            projectRoot: rootURL,
            allowRoot: false
        ) else {
            throw WorkspaceFileOperationError.sourceOutsideProject
        }

        var sourceIsDirectory = ObjCBool(false)
        guard fileManager.fileExists(
            atPath: sourceURL.path,
            isDirectory: &sourceIsDirectory
        ) else {
            throw WorkspaceFileOperationError.sourceDoesNotExist
        }
        if !sourceIsDirectory.boolValue, !isRegularFile(sourceURL) {
            throw WorkspaceFileOperationError.unsupportedSourceType
        }

        guard let name = WorkspaceEntryNameValidator.normalized(rawName) else {
            throw WorkspaceFileOperationError.invalidName
        }
        if name == sourceURL.lastPathComponent {
            return sourceURL
        }

        let parentURL = WorkspacePathSafety.canonical(
            sourceURL.deletingLastPathComponent()
        )
        guard WorkspacePathSafety.isWithinProject(
            parentURL,
            projectRoot: rootURL
        ) else {
            throw WorkspaceFileOperationError.sourceOutsideProject
        }

        let destinationURL = parentURL.appendingPathComponent(
            name,
            isDirectory: sourceIsDirectory.boolValue
        )
        guard WorkspacePathSafety.isWithinProject(
            destinationURL,
            projectRoot: rootURL,
            allowRoot: false
        ) else {
            throw WorkspaceFileOperationError.sourceOutsideProject
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            guard isCaseOnlyRename(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                fileManager: fileManager
            ) else {
                throw WorkspaceFileOperationError.destinationAlreadyExists
            }
            return try performCaseOnlyRename(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                isDirectory: sourceIsDirectory.boolValue,
                fileManager: fileManager
            )
        }

        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private static func isCaseOnlyRename(
        sourceURL: URL,
        destinationURL: URL,
        fileManager: FileManager
    ) -> Bool {
        guard sourceURL.lastPathComponent != destinationURL.lastPathComponent,
              sourceURL.lastPathComponent.compare(
                  destinationURL.lastPathComponent,
                  options: [.caseInsensitive],
                  locale: Locale(identifier: "en_US_POSIX")
              ) == .orderedSame,
              let sourceIdentifier = WorkspaceFileRevisionReader.read(
                  sourceURL,
                  fileManager: fileManager
              )?.resourceIdentifier,
              let destinationIdentifier = WorkspaceFileRevisionReader.read(
                  destinationURL,
                  fileManager: fileManager
              )?.resourceIdentifier
        else {
            return false
        }
        return sourceIdentifier == destinationIdentifier
    }

    /// 大小写不敏感卷会把新旧名称视为同一路径；借助同目录临时名完成两阶段改名。
    /// 第二阶段失败时尽力恢复原名，且所有 moveItem 调用都保持不覆盖语义。
    private static func performCaseOnlyRename(
        sourceURL: URL,
        destinationURL: URL,
        isDirectory: Bool,
        fileManager: FileManager
    ) throws -> URL {
        let parentURL = sourceURL.deletingLastPathComponent()
        let temporaryURL = try makeUniqueTemporaryURL(
            in: parentURL,
            isDirectory: isDirectory,
            fileManager: fileManager
        )

        try fileManager.moveItem(at: sourceURL, to: temporaryURL)
        do {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            return destinationURL
        } catch {
            do {
                try fileManager.moveItem(at: temporaryURL, to: sourceURL)
            } catch let rollbackError {
                throw CocoaError(
                    .fileWriteUnknown,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "大小写重命名失败，且无法恢复原名称。文件保留在临时路径 \(temporaryURL.path)。",
                        NSUnderlyingErrorKey: rollbackError
                    ]
                )
            }
            throw error
        }
    }

    private static func makeUniqueTemporaryURL(
        in parentURL: URL,
        isDirectory: Bool,
        fileManager: FileManager
    ) throws -> URL {
        for _ in 0..<maximumTemporaryNameAttempts {
            let candidate = parentURL.appendingPathComponent(
                ".stm32flasher-rename-\(UUID().uuidString)",
                isDirectory: isDirectory
            )
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw CocoaError(
            .fileWriteFileExists,
            userInfo: [
                NSLocalizedDescriptionKey: "无法为大小写重命名创建安全的临时路径。"
            ]
        )
    }
}

struct WorkspaceDisplayLabel: Equatable, Sendable {
    let name: String
    let qualifier: String?

    var combined: String {
        guard let qualifier else { return name }
        return "\(name) — \(qualifier)/"
    }
}

enum WorkspacePathPresentation {
    /// 返回工程根目录下的相对路径；工程外路径返回 `nil`。
    static func relativePath(for url: URL, projectRoot: URL) -> String? {
        let rootURL = WorkspacePathSafety.canonical(projectRoot)
        let candidateURL = WorkspacePathSafety.canonical(url)
        guard WorkspacePathSafety.isWithinProject(
            candidateURL,
            projectRoot: rootURL
        ) else {
            return nil
        }
        if candidateURL.path == rootURL.path {
            return "."
        }
        return String(candidateURL.path.dropFirst(rootURL.path.count + 1))
    }

    /// 为同名文件生成最短、唯一的父路径后缀；不同名文件保持简洁。
    ///
    /// 字典键是规范化绝对路径，可直接用 `WorkspacePathSafety.canonical(url).path` 查询。
    static func displayLabels(
        for urls: [URL],
        projectRoot: URL?
    ) -> [String: WorkspaceDisplayLabel] {
        let uniqueURLs = Dictionary(
            urls.map { (WorkspacePathSafety.canonical($0).path, WorkspacePathSafety.canonical($0)) },
            uniquingKeysWith: { first, _ in first }
        )
        let grouped = Dictionary(grouping: uniqueURLs.values) {
            $0.lastPathComponent.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
        }

        var labels: [String: WorkspaceDisplayLabel] = [:]
        labels.reserveCapacity(uniqueURLs.count)

        for group in grouped.values {
            if group.count == 1, let url = group.first {
                labels[url.path] = WorkspaceDisplayLabel(
                    name: url.lastPathComponent,
                    qualifier: nil
                )
                continue
            }

            let componentsByPath = Dictionary(
                uniqueKeysWithValues: group.map { url in
                    (url.path, parentComponents(for: url, projectRoot: projectRoot))
                }
            )
            for url in group {
                let components = componentsByPath[url.path] ?? ["."]
                let qualifier = shortestUniqueSuffix(
                    components: components,
                    allComponents: componentsByPath
                )
                labels[url.path] = WorkspaceDisplayLabel(
                    name: url.lastPathComponent,
                    qualifier: qualifier
                )
            }
        }
        return labels
    }

    private static func parentComponents(
        for url: URL,
        projectRoot: URL?
    ) -> [String] {
        if let projectRoot,
           let relativePath = relativePath(for: url, projectRoot: projectRoot) {
            let components = relativePath.split(separator: "/").map(String.init)
            let parentComponents = Array(components.dropLast())
            if parentComponents.isEmpty {
                return ["."]
            }
            return parentComponents
        }

        let components = url.deletingLastPathComponent().pathComponents
            .filter { $0 != "/" }
        return components.isEmpty ? ["."] : components
    }

    private static func shortestUniqueSuffix(
        components: [String],
        allComponents: [String: [String]]
    ) -> String {
        for count in 1...components.count {
            let suffix = components.suffix(count).joined(separator: "/")
            let matchingCount = allComponents.values.reduce(into: 0) { total, candidate in
                if candidate.suffix(count).joined(separator: "/") == suffix {
                    total += 1
                }
            }
            if matchingCount == 1 {
                return suffix
            }
        }

        // 正常的工程树中不会出现两个相同绝对路径；保留完整父路径作为稳定兜底。
        return components.joined(separator: "/")
    }
}

enum WorkspaceURLRemapper {
    /// 将文件夹或文件重命名前的 URL 映射到新路径；无关 URL 返回 `nil`。
    static func remap(
        _ candidateURL: URL,
        replacing sourceURL: URL,
        with destinationURL: URL
    ) -> URL? {
        let candidatePath = WorkspacePathSafety.canonical(candidateURL).path
        let sourcePath = WorkspacePathSafety.canonical(sourceURL).path
        let destination = WorkspacePathSafety.canonical(destinationURL)
        if candidatePath == sourcePath {
            return destination
        }
        guard candidatePath.hasPrefix(sourcePath + "/") else {
            return nil
        }
        let suffix = String(candidatePath.dropFirst(sourcePath.count + 1))
        return destination.appendingPathComponent(suffix)
    }
}

private func directoryExists(
    _ url: URL,
    fileManager: FileManager
) -> Bool {
    var isDirectory = ObjCBool(false)
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && isDirectory.boolValue
}

private func isRegularFile(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
}

private func isSymbolicLink(_ url: URL) -> Bool {
    var fileInfo = stat()
    let status = url.path.withCString { Darwin.lstat($0, &fileInfo) }
    return status == 0 && (fileInfo.st_mode & S_IFMT) == S_IFLNK
}
