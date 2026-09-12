import Foundation

@main
struct FolderLogicTests {
    static func main() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("stm32-folder-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(
            at: root.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: root.appendingPathComponent("include", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: root.appendingPathComponent("empty", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: root.appendingPathComponent("firmware/drivers/sensors/light", isDirectory: true),
            withIntermediateDirectories: true
        )

        try write("int main(void) { return 0; }\n", to: root.appendingPathComponent("main.c"))
        try write("int sensor_read(void) { return 0; }\n", to: root.appendingPathComponent("src/sensor.c"))
        try write("#pragma once\n", to: root.appendingPathComponent("include/sensor.h"))
        try write("{}\n", to: root.appendingPathComponent("board.json"))
        try write("#pragma once\n", to: root.appendingPathComponent("firmware/drivers/sensors/light/adc.h"))
        try write("hidden\n", to: root.appendingPathComponent(".hidden.c"))

        let scan = WorkspaceScanner.scan(directory: root, maximumEntries: 32)
        require(!scan.isCancelled, "普通扫描不应被取消")
        require(!scan.isTruncated, "小型工程不应被截断")
        require(scan.failureCount == 0, "正常扫描不应产生文件系统错误")
        require(scan.issues.isEmpty, "正常扫描不应保留错误样本")
        require(scan.entries.contains { $0.name == "empty" && $0.isDirectory }, "必须保留空文件夹")
        require(scan.entries.contains { $0.name == "board.json" && !$0.isDirectory }, "必须显示非源码文件")
        require(!scan.entries.contains { $0.name == ".hidden.c" }, "必须跳过隐藏文件")

        let tree = ExplorerTreeBuilder.make(root: root, entries: scan.entries)
        let flattened = flatten(tree)
        require(flattened.contains("empty"), "文件树必须包含空文件夹")
        require(flattened.contains("include/sensor.h"), "文件树必须保留 include 层级")
        require(flattened.contains("src/sensor.c"), "文件树必须保留 src 层级")
        require(
            flattened.contains("firmware/drivers/sensors/light/adc.h"),
            "文件树必须保留多层嵌套文件夹"
        )
        require(
            tree.first?.name == "empty" || tree.first?.name == "firmware",
            "文件夹必须排在文件之前"
        )

        let outside = WorkspaceEntry(
            url: root.deletingLastPathComponent().appendingPathComponent("outside.c"),
            isDirectory: false
        )
        require(
            ExplorerTreeBuilder.make(root: root, entries: [outside]).isEmpty,
            "文件树不得接受根目录之外的条目"
        )

        let mainURL = root.appendingPathComponent("main.c")
        let externalURL = root.deletingLastPathComponent().appendingPathComponent("external.c")
        require(
            BuildScopeResolver.resolve(
                projectRoot: root,
                selectedFile: mainURL,
                projectFiles: [mainURL]
            ) == .project,
            "选中工程内文件时必须构建工程"
        )
        require(
            BuildScopeResolver.resolve(
                projectRoot: root,
                selectedFile: externalURL,
                projectFiles: [mainURL]
            ) == .singleFile,
            "选中工程外文件时必须构建当前单文件"
        )
        require(
            BuildScopeResolver.resolve(
                projectRoot: root,
                selectedFile: nil,
                projectFiles: [mainURL]
            ) == .singleFile,
            "未命名编辑器必须按单文件构建"
        )

        require(
            WorkspaceFolderNameValidator.normalized("drivers") == "drivers",
            "普通文件夹名称必须可用"
        )
        require(
            WorkspaceFolderNameValidator.normalized("  sensors  ") == "sensors",
            "文件夹名称应去除首尾空白"
        )
        require(
            WorkspaceFolderNameValidator.normalized("nested/path") == nil,
            "新建文件夹不能借名称跨越工程目录"
        )
        require(
            WorkspaceFolderNameValidator.normalized(".hidden") == nil,
            "不应通过新建功能创建隐藏目录"
        )
        let nestedDirectory = root.appendingPathComponent("firmware/drivers", isDirectory: true)
        require(
            WorkspacePathSafety.isWithinProject(nestedDirectory, projectRoot: root),
            "工程内的嵌套文件夹必须允许作为新建和移动目标"
        )
        require(
            WorkspacePathSafety.isWithinProject(root, projectRoot: root),
            "工程根目录必须允许作为移动目标"
        )
        require(
            !WorkspacePathSafety.isWithinProject(externalURL, projectRoot: root),
            "工程外路径不得成为新建或移动目标"
        )

        let moveSourceURL = root.appendingPathComponent("move-me.c")
        let moveTargetDirectory = root.appendingPathComponent("src", isDirectory: true)
        try write("void move_me(void) {}\n", to: moveSourceURL)
        let movedURL = try WorkspaceFileMover.moveFile(
            at: moveSourceURL,
            to: moveTargetDirectory,
            projectRoot: root
        )
        require(!fileManager.fileExists(atPath: moveSourceURL.path), "移动后原文件必须消失")
        require(fileManager.fileExists(atPath: movedURL.path), "移动后目标文件必须真实存在")

        try write("void duplicate(void) {}\n", to: moveSourceURL)
        do {
            _ = try WorkspaceFileMover.moveFile(
                at: moveSourceURL,
                to: moveTargetDirectory,
                projectRoot: root
            )
            require(false, "目标同名文件存在时必须拒绝覆盖")
        } catch WorkspaceFileMoveError.destinationAlreadyExists {
            // Expected: existing files are never overwritten.
        }

        let moveLinkTargetURL = root.appendingPathComponent("move-link-target.c")
        let moveLinkURL = root.appendingPathComponent("move-link.c")
        try write("keep target\n", to: moveLinkTargetURL)
        try fileManager.createSymbolicLink(
            at: moveLinkURL,
            withDestinationURL: moveLinkTargetURL
        )
        try expectFileMoveError(.symbolicLinkNotAllowed) {
            _ = try WorkspaceFileMover.moveFile(
                at: moveLinkURL,
                to: moveTargetDirectory,
                projectRoot: root
            )
        }
        require(
            fileManager.fileExists(atPath: moveLinkTargetURL.path),
            "拒绝移动符号链接后，链接目标必须保留在原位置"
        )
        require(
            (try? moveLinkURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink)
                == true,
            "拒绝移动符号链接后，链接本身必须保留"
        )
        require(
            !fileManager.fileExists(
                atPath: moveTargetDirectory.appendingPathComponent(moveLinkURL.lastPathComponent).path
            ),
            "拒绝符号链接后不得在目标文件夹创建任何项目"
        )

        testScanIssueCollection()
        try testEntryNameValidation()
        try testSourceFileCreation(root: root, fileManager: fileManager)
        try testEntryRename(root: root, fileManager: fileManager)
        try testPathPresentation(root: root)
        try testFileRevision(root: root)
        try testBuildProcessSafety()

        let limitedRoot = root.appendingPathComponent("limited", isDirectory: true)
        try fileManager.createDirectory(at: limitedRoot, withIntermediateDirectories: true)
        for index in 0..<10 {
            try write("\(index)\n", to: limitedRoot.appendingPathComponent("\(index).txt"))
        }
        let limited = WorkspaceScanner.scan(directory: limitedRoot, maximumEntries: 3)
        require(limited.entries.count == 3, "扫描结果必须遵守总条目上限")
        require(limited.inspectedCount == 3, "已检查条目数不得超过上限")
        require(limited.isTruncated, "超过上限时必须明确标记截断")
        require(limited.failureCount == 0, "条目截断不应被误报为扫描错误")

        print("底层测试通过：文件树、文件操作、路径边界、2,000 项机制和编译内存上限均正常。")
    }

    private static func testScanIssueCollection() {
        var collector = WorkspaceScanIssueCollector(maximumRetainedIssues: 2)
        for index in 0..<5 {
            collector.record(
                path: String(repeating: "p", count: 700) + "-\(index)",
                message: String(repeating: "错误", count: 300)
            )
        }

        require(collector.failureCount == 5, "扫描错误必须累计完整失败次数")
        require(collector.issues.count == 2, "扫描错误样本必须遵守固定保留上限")
        require(
            collector.issues.allSatisfy {
                $0.path.count <= WorkspaceScanIssueCollector.maximumPathCharacters
            },
            "扫描错误路径必须限制长度"
        )
        require(
            collector.issues.allSatisfy {
                $0.message.count <= WorkspaceScanIssueCollector.maximumMessageCharacters
            },
            "扫描错误消息必须限制长度"
        )

        var clampedCollector = WorkspaceScanIssueCollector(maximumRetainedIssues: Int.max)
        for index in 0..<(WorkspaceScanIssueCollector.hardMaximumRetainedIssues + 4) {
            clampedCollector.record(path: "/entry/\(index)", message: "失败")
        }
        require(
            clampedCollector.issues.count
                == WorkspaceScanIssueCollector.hardMaximumRetainedIssues,
            "调用方不得绕过扫描错误样本的硬上限"
        )
    }

    private static func testEntryNameValidation() throws {
        require(
            WorkspaceEntryNameValidator.normalized("  driver.c  ") == "driver.c",
            "资源名称应去除首尾空白"
        )
        require(
            WorkspaceEntryNameValidator.normalized("nested/file.c") == nil,
            "资源名称不能跨目录"
        )
        require(
            WorkspaceEntryNameValidator.normalized(".hidden.c") == nil,
            "资源名称不能创建隐藏项"
        )
        require(
            WorkspaceEntryNameValidator.normalized("bad:name.c") == nil,
            "资源名称不能包含 Finder 路径分隔字符"
        )
        require(
            WorkspaceEntryNameValidator.normalized("bad\nname.c") == nil,
            "资源名称不能包含控制字符"
        )
        require(
            WorkspaceEntryNameValidator.normalized(String(repeating: "a", count: 121)) == nil,
            "资源名称必须遵守 UTF-8 字节上限"
        )
        require(
            WorkspaceEntryNameValidator.normalized("e\u{301}.c") == "é.c",
            "资源名称应规范化 Unicode，避免视觉同名"
        )
    }

    private static func testSourceFileCreation(
        root: URL,
        fileManager: FileManager
    ) throws {
        let sourceDirectory = root.appendingPathComponent("generated", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)

        let cURL = try WorkspaceSourceFileCreator.createEmptyFile(
            named: "app",
            kind: .c,
            in: sourceDirectory,
            projectRoot: root
        )
        require(cURL.lastPathComponent == "app.c", "省略扩展名时应自动补充 .c")
        require(fileManager.fileExists(atPath: cURL.path), "必须在磁盘创建真实 C 文件")
        let createdCData = try Data(contentsOf: cURL)
        require(
            createdCData.isEmpty,
            "新建 C 文件必须为空，不能偷偷注入模板"
        )

        let headerURL = try WorkspaceSourceFileCreator.createEmptyFile(
            named: "app.h",
            kind: .header,
            in: sourceDirectory,
            projectRoot: root
        )
        require(fileManager.fileExists(atPath: headerURL.path), "必须在磁盘创建真实 H 文件")

        try expectFileOperationError(.destinationAlreadyExists) {
            _ = try WorkspaceSourceFileCreator.createEmptyFile(
                named: "app.c",
                kind: .c,
                in: sourceDirectory,
                projectRoot: root
            )
        }
        let existingCData = try Data(contentsOf: cURL)
        require(
            existingCData.isEmpty,
            "同名创建失败时绝不能截断已有文件"
        )

        try expectFileOperationError(.invalidSourceExtension(expected: "c")) {
            _ = try WorkspaceSourceFileCreator.createEmptyFile(
                named: "wrong.h",
                kind: .c,
                in: sourceDirectory,
                projectRoot: root
            )
        }
        try expectFileOperationError(.invalidName) {
            _ = try WorkspaceSourceFileCreator.createEmptyFile(
                named: "../escape.c",
                kind: .c,
                in: sourceDirectory,
                projectRoot: root
            )
        }

        let outsideDirectory = root.deletingLastPathComponent()
            .appendingPathComponent("stm32-outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: outsideDirectory) }
        try fileManager.createDirectory(at: outsideDirectory, withIntermediateDirectories: false)
        try expectFileOperationError(.parentOutsideProject) {
            _ = try WorkspaceSourceFileCreator.createEmptyFile(
                named: "escape.c",
                kind: .c,
                in: outsideDirectory,
                projectRoot: root
            )
        }

        let outsideViaLink = root.appendingPathComponent("outside-link", isDirectory: true)
        try fileManager.createSymbolicLink(at: outsideViaLink, withDestinationURL: outsideDirectory)
        try expectFileOperationError(.parentOutsideProject) {
            _ = try WorkspaceSourceFileCreator.createEmptyFile(
                named: "escape.c",
                kind: .c,
                in: outsideViaLink,
                projectRoot: root
            )
        }
        require(
            !fileManager.fileExists(atPath: outsideDirectory.appendingPathComponent("escape.c").path),
            "符号链接不能绕过工程路径边界"
        )
    }

    private static func testEntryRename(
        root: URL,
        fileManager: FileManager
    ) throws {
        let renameDirectory = root.appendingPathComponent("rename-tests", isDirectory: true)
        try fileManager.createDirectory(
            at: renameDirectory.appendingPathComponent("drivers", isDirectory: true),
            withIntermediateDirectories: true
        )
        let originalFileURL = renameDirectory.appendingPathComponent("original.c")
        try write("keep me\n", to: originalFileURL)
        let revisionBeforeRename = WorkspaceFileRevisionReader.read(originalFileURL)

        let renamedFileURL = try WorkspaceEntryRenamer.rename(
            at: originalFileURL,
            to: "renamed.c",
            projectRoot: root
        )
        require(!fileManager.fileExists(atPath: originalFileURL.path), "文件重命名后旧路径必须消失")
        require(fileManager.fileExists(atPath: renamedFileURL.path), "文件重命名后新路径必须存在")
        let renamedContents = try String(contentsOf: renamedFileURL, encoding: .utf8)
        require(
            renamedContents == "keep me\n",
            "文件重命名必须完整保留内容"
        )
        require(
            revisionBeforeRename == WorkspaceFileRevisionReader.read(renamedFileURL),
            "仅重命名路径不能伪装成文件内容被外部修改"
        )

        let originalFolderURL = renameDirectory.appendingPathComponent("drivers", isDirectory: true)
        let childURL = originalFolderURL.appendingPathComponent("gpio.c")
        try write("void gpio(void) {}\n", to: childURL)
        let renamedFolderURL = try WorkspaceEntryRenamer.rename(
            at: originalFolderURL,
            to: "platform",
            projectRoot: root
        )
        require(
            fileManager.fileExists(
                atPath: renamedFolderURL.appendingPathComponent("gpio.c").path
            ),
            "文件夹重命名必须保留其全部子项"
        )
        let remappedChildURL = WorkspaceURLRemapper.remap(
            childURL,
            replacing: originalFolderURL,
            with: renamedFolderURL
        )
        require(
            remappedChildURL?.standardizedFileURL.path
                == renamedFolderURL.appendingPathComponent("gpio.c").standardizedFileURL.path,
            "文件夹重命名后必须同步映射后代编辑器路径"
        )
        require(
            WorkspaceURLRemapper.remap(
                renamedFileURL,
                replacing: originalFolderURL,
                with: renamedFolderURL
            ) == nil,
            "文件夹重命名不得改动无关编辑器路径"
        )

        let collisionSourceURL = renameDirectory.appendingPathComponent("collision-source.c")
        let collisionTargetURL = renameDirectory.appendingPathComponent("collision-target.c")
        try write("source\n", to: collisionSourceURL)
        try write("target\n", to: collisionTargetURL)
        try expectFileOperationError(.destinationAlreadyExists) {
            _ = try WorkspaceEntryRenamer.rename(
                at: collisionSourceURL,
                to: collisionTargetURL.lastPathComponent,
                projectRoot: root
            )
        }
        let collisionTargetContents = try String(
            contentsOf: collisionTargetURL,
            encoding: .utf8
        )
        require(
            collisionTargetContents == "target\n",
            "重命名同名冲突时绝不能覆盖目标"
        )
        require(
            fileManager.fileExists(atPath: collisionSourceURL.path),
            "重命名冲突后源文件必须保留"
        )

        let caseOnlySourceURL = renameDirectory.appendingPathComponent("CaseOnly.c")
        let caseOnlyDestinationURL = renameDirectory.appendingPathComponent("caseonly.c")
        try write("case remains intact\n", to: caseOnlySourceURL)
        let caseOnlyRevision = WorkspaceFileRevisionReader.read(caseOnlySourceURL)
        let caseOnlyRenamedURL = try WorkspaceEntryRenamer.rename(
            at: caseOnlySourceURL,
            to: caseOnlyDestinationURL.lastPathComponent,
            projectRoot: root
        )
        require(
            caseOnlyRenamedURL.lastPathComponent == "caseonly.c",
            "仅大小写重命名必须返回用户请求的新名称"
        )
        let directoryNames = try fileManager.contentsOfDirectory(atPath: renameDirectory.path)
        require(
            directoryNames.contains("caseonly.c") && !directoryNames.contains("CaseOnly.c"),
            "目录中的真实文件名必须完成大小写变更"
        )
        let caseOnlyContents = try String(
            contentsOf: caseOnlyRenamedURL,
            encoding: .utf8
        )
        require(
            caseOnlyContents == "case remains intact\n",
            "仅大小写重命名必须保留文件内容"
        )
        require(
            caseOnlyRevision == WorkspaceFileRevisionReader.read(caseOnlyRenamedURL),
            "仅大小写重命名不得改变文件身份或内容版本"
        )

        try expectFileOperationError(.cannotRenameProjectRoot) {
            _ = try WorkspaceEntryRenamer.rename(
                at: root,
                to: "renamed-root",
                projectRoot: root
            )
        }
        let externalFileURL = root.deletingLastPathComponent()
            .appendingPathComponent("stm32-external-\(UUID().uuidString).c")
        defer { try? fileManager.removeItem(at: externalFileURL) }
        try write("outside\n", to: externalFileURL)
        try expectFileOperationError(.sourceOutsideProject) {
            _ = try WorkspaceEntryRenamer.rename(
                at: externalFileURL,
                to: "escaped.c",
                projectRoot: root
            )
        }

        let linkURL = renameDirectory.appendingPathComponent("renamed-link.c")
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: renamedFileURL)
        try expectFileOperationError(.symbolicLinkNotAllowed) {
            _ = try WorkspaceEntryRenamer.rename(
                at: linkURL,
                to: "link-new.c",
                projectRoot: root
            )
        }

        let unchangedURL = try WorkspaceEntryRenamer.rename(
            at: renamedFileURL,
            to: renamedFileURL.lastPathComponent,
            projectRoot: root
        )
        require(
            unchangedURL.standardizedFileURL.path == renamedFileURL.standardizedFileURL.path,
            "提交相同名称应安全地保持原路径"
        )
    }

    private static func testPathPresentation(root: URL) throws {
        let rootMain = root.appendingPathComponent("main.c")
        let sourceMain = root.appendingPathComponent("src/main.c")
        let testMain = root.appendingPathComponent("tests/main.c")
        let unique = root.appendingPathComponent("src/adc.c")

        require(
            WorkspacePathPresentation.relativePath(for: sourceMain, projectRoot: root)
                == "src/main.c",
            "工程内路径应转换为稳定的相对路径"
        )
        require(
            WorkspacePathPresentation.relativePath(
                for: root.deletingLastPathComponent().appendingPathComponent("outside.c"),
                projectRoot: root
            ) == nil,
            "工程外路径不能伪装成相对路径"
        )

        let labels = WorkspacePathPresentation.displayLabels(
            for: [rootMain, sourceMain, testMain, unique],
            projectRoot: root
        )
        require(
            labels[WorkspacePathSafety.canonical(rootMain).path]?.combined == "main.c — ./",
            "工程根目录的同名文件应明确显示根位置"
        )
        require(
            labels[WorkspacePathSafety.canonical(sourceMain).path]?.combined == "main.c — src/",
            "同名文件应显示最短唯一父路径"
        )
        require(
            labels[WorkspacePathSafety.canonical(testMain).path]?.combined == "main.c — tests/",
            "不同目录的同名文件必须可区分"
        )
        require(
            labels[WorkspacePathSafety.canonical(unique).path]?.combined == "adc.c",
            "没有重名的文件不应显示多余路径"
        )

        let nestedA = root.appendingPathComponent("board-a/src/duplicate.c")
        let nestedB = root.appendingPathComponent("board-b/src/duplicate.c")
        let nestedLabels = WorkspacePathPresentation.displayLabels(
            for: [nestedA, nestedB],
            projectRoot: root
        )
        require(
            nestedLabels[WorkspacePathSafety.canonical(nestedA).path]?.qualifier
                == "board-a/src",
            "父文件夹同名时应扩展到最短唯一后缀"
        )
        require(
            nestedLabels[WorkspacePathSafety.canonical(nestedB).path]?.qualifier
                == "board-b/src",
            "重复文件名展示必须对称且稳定"
        )
    }

    private static func testFileRevision(root: URL) throws {
        let url = root.appendingPathComponent("revision-test.c")
        try write("one\n", to: url)
        let original = WorkspaceFileRevisionReader.read(url)
        try write("a different size\n", to: url)
        let changed = WorkspaceFileRevisionReader.read(url)
        require(original != nil, "现有源码必须能记录磁盘版本")
        require(changed != nil, "修改后的源码必须能重新读取磁盘版本")
        require(original != changed, "外部修改后磁盘版本必须发生变化")
        require(
            WorkspaceFileRevisionReader.read(
                root.appendingPathComponent("missing-revision.c")
            ) == nil,
            "不存在的源码不能伪造磁盘版本"
        )
    }

    private static func testBuildProcessSafety() throws {
        var output = BoundedTextAccumulator(maximumCharacters: 1_000)
        for index in 0..<200 {
            output.append("command-\(index): \(String(repeating: "x", count: 100))\n")
        }
        require(
            output.text.count <= 1_000,
            "多文件编译输出必须始终遵守汇总字符上限"
        )
        require(
            output.text.contains("较早编译输出已自动清理"),
            "截断编译输出时必须给出明确标记"
        )
        require(
            output.text.contains("command-199"),
            "截断后应优先保留最新的编译错误上下文"
        )

        require(
            FirmwareFlashValidator.binaryRangeIsValid(
                startAddress: FirmwareFlashValidator.flashStart,
                byteCount: 65_536
            ),
            "从 Flash 起点写入完整 64 KiB BIN 应合法"
        )
        require(
            FirmwareFlashValidator.binaryRangeIsValid(
                startAddress: FirmwareFlashValidator.flashEndExclusive - 1,
                byteCount: 1
            ),
            "Flash 最后一个字节应允许写入"
        )
        require(
            !FirmwareFlashValidator.binaryRangeIsValid(
                startAddress: FirmwareFlashValidator.flashEndExclusive - 1,
                byteCount: 2
            ),
            "BIN 起始地址加长度超过 64 KiB 时必须拒绝"
        )
        require(
            !FirmwareFlashValidator.binaryRangeIsValid(
                startAddress: UInt64.max,
                byteCount: 2
            ),
            "BIN 地址加法溢出时必须拒绝"
        )

        let verifiedOutput = """
        File download complete
        Download verified successfully
        """
        require(
            STM32ProgrammerOutputValidator.confirmsDownloadAndVerification(verifiedOutput),
            "只有下载和校验均明确成功时才能报告烧录成功"
        )
        require(
            !STM32ProgrammerOutputValidator.confirmsDownloadAndVerification(
                verifiedOutput + "\nError: verification failed"
            ),
            "成功短语后出现错误证据时仍必须判定失败"
        )
        require(
            !STM32ProgrammerOutputValidator.confirmsDownloadAndVerification(
                "File download complete"
            ),
            "只有下载完成、没有校验证据时不得报告成功"
        )
        require(
            STM32TargetOutputValidator.confirmsF103MediumDensity(
                "Device ID : 0x410\nDevice name : STM32F101/F102/F103 Medium-density"
            ),
            "Device ID 0x410 应识别为 F103 中密度目标"
        )
        require(
            !STM32TargetOutputValidator.confirmsF103MediumDensity(
                "Device ID : 0x419\nDevice name : STM32F4"
            ),
            "错误目标芯片不得解锁烧录"
        )

        let controller = BuildProcessController()
        controller.cancel()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let didLaunch = try controller.launch(process)
        require(
            !didLaunch,
            "取消发生在启动前时不得再运行编译子进程"
        )

        let runningController = BuildProcessController()
        let sleepProcess = Process()
        sleepProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleepProcess.arguments = ["5"]
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let outcome = ProcessTestOutcome()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let launched = try runningController.launch(sleepProcess)
                outcome.set(launched: launched, error: nil)
                started.signal()
                if launched {
                    sleepProcess.waitUntilExit()
                    runningController.finish(sleepProcess)
                }
            } catch {
                outcome.set(launched: false, error: error.localizedDescription)
                started.signal()
            }
            finished.signal()
        }

        let didStartInTime = started.wait(timeout: .now() + 2) == .success
        require(didStartInTime, "编译子进程必须能进入可取消状态")
        let cancelStartedAt = Date()
        runningController.cancel()
        let didFinishInTime = finished.wait(timeout: .now() + 2) == .success
        require(didFinishInTime, "取消后必须真实终止正在运行的编译子进程")
        require(
            Date().timeIntervalSince(cancelStartedAt) < 2,
            "取消编译不能等待原命令自然结束"
        )
        let snapshot = outcome.snapshot()
        require(snapshot.launched, "取消测试必须先成功启动子进程")
        require(snapshot.error == nil, "取消测试不应产生启动错误")

        let timeoutController = ProcessController()
        let timeoutProcess = Process()
        timeoutProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        timeoutProcess.arguments = ["5"]
        let timeoutStartedAt = Date()
        let timeoutLaunched = try timeoutController.launch(
            timeoutProcess,
            timeout: 0.1,
            forceTerminationGrace: 0.1
        )
        require(timeoutLaunched, "超时测试必须成功启动子进程")
        timeoutProcess.waitUntilExit()
        timeoutController.finish(timeoutProcess)
        require(timeoutController.stopReason == .timedOut, "超时必须记录明确原因")
        require(
            Date().timeIntervalSince(timeoutStartedAt) < 2,
            "超时命令必须在有限时间内被终止"
        )

        let inheritedPipeController = ProcessController()
        let inheritedPipeProcess = Process()
        let inheritedPipe = Pipe()
        inheritedPipeProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        inheritedPipeProcess.arguments = ["-c", "sleep 5 &"]
        inheritedPipeProcess.standardOutput = inheritedPipe
        inheritedPipeProcess.standardError = inheritedPipe
        let pipeReadFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? inheritedPipe.fileHandleForReading.read(upToCount: 1)
            pipeReadFinished.signal()
        }
        let inheritedPipeStartedAt = Date()
        let inheritedPipeLaunched = try inheritedPipeController.launch(
            inheritedPipeProcess,
            timeout: 0.1,
            forceTerminationGrace: 0.1,
            interruptIO: {
                try? inheritedPipe.fileHandleForReading.close()
            }
        )
        require(inheritedPipeLaunched, "子进程管道测试必须成功启动")
        inheritedPipeProcess.waitUntilExit()
        require(
            pipeReadFinished.wait(timeout: .now() + 2) == .success,
            "子进程继承输出管道时，超时仍必须解除读取阻塞"
        )
        inheritedPipeController.finish(inheritedPipeProcess)
        require(
            inheritedPipeController.stopReason == .timedOut,
            "父进程退出但子进程仍占用管道时，必须记录超时"
        )
        require(
            Date().timeIntervalSince(inheritedPipeStartedAt) < 2,
            "子进程不得借由继承输出管道拖住任务"
        )
    }

    private static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func expectFileOperationError(
        _ expected: WorkspaceFileOperationError,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            require(false, "预期文件操作失败：\(expected)")
        } catch let error as WorkspaceFileOperationError {
            require(error == expected, "文件操作错误不符：\(error)，预期 \(expected)")
        }
    }

    private static func expectFileMoveError(
        _ expected: WorkspaceFileMoveError,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            require(false, "预期文件移动失败：\(expected)")
        } catch let error as WorkspaceFileMoveError {
            require(
                error.localizedDescription == expected.localizedDescription,
                "文件移动错误不符：\(error.localizedDescription)，预期 \(expected.localizedDescription)"
            )
        }
    }

    private static func flatten(
        _ nodes: [ExplorerTreeNode],
        prefix: String = ""
    ) -> [String] {
        nodes.flatMap { node in
            let path = prefix.isEmpty ? node.name : "\(prefix)/\(node.name)"
            return [path] + flatten(node.children ?? [], prefix: path)
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("文件夹底层测试失败：\(message)")
        }
    }
}

private final class ProcessTestOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var launched = false
    private var error: String?

    func set(launched: Bool, error: String?) {
        lock.lock()
        self.launched = launched
        self.error = error
        lock.unlock()
    }

    func snapshot() -> (launched: Bool, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (launched, error)
    }
}
