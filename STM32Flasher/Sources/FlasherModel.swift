import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Darwin

enum ProbeStatus: Equatable {
    case missingBackend
    case disconnected
    case connected
    case busy
    case failed

    var title: String {
        switch self {
        case .missingBackend: return "等待安装烧录引擎"
        case .disconnected: return "未检测设备"
        case .connected: return "设备已连接"
        case .busy: return "正在工作"
        case .failed: return "连接异常"
        }
    }

    var color: Color {
        switch self {
        case .missingBackend: return .yellow
        case .disconnected: return .secondary
        case .connected: return .green
        case .busy: return .cyan
        case .failed: return .red
        }
    }

    var symbol: String {
        switch self {
        case .missingBackend: return "shippingbox"
        case .disconnected: return "circle.dashed"
        case .connected: return "checkmark.circle.fill"
        case .busy: return "bolt.horizontal.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }
}

struct CommandResult {
    let exitCode: Int32
    let output: String
}

enum BuildIssueSeverity: String, Sendable {
    case error
    case warning
    case note
}

struct BuildIssue: Identifiable, Hashable, Sendable {
    let fileURL: URL
    let line: Int
    let column: Int
    let severity: BuildIssueSeverity
    let message: String

    var id: String {
        "\(fileURL.standardizedFileURL.path):\(line):\(column):\(severity.rawValue):\(message)"
    }
}

private enum WorkspaceUndoOperation {
    case move(currentURL: URL, originalURL: URL)
    case copy(createdURL: URL)
}

private enum ResourceLimits {
    static let maximumSourceBytes: Int64 = 1_000_000
    static let maximumFirmwareBytes: Int64 = 16 * 1024 * 1024
    static let maximumCompileSources = 128
    static let maximumIncludeDirectories = 128
    static let maximumCommandOutputBytes = 1024 * 1024
    static let maximumAggregateBuildOutputCharacters = 512_000
    static let maximumLogCharacters = 200_000
    static let maximumProjectEntries = 2_000
    static let maximumOpenEditors = 32
    static let compilerCommandTimeout: TimeInterval = 120
    static let probeListTimeout: TimeInterval = 20
    static let targetConnectTimeout: TimeInterval = 30
    static let flashCommandTimeout: TimeInterval = 180
    static let resetCommandTimeout: TimeInterval = 30
    static let forceTerminationGrace: TimeInterval = 2
}

struct ProjectFile: Identifiable, Hashable, Sendable {
    let url: URL

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.lowercased() }

    var symbol: String {
        switch fileExtension {
        case "c": return "c.square.fill"
        case "h": return "h.square.fill"
        case "s": return "s.square.fill"
        case "ld": return "link"
        default: return "doc.text"
        }
    }
}

enum OptimizationLevel: String, CaseIterable, Identifiable {
    case debug = "调试 (-Og)"
    case none = "不优化 (-O0)"
    case size = "体积优先 (-Os)"
    case speed = "速度优先 (-O2)"

    var id: String { rawValue }

    var compilerFlag: String {
        switch self {
        case .debug: return "-Og"
        case .none: return "-O0"
        case .size: return "-Os"
        case .speed: return "-O2"
        }
    }
}

@MainActor
final class FlasherModel: ObservableObject {
    @Published var cliURL: URL?
    @Published var firmwareURL: URL?
    @Published var binaryAddress = "0x08000000"
    @Published var eraseBeforeFlash = true
    @Published var resetAfterFlash = true
    @Published var swdFrequency = 4000
    @Published var probeStatus: ProbeStatus = .missingBackend
    @Published var probeName = "未检测"
    @Published var targetName = "STM32F103C8T6"
    @Published private(set) var probeDiagnosticTitle = "等待检测"
    @Published private(set) var probeDiagnosticDetail = "连接 ST-Link 后，软件会分别检查 USB 探针和目标芯片。"
    @Published var logText = "准备就绪。请选择固件并连接 ST-Link。\n"
    @Published var isDetecting = false
    @Published var isFlashing = false
    @Published var progress = 0.0
    @Published var operationText = "等待操作"
    @Published var lastResultText = "尚未执行烧录"
    @Published var alertTitle = ""
    @Published var alertMessage = ""
    @Published var isShowingAlert = false
    @Published var compilerURL: URL?
    @Published var objcopyURL: URL?
    @Published var sizeToolURL: URL?
    @Published var sourceCode = ""
    @Published var sourceFileName = "main.c"
    @Published var projectName = "单文件工程"
    @Published var projectDirectoryURL: URL?
    @Published var projectFiles: [ProjectFile] = []
    @Published var projectEntries: [WorkspaceEntry] = []
    @Published var openFiles: [ProjectFile] = []
    @Published var selectedProjectFile: ProjectFile?
    @Published var sourceIsDirty = false
    @Published var optimizationLevel: OptimizationLevel = .debug
    @Published var warningsAsErrors = false
    @Published var isCompiling = false
    @Published var isScanningProject = false
    @Published var buildLog = "代码编辑器已就绪。打开或输入 C 程序后点击“编译”。\n"
    @Published var lastBuildText = "尚未编译"
    @Published var buildErrorCount = 0
    @Published var buildWarningCount = 0
    @Published private(set) var buildIssues: [BuildIssue] = []
    @Published var requestedSourceLine: Int?
    @Published private(set) var recentProjectPaths: [String] =
        UserDefaults.standard.stringArray(forKey: "RecentProjectPaths") ?? []
    @Published private(set) var copiedProjectEntry: WorkspaceEntry?
    @Published private(set) var canUndoWorkspaceOperation = false
    @Published var flashUsed = 0
    @Published var ramUsed = 0
    @Published var lastBuildDuration = 0.0
    @Published private(set) var hasFreshBuild = false

    private var activeProcessController: ProcessController?
    private var activeOperationID: UUID?
    private var activeBuildID: UUID?
    private var buildTask: Task<Void, Never>?
    private var activeBuildController: ProcessController?
    private var projectScanTask: Task<Void, Never>?
    private var projectScanWorker: Task<WorkspaceScanResult, Never>?
    private var activeProjectScanID: UUID?
    private var selectedSourceSnapshot: WorkspaceFileRevision?
    private var sourceEditGeneration: UInt64 = 0
    private var didBootstrap = false
    private var shouldAutoDetectProbeAfterBootstrap = false
    private var projectSecurityScopedURL: URL?
    private var projectMonitor: DispatchSourceFileSystemObject?
    private var projectMonitorRefreshTask: Task<Void, Never>?
    private var lastWorkspaceUndoOperation: WorkspaceUndoOperation?
    private let cliPreferenceKey = "CustomSTM32ProgrammerCLIPath"
    private let lastWorkspaceKindKey = "LastWorkspaceKind"
    private let lastProjectPathKey = "LastProjectPath"
    private let lastProjectBookmarkKey = "LastProjectSecurityScopedBookmark"
    private let lastSourcePathKey = "LastSourcePath"
    private let recentProjectPathsKey = "RecentProjectPaths"
    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var hasCLI: Bool {
        guard let cliURL else { return false }
        return FileManager.default.isExecutableFile(atPath: cliURL.path)
    }

    var isBusy: Bool {
        isDetecting || isFlashing || isCompiling || isScanningProject
    }

    var hasCompiler: Bool {
        guard let compilerURL, let objcopyURL, let sizeToolURL else { return false }
        return FileManager.default.isExecutableFile(atPath: compilerURL.path)
            && FileManager.default.isExecutableFile(atPath: objcopyURL.path)
            && FileManager.default.isExecutableFile(atPath: sizeToolURL.path)
    }

    var compilerName: String {
        hasCompiler ? "ARM GCC 已就绪" : "未找到 ARM GCC"
    }

    var compileUnavailableReason: String? {
        if isScanningProject { return "正在读取工程文件，请稍候" }
        if isDetecting || isFlashing { return "请等待当前设备操作结束" }
        if isCompiling { return "正在编译" }
        guard hasCompiler else { return "未找到 ARM GCC 工具链" }

        if isEditingProjectFile {
            let sources = projectFiles.filter { $0.fileExtension == "c" }
            guard !sources.isEmpty else { return "工程中没有 C 源文件" }
            guard sources.contains(where: { fileSize($0.url) > 0 }) else {
                return "工程中的 C 源文件都是空的"
            }
        } else if sourceCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "当前 C 源码为空"
        }
        return nil
    }

    var canCompile: Bool {
        compileUnavailableReason == nil
    }

    var aiOneClickUnavailableReason: String? {
        if isScanningProject { return "正在读取工程文件，请稍候" }
        if isDetecting { return "正在检测 ST-Link" }
        if isCompiling { return "正在编译" }
        if isFlashing { return "正在烧录，请勿断开设备" }
        guard hasCompiler else { return "未找到 ARM GCC 工具链" }
        guard hasCLI else { return "未找到 STM32CubeProgrammer" }
        guard probeStatus == .connected else { return "请先检测并确认 ST-Link 和目标芯片" }
        guard let selectedProjectFile else { return "请先打开要替换的 main.c 文件" }
        guard selectedProjectFile.fileExtension == "c" else { return "请先打开 C 源文件，不能覆盖头文件" }
        guard !currentSourceHasExternalChanges else {
            return "磁盘上的当前源码已经变化，请先处理保存冲突"
        }
        return nil
    }

    var canImportClipboardAndFlash: Bool {
        aiOneClickUnavailableReason == nil
    }

    var currentSourceHasExternalChanges: Bool {
        guard let selectedProjectFile, let selectedSourceSnapshot else {
            return false
        }
        return sourceFileSnapshot(for: selectedProjectFile.url) != selectedSourceSnapshot
    }

    private var isEditingProjectFile: Bool {
        BuildScopeResolver.resolve(
            projectRoot: projectDirectoryURL,
            selectedFile: selectedProjectFile?.url,
            projectFiles: projectFiles.map(\.url)
        ) == .project
    }

    var flashUsageText: String {
        "\(flashUsed) / 65536 B"
    }

    var ramUsageText: String {
        "\(ramUsed) / 20480 B"
    }

    var flashUsage: Double {
        min(Double(flashUsed) / 65_536.0, 1)
    }

    var ramUsage: Double {
        min(Double(ramUsed) / 20_480.0, 1)
    }

    var workspaceDescription: String {
        projectDirectoryURL?.path ?? "单文件工程"
    }

    var sourceLineCount: Int {
        guard !sourceCode.isEmpty else { return 0 }
        return 1 + sourceCode.lazy.filter { $0 == "\n" }.count
    }

    var isBinaryFirmware: Bool {
        firmwareURL?.pathExtension.lowercased() == "bin"
    }

    var firmwareName: String {
        firmwareURL?.lastPathComponent ?? "拖入固件，或点击选择"
    }

    var firmwareDescription: String {
        guard let firmwareURL else {
            return ".hex / .bin / .elf，STM32F103C8T6 最大 64 KiB"
        }
        let size = fileSize(firmwareURL)
        return "\(firmwareURL.pathExtension.uppercased()) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }

    var canFlash: Bool {
        hasCLI
            && firmwareURL != nil
            && probeStatus == .connected
            && !isBusy
            && isValidAddress
            && isValidBinaryFirmwareRange
    }

    var canFlashCompiledSource: Bool {
        canFlash && hasFreshBuild
    }

    var flashReadinessText: String {
        if !hasCLI { return "未找到 STM32CubeProgrammer" }
        if firmwareURL == nil { return "请先选择固件，或在代码页完成编译" }
        if isBinaryFirmware && !isValidAddress { return "BIN 写入地址无效" }
        if isBinaryFirmware && !isValidBinaryFirmwareRange { return "BIN 写入区间超出 64 KiB Flash" }
        if isFlashing { return "正在烧录，请勿断开设备" }
        if isDetecting { return "正在检测 ST-Link" }
        if isCompiling || isScanningProject { return "请等待当前操作结束" }
        if probeStatus != .connected { return "固件已就绪，请检测 ST-Link 和目标芯片" }
        return "程序和设备已准备好"
    }

    var probeDisplayName: String {
        if probeStatus == .connected,
           probeName == "未检测" || probeName == "未发现" {
            return "ST-Link"
        }
        return probeName
    }

    private var isValidAddress: Bool {
        guard isBinaryFirmware else { return true }
        guard let address = parsedBinaryAddress else { return false }
        return (FirmwareFlashValidator.flashStart..<FirmwareFlashValidator.flashEndExclusive)
            .contains(address)
    }

    private var isValidBinaryFirmwareRange: Bool {
        guard isBinaryFirmware else { return true }
        guard let firmwareURL, let address = parsedBinaryAddress else { return false }
        return FirmwareFlashValidator.binaryRangeIsValid(
            startAddress: address,
            byteCount: fileSize(firmwareURL)
        )
    }

    private var parsedBinaryAddress: UInt64? {
        let normalized = binaryAddress.lowercased().replacingOccurrences(of: "0x", with: "")
        return UInt64(normalized, radix: 16)
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        refreshCLI()
        refreshCompiler()
        shouldAutoDetectProbeAfterBootstrap = hasCLI
        restoreLastWorkspace()
        performBootstrapProbeDetectionIfIdle()
    }

    private func performBootstrapProbeDetectionIfIdle() {
        guard shouldAutoDetectProbeAfterBootstrap, hasCLI, !isBusy else { return }
        shouldAutoDetectProbeAfterBootstrap = false
        detectProbe()
    }

    func refreshCLI() {
        cliURL = CLIResolver.resolve()
        if hasCLI {
            probeStatus = .disconnected
            probeName = "未检测"
            probeDiagnosticTitle = "等待检测"
            probeDiagnosticDetail = "烧录引擎已就绪，点击检测设备可检查 USB、供电和 SWD 连接。"
            appendLog("已找到 STM32CubeProgrammer：\(cliURL!.path)")
        } else {
            probeStatus = .missingBackend
            probeDiagnosticTitle = "缺少烧录引擎"
            probeDiagnosticDetail = "未找到 STM32CubeProgrammer，暂时不能检测或烧录。"
            appendLog("未找到 STM32_Programmer_CLI，请先安装 STM32CubeProgrammer。")
        }
    }

    func refreshCompiler() {
        let resolved = CompilerResolver.resolve()
        compilerURL = resolved.compiler
        objcopyURL = resolved.objcopy
        sizeToolURL = resolved.size
        if hasCompiler {
            appendBuildLog("已找到 ARM GCC：\(compilerURL!.path)")
        } else {
            appendBuildLog("ARM GCC 工具链不完整。需要 gcc、objcopy 和 size。")
        }
    }

    func selectCLI(_ url: URL) {
        guard url.lastPathComponent == "STM32_Programmer_CLI" else {
            showAlert("文件不正确", "请选择名为 STM32_Programmer_CLI 的可执行文件。")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            showAlert("文件不可执行", "所选文件没有执行权限。")
            return
        }
        UserDefaults.standard.set(url.path, forKey: cliPreferenceKey)
        cliURL = url
        probeStatus = .disconnected
        probeDiagnosticTitle = "等待检测"
        probeDiagnosticDetail = "烧录引擎已选择，点击检测设备确认 ST-Link 与目标芯片。"
        appendLog("已选择烧录引擎：\(url.path)")
    }

    func selectFirmware(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let ext = url.pathExtension.lowercased()
        guard ["hex", "bin", "elf"].contains(ext) else {
            showAlert("不支持的文件", "请选择 .hex、.bin 或 .elf 固件。")
            return
        }

        let size = fileSize(url)
        guard size > 0 else {
            showAlert("固件无效", "文件为空或无法读取。")
            return
        }

        guard size <= ResourceLimits.maximumFirmwareBytes else {
            showAlert("固件文件过大", "为防止异常资源占用，单个固件文件不能超过 16 MiB。")
            return
        }

        if ext == "bin" && size > 65_536 {
            showAlert(
                "BIN 固件过大",
                "STM32F103C8T6 官方 Flash 容量为 64 KiB，当前文件为 \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))。为防止越界，第一版拒绝烧录。"
            )
            return
        }

        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: "LastFirmwareBookmark")
        } catch {
            // The selected URL remains valid for this app session.
        }

        firmwareURL = url
        hasFreshBuild = false
        appendLog("已选择固件：\(url.lastPathComponent)（\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))）")
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let raw = item as? String {
                url = URL(string: raw)
            } else if let directURL = item as? URL {
                url = directURL
            }
            guard let url else { return }
            Task { @MainActor in
                self?.selectFirmware(url)
            }
        }
        return true
    }

    func detectProbe() {
        guard let cliURL, hasCLI, !isBusy else { return }
        isDetecting = true
        probeStatus = .busy
        probeDiagnosticTitle = "正在检查 USB 探针"
        probeDiagnosticDetail = "先确认 macOS 能识别 ST-Link，再尝试通过 SWD 连接芯片。"
        operationText = "正在检测 ST-Link"
        progress = 0.2
        appendLog("开始检测 ST-Link…")

        run(
            cliURL: cliURL,
            arguments: ["-l", "stlink"],
            timeout: ResourceLimits.probeListTimeout
        ) { [weak self] result in
            guard let self else { return }
            if result.exitCode == 0 && self.outputContainsProbe(result.output) {
                self.appendLog(result.output)
                let detectedProbeName = self.parseProbeName(result.output)
                self.probeName = detectedProbeName
                self.probeDiagnosticTitle = "ST-Link 已识别"
                self.probeDiagnosticDetail = "USB 通信正常，正在检查目标板供电和 SWD 连接。"
                self.progress = 0.55
                self.operationText = "正在确认目标芯片"
                self.appendLog("已发现 \(detectedProbeName)，正在通过 SWD 只读检测目标芯片…")
                self.run(
                    cliURL: cliURL,
                    arguments: [
                        "-c", "port=SWD", "mode=UR", "reset=HWrst",
                        "freq=\(self.swdFrequency)"
                    ],
                    timeout: ResourceLimits.targetConnectTimeout
                ) { [weak self] targetResult in
                    guard let self else { return }
                    self.isDetecting = false
                    self.progress = 0
                    self.appendLog(targetResult.output)

                    if targetResult.exitCode == 0,
                       STM32TargetOutputValidator.confirmsF103MediumDensity(targetResult.output) {
                        self.probeStatus = .connected
                        self.probeName = detectedProbeName
                        self.targetName = "STM32F10x 中密度 · ID 0x410"
                        self.probeDiagnosticTitle = "连接正常"
                        self.probeDiagnosticDetail = "ST-Link 与 STM32F103C8T6 已确认，可以安全烧录。"
                        self.lastResultText = "ST-Link 与目标芯片检测成功"
                        self.operationText = "目标芯片已确认"
                        self.appendLog("✓ ST-Link 已连接，目标 ID 为 0x410（STM32F103C8T6 所属中密度系列）。")
                    } else {
                        self.probeStatus = .failed
                        self.lastResultText = "目标芯片检测失败"
                        self.operationText = "目标芯片未确认"
                        let message: String
                        if targetResult.exitCode != 0 {
                            message = self.friendlyFailureMessage(targetResult.output)
                            let diagnostic = self.probeDiagnostic(
                                for: targetResult.output,
                                probeWasFound: true
                            )
                            self.probeDiagnosticTitle = diagnostic.title
                            self.probeDiagnosticDetail = diagnostic.detail
                        } else {
                            message = "ST-Link 已发现，但目标没有报告 STM32F103 中密度器件标识（Device ID 0x410）。为避免烧录错误芯片，已禁止烧录。"
                            self.probeDiagnosticTitle = "芯片型号不匹配"
                            self.probeDiagnosticDetail = "探针已连接，但未确认 Device ID 0x410；为避免写错芯片，已禁止烧录。"
                        }
                        self.appendLog("✗ \(message)")
                        self.showAlert("目标芯片未确认", message)
                    }
                }
            } else {
                self.isDetecting = false
                self.progress = 0
                self.probeStatus = .failed
                self.probeName = "未发现"
                self.lastResultText = "没有检测到 ST-Link"
                let diagnostic = self.probeDiagnostic(
                    for: result.output,
                    probeWasFound: false
                )
                self.probeDiagnosticTitle = diagnostic.title
                self.probeDiagnosticDetail = diagnostic.detail
                self.appendLog(result.output)
                self.appendLog("✗ \(diagnostic.detail)")
            }
        }
    }

    func flash() {
        guard let cliURL, let firmwareURL, canFlash else { return }

        guard validateFirmwareBeforeFlash(firmwareURL) else { return }

        let shouldResetAfterFlash = resetAfterFlash
        let shouldEraseBeforeFlash = eraseBeforeFlash
        let selectedSWDFrequency = swdFrequency
        isFlashing = true
        probeStatus = .busy
        progress = 0.08
        operationText = "正在重新确认目标芯片"
        lastResultText = "烧录进行中"
        appendLog("────────────────────────")
        appendLog("开始烧录：\(firmwareURL.lastPathComponent)")
        appendLog("擦除前重新确认目标芯片，避免检测后更换设备造成误烧录…")

        run(
            cliURL: cliURL,
            arguments: [
                "-c", "port=SWD", "mode=UR", "reset=HWrst",
                "freq=\(selectedSWDFrequency)"
            ],
            timeout: ResourceLimits.targetConnectTimeout
        ) { [weak self] targetResult in
            guard let self else { return }
            self.appendLog(targetResult.output)
            guard targetResult.exitCode == 0,
                  STM32TargetOutputValidator.confirmsF103MediumDensity(targetResult.output)
            else {
                self.isFlashing = false
                self.progress = 0
                self.probeStatus = .failed
                self.operationText = "目标芯片未确认，未执行擦除"
                self.lastResultText = "烧录已停止：目标芯片未确认"
                let message = targetResult.exitCode == 0
                    ? "烧录前没有再次确认到 Device ID 0x410。为避免擦除错误芯片，本次未执行擦除和写入。"
                    : self.friendlyFailureMessage(targetResult.output)
                self.appendLog("✗ \(message)")
                self.showAlert("烧录已安全停止", message)
                return
            }

            self.targetName = "STM32F10x 中密度 · ID 0x410"
            self.appendLog("✓ 烧录前目标复核通过（Device ID 0x410）。")
            self.performFirmwareFlash(
                cliURL: cliURL,
                firmwareURL: firmwareURL,
                shouldEraseBeforeFlash: shouldEraseBeforeFlash,
                shouldResetAfterFlash: shouldResetAfterFlash,
                swdFrequency: selectedSWDFrequency
            )
        }
    }

    private func performFirmwareFlash(
        cliURL: URL,
        firmwareURL: URL,
        shouldEraseBeforeFlash: Bool,
        shouldResetAfterFlash: Bool,
        swdFrequency: Int
    ) {
        guard validateFirmwareBeforeFlash(firmwareURL) else {
            isFlashing = false
            progress = 0
            probeStatus = .connected
            operationText = "固件无效，未执行烧录"
            lastResultText = "烧录已停止：固件无效"
            return
        }

        let securityAccess = firmwareURL.startAccessingSecurityScopedResource()
        var arguments = [
            "-c", "port=SWD", "mode=UR", "reset=HWrst", "freq=\(swdFrequency)"
        ]

        if shouldEraseBeforeFlash {
            arguments += ["-e", "all"]
        }

        arguments += ["-d", firmwareURL.path]
        if isBinaryFirmware {
            arguments.append(normalizedAddress)
        }
        arguments.append("-v")
        if shouldResetAfterFlash {
            arguments.append("-rst")
        }

        appendLog("执行参数：\(redactedCommand(arguments))")
        progress = 0.18
        operationText = shouldEraseBeforeFlash ? "正在擦除并下载固件" : "正在下载固件"

        run(
            cliURL: cliURL,
            arguments: arguments,
            timeout: ResourceLimits.flashCommandTimeout,
            cleanup: {
                if securityAccess {
                    firmwareURL.stopAccessingSecurityScopedResource()
                }
            }
        ) { [weak self] result in
            guard let self else { return }
            self.isFlashing = false
            self.appendLog(result.output)

            let downloadAndVerificationSucceeded = result.exitCode == 0
                && STM32ProgrammerOutputValidator.confirmsDownloadAndVerification(result.output)
            self.progress = downloadAndVerificationSucceeded ? 1 : 0

            if downloadAndVerificationSucceeded {
                self.probeStatus = .connected
                self.probeName = self.parseProbeName(result.output)
                self.operationText = "烧录完成"
                self.lastResultText = "烧录、校验成功"
                self.appendLog("✓ 烧录成功，校验通过\(shouldResetAfterFlash ? "，芯片已复位运行" : "")。")
                NSSound(named: "Glass")?.play()
                self.showAlert("烧录成功", "固件已写入并校验通过\(shouldResetAfterFlash ? "，目标芯片已复位运行。" : "。")")
            } else {
                self.probeStatus = .failed
                self.operationText = "烧录失败"
                self.lastResultText = "烧录失败，请查看日志"
                self.appendLog("✗ 烧录未完成，退出码：\(result.exitCode)。")
                NSSound(named: "Basso")?.play()
                let message = result.exitCode == 0
                    ? "烧录引擎未同时报告下载完成与校验成功，或输出中包含错误。为避免误报，本次操作按失败处理。"
                    : self.friendlyFailureMessage(result.output)
                self.showAlert("烧录失败", message)
            }
        }
    }

    func cancel() {
        activeOperationID = nil
        let wasCompiling = isCompiling
        if wasCompiling {
            buildTask?.cancel()
            activeBuildController?.cancel(
                forceTerminationGrace: ResourceLimits.forceTerminationGrace
            )
            lastBuildText = "正在停止编译"
            operationText = "正在停止编译进程"
            appendBuildLog("正在停止编译进程…")
        } else {
            activeBuildID = nil
            buildTask = nil
            activeBuildController = nil
        }
        cancelProjectScan()
        activeProcessController?.cancel(
            forceTerminationGrace: ResourceLimits.forceTerminationGrace
        )
        activeProcessController = nil
        isDetecting = false
        isFlashing = false
        progress = 0
        probeStatus = hasCLI ? .disconnected : .missingBackend
        if !wasCompiling {
            isCompiling = false
            operationText = "操作已停止"
        }
        appendLog("操作已由用户停止。")
    }

    func openCubeProgrammerDownload() {
        guard let url = URL(string: "https://www.st.com/en/development-tools/stm32cubeprog.html") else { return }
        NSWorkspace.shared.open(url)
    }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
    }

    func clearLog() {
        logText = "日志已清空。\n"
    }

    func createProject(at directory: URL) {
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try WorkspaceSourceFileCreator.createEmptyFile(
                named: "main.c",
                kind: .c,
                in: directory,
                projectRoot: directory
            )
            openProject(directory)
            appendBuildLog("已创建工程：\(directory.path)")
        } catch WorkspaceFileOperationError.destinationAlreadyExists {
            showAlert("工程已存在", "所选文件夹中已有 main.c。请直接打开该工程，或选择新的文件夹。")
        } catch {
            showAlert("无法创建工程", error.localizedDescription)
        }
    }

    func openProject(_ directory: URL) {
        stopProjectMonitor()
        retainSecurityScope(for: directory)
        startProjectScan(
            directory: directory,
            isRefresh: false,
            preferredSourcePath: nil
        )
    }

    @discardableResult
    func createFolder(named rawName: String, in parentDirectoryURL: URL? = nil) -> URL? {
        guard let projectDirectoryURL else {
            showAlert("请先打开工程", "新建子文件夹前，请先打开一个 STM32 工程文件夹。")
            return nil
        }
        guard !isBusy else { return nil }
        guard let name = WorkspaceFolderNameValidator.normalized(rawName) else {
            showAlert(
                "文件夹名称无效",
                "请输入 1～120 字节的普通名称，不能包含 /、:、控制字符或以 . 开头。"
            )
            return nil
        }

        let projectURL = WorkspacePathSafety.canonical(projectDirectoryURL)
        let parentURL = WorkspacePathSafety.canonical(parentDirectoryURL ?? projectURL)
        guard WorkspacePathSafety.isWithinProject(parentURL, projectRoot: projectURL),
              isDirectory(parentURL)
        else {
            showAlert("文件夹名称无效", "新文件夹必须创建在当前工程目录内。")
            return nil
        }
        let folderURL = parentURL.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folderURL.path) else {
            showAlert("文件夹已存在", "目标文件夹中已经有名为“\(name)”的文件夹。")
            return nil
        }

        do {
            try FileManager.default.createDirectory(
                at: folderURL,
                withIntermediateDirectories: false
            )
            appendBuildLog("已新建文件夹：\(folderURL.path)")
            refreshProjectFiles()
            return folderURL
        } catch {
            showAlert("无法新建文件夹", error.localizedDescription)
            return nil
        }
    }

    func createSourceFile(
        named rawName: String,
        expectedExtension: String,
        in parentDirectoryURL: URL? = nil
    ) {
        guard let projectDirectoryURL else {
            showAlert("请先打开工程", "请先打开一个工程文件夹，再在其中新建源码文件。")
            return
        }
        guard !isBusy else { return }

        let kind: WorkspaceSourceFileKind
        switch expectedExtension.lowercased() {
        case "c":
            kind = .c
        case "h":
            kind = .header
        default:
            showAlert("文件类型无效", "当前只能新建 .c 或 .h 文件。")
            return
        }

        let projectURL = WorkspacePathSafety.canonical(projectDirectoryURL)
        let parentURL = WorkspacePathSafety.canonical(parentDirectoryURL ?? projectURL)
        do {
            let fileURL = try WorkspaceSourceFileCreator.createEmptyFile(
                named: rawName,
                kind: kind,
                in: parentURL,
                projectRoot: projectURL
            )
            let file = ProjectFile(url: fileURL)
            openProjectFile(file)
            appendBuildLog("已新建源码：\(fileURL.path)")
            refreshProjectFiles()
        } catch {
            showAlert("无法新建源码", error.localizedDescription)
        }
    }

    func renameProjectEntry(_ entry: WorkspaceEntry, to rawName: String) {
        guard let projectDirectoryURL else {
            showAlert("请先打开工程", "重命名前，请先打开一个工程文件夹。")
            return
        }
        guard !isBusy else { return }

        var requestedName = rawName
        if entry.isEditableSource {
            if URL(fileURLWithPath: requestedName).pathExtension.isEmpty {
                requestedName += ".\(entry.fileExtension)"
            }
            let requestedExtension = URL(fileURLWithPath: requestedName)
                .pathExtension
                .lowercased()
            guard ["c", "h"].contains(requestedExtension) else {
                showAlert("源码名称无效", "C 源码必须保留 .c 或 .h 扩展名。")
                return
            }
        }

        let projectURL = WorkspacePathSafety.canonical(projectDirectoryURL)
        let originalSourceURL = entry.url.standardizedFileURL
        let sourceURL = WorkspacePathSafety.canonical(originalSourceURL)
        do {
            let renamedURL = try WorkspaceEntryRenamer.rename(
                at: originalSourceURL,
                to: requestedName,
                projectRoot: projectURL
            )
            guard renamedURL.standardizedFileURL.path != sourceURL.standardizedFileURL.path else {
                return
            }

            openFiles = openFiles.map { file in
                guard let remappedURL = WorkspaceURLRemapper.remap(
                    file.url,
                    replacing: sourceURL,
                    with: renamedURL
                ) else {
                    return file
                }
                return ProjectFile(url: remappedURL)
            }

            if let selectedProjectFile,
               let remappedURL = WorkspaceURLRemapper.remap(
                   selectedProjectFile.url,
                   replacing: sourceURL,
                   with: renamedURL
               ) {
                let renamedFile = ProjectFile(url: remappedURL)
                self.selectedProjectFile = renamedFile
                sourceFileName = renamedFile.name
                lastBuildText = "已重命名 \(renamedFile.name)"
                invalidateCompiledFirmware()
                rememberCurrentSelection(renamedFile)
            }

            appendBuildLog("已重命名：\(sourceURL.lastPathComponent) → \(renamedURL.lastPathComponent)")
            setWorkspaceUndo(.move(currentURL: renamedURL, originalURL: originalSourceURL))
            refreshProjectFiles()
        } catch {
            showAlert("无法重命名", error.localizedDescription)
        }
    }

    func renameUntitledSource(to rawName: String) {
        guard selectedProjectFile == nil else { return }
        guard var name = WorkspaceEntryNameValidator.normalized(rawName) else {
            showAlert("名称无效", "请输入普通文件名，不能包含 /、:、控制字符或以 . 开头。")
            return
        }
        if URL(fileURLWithPath: name).pathExtension.isEmpty {
            name += ".c"
        }
        guard ["c", "h"].contains(
            URL(fileURLWithPath: name).pathExtension.lowercased()
        ) else {
            showAlert("名称无效", "未保存的源码名称必须以 .c 或 .h 结尾。")
            return
        }
        sourceFileName = name
        if projectDirectoryURL == nil {
            projectName = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        }
        lastBuildText = "已命名为 \(name)，保存后写入磁盘"
        appendBuildLog("未保存源码已命名为 \(name)。")
    }

    func moveProjectEntry(_ entry: WorkspaceEntry, to destinationDirectoryURL: URL) {
        guard let projectDirectoryURL else {
            showAlert("请先打开工程", "移动文件前，请先打开一个 STM32 工程文件夹。")
            return
        }
        guard !isBusy, !entry.isDirectory else { return }

        let projectURL = WorkspacePathSafety.canonical(projectDirectoryURL)
        let originalSourceURL = entry.url.standardizedFileURL
        let sourceURL = WorkspacePathSafety.canonical(originalSourceURL)
        let destinationURL = WorkspacePathSafety.canonical(destinationDirectoryURL)
        guard WorkspacePathSafety.isWithinProject(sourceURL, projectRoot: projectURL, allowRoot: false),
              WorkspacePathSafety.isWithinProject(destinationURL, projectRoot: projectURL),
              isDirectory(destinationURL)
        else {
            showAlert("移动位置无效", "只能在当前工程目录及其子文件夹内归类文件。")
            return
        }

        let movedURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
        guard movedURL.standardizedFileURL.path != sourceURL.standardizedFileURL.path else {
            appendBuildLog("文件已在目标文件夹中：\(sourceURL.lastPathComponent)")
            return
        }
        guard !FileManager.default.fileExists(atPath: movedURL.path) else {
            showAlert("目标已存在同名文件", "为防止覆盖，未移动 \(sourceURL.lastPathComponent)。")
            return
        }

        do {
            let confirmedMovedURL = try WorkspaceFileMover.moveFile(
                at: originalSourceURL,
                to: destinationURL,
                projectRoot: projectURL
            )
            let movedFile = ProjectFile(url: confirmedMovedURL)
            let wasSelected = selectedProjectFile?.url.standardizedFileURL.path
                == sourceURL.standardizedFileURL.path
            openFiles = openFiles.map { file in
                file.url.standardizedFileURL.path == sourceURL.standardizedFileURL.path ? movedFile : file
            }

            if wasSelected {
                selectedProjectFile = movedFile
                sourceFileName = movedFile.name
                invalidateCompiledFirmware()
                lastBuildText = sourceIsDirty
                    ? "已移动 \(movedFile.name)，未保存修改仍保留"
                    : "已移动 \(movedFile.name)"
                rememberCurrentSelection(movedFile)
            }

            appendBuildLog("已移动文件：\(sourceURL.lastPathComponent) → \(destinationURL.path)")
            setWorkspaceUndo(.move(currentURL: confirmedMovedURL, originalURL: originalSourceURL))
            refreshProjectFiles()
        } catch {
            showAlert("无法移动文件", error.localizedDescription)
        }
    }

    func moveDroppedProjectFile(at sourceURL: URL, to destinationDirectoryURL: URL) {
        let sourcePath = WorkspacePathSafety.canonical(sourceURL).path
        guard let entry = projectEntries.first(where: {
            !$0.isDirectory && WorkspacePathSafety.canonical($0.url).path == sourcePath
        }) else {
            showAlert(
                "不能移动这个项目",
                "当前版本只允许拖动工程内部的单个文件。外部文件和文件夹不会自动导入。"
            )
            return
        }
        moveProjectEntry(entry, to: destinationDirectoryURL)
    }

    func copyProjectEntry(_ entry: WorkspaceEntry) {
        guard let projectDirectoryURL,
              WorkspacePathSafety.isWithinProject(
                entry.url,
                projectRoot: projectDirectoryURL,
                allowRoot: false
              ),
              FileManager.default.fileExists(atPath: entry.url.path)
        else {
            showAlert("无法复制", "只能复制当前工程中仍然存在的文件或文件夹。")
            return
        }
        copiedProjectEntry = entry
        appendBuildLog("已复制到工程剪贴板：\(entry.url.lastPathComponent)")
    }

    func pasteCopiedProjectEntry(into destinationDirectoryURL: URL) {
        guard let projectDirectoryURL, let copiedProjectEntry, !isBusy else { return }
        let projectRoot = WorkspacePathSafety.canonical(projectDirectoryURL)
        let sourceURL = WorkspacePathSafety.canonical(copiedProjectEntry.url)
        let destinationDirectory = WorkspacePathSafety.canonical(destinationDirectoryURL)
        guard WorkspacePathSafety.isWithinProject(sourceURL, projectRoot: projectRoot, allowRoot: false),
              WorkspacePathSafety.isWithinProject(destinationDirectory, projectRoot: projectRoot),
              isDirectory(destinationDirectory),
              FileManager.default.fileExists(atPath: sourceURL.path)
        else {
            showAlert("无法粘贴", "复制源或目标文件夹已经失效。")
            return
        }
        if copiedProjectEntry.isDirectory,
           WorkspacePathSafety.isWithinProject(destinationDirectory, projectRoot: sourceURL) {
            showAlert("无法粘贴", "不能把文件夹复制到它自己的子文件夹中。")
            return
        }

        let destinationURL = availableCopyDestination(
            for: sourceURL,
            in: destinationDirectory,
            isDirectory: copiedProjectEntry.isDirectory
        )
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            setWorkspaceUndo(.copy(createdURL: destinationURL))
            appendBuildLog("已粘贴：\(destinationURL.lastPathComponent)")
            refreshProjectFiles()
        } catch {
            showAlert("粘贴失败", error.localizedDescription)
        }
    }

    func undoLastWorkspaceOperation() {
        guard !isBusy, let operation = lastWorkspaceUndoOperation,
              let projectDirectoryURL
        else { return }
        let projectRoot = WorkspacePathSafety.canonical(projectDirectoryURL)

        do {
            switch operation {
            case let .move(currentURL, originalURL):
                guard WorkspacePathSafety.isWithinProject(currentURL, projectRoot: projectRoot, allowRoot: false),
                      WorkspacePathSafety.isWithinProject(originalURL, projectRoot: projectRoot, allowRoot: false),
                      FileManager.default.fileExists(atPath: currentURL.path),
                      !FileManager.default.fileExists(atPath: originalURL.path)
                else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try FileManager.default.moveItem(at: currentURL, to: originalURL)
                remapOpenWorkspaceURLs(replacing: currentURL, with: originalURL)
                appendBuildLog("已撤销文件操作：恢复 \(originalURL.lastPathComponent)")

            case let .copy(createdURL):
                guard WorkspacePathSafety.isWithinProject(createdURL, projectRoot: projectRoot, allowRoot: false),
                      FileManager.default.fileExists(atPath: createdURL.path)
                else {
                    throw CocoaError(.fileNoSuchFile)
                }
                if sourceIsDirty,
                   selectedProjectFile.map({
                       WorkspacePathSafety.isWithinProject(
                           $0.url,
                           projectRoot: createdURL
                       )
                   }) == true {
                    showAlert("无法撤销", "复制出的文件中存在未保存修改，请先保存或关闭。")
                    return
                }
                try FileManager.default.removeItem(at: createdURL)
                openFiles.removeAll {
                    WorkspacePathSafety.isWithinProject($0.url, projectRoot: createdURL)
                }
                appendBuildLog("已撤销复制：\(createdURL.lastPathComponent)")
            }
            setWorkspaceUndo(nil)
            refreshProjectFiles()
        } catch {
            setWorkspaceUndo(nil)
            showAlert("无法撤销", "文件可能已被其他程序修改或目标位置已有同名项目。")
        }
    }

    private func availableCopyDestination(
        for sourceURL: URL,
        in directoryURL: URL,
        isDirectory: Bool
    ) -> URL {
        let fileManager = FileManager.default
        let originalName = sourceURL.deletingPathExtension().lastPathComponent
        let pathExtension = isDirectory ? "" : sourceURL.pathExtension
        for index in 1...999 {
            let suffix = index == 1 ? " 副本" : " 副本 \(index)"
            let name = originalName + suffix + (pathExtension.isEmpty ? "" : ".\(pathExtension)")
            let candidate = directoryURL.appendingPathComponent(name, isDirectory: isDirectory)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directoryURL.appendingPathComponent(UUID().uuidString, isDirectory: isDirectory)
    }

    private func setWorkspaceUndo(_ operation: WorkspaceUndoOperation?) {
        lastWorkspaceUndoOperation = operation
        canUndoWorkspaceOperation = operation != nil
    }

    private func remapOpenWorkspaceURLs(replacing sourceURL: URL, with destinationURL: URL) {
        openFiles = openFiles.map { file in
            guard let remappedURL = WorkspaceURLRemapper.remap(
                file.url,
                replacing: sourceURL,
                with: destinationURL
            ) else { return file }
            return ProjectFile(url: remappedURL)
        }
        if let selectedProjectFile,
           let remappedURL = WorkspaceURLRemapper.remap(
               selectedProjectFile.url,
               replacing: sourceURL,
               with: destinationURL
           ) {
            let remappedFile = ProjectFile(url: remappedURL)
            self.selectedProjectFile = remappedFile
            sourceFileName = remappedFile.name
            rememberCurrentSelection(remappedFile)
        }
    }

    func refreshProjectFiles() {
        guard let projectDirectoryURL else { return }
        startProjectScan(
            directory: projectDirectoryURL,
            isRefresh: true,
            preferredSourcePath: nil
        )
    }

    func closeProject() {
        cancelProjectScan()
        stopProjectMonitor()
        let closedName = projectDirectoryURL?.lastPathComponent
        releaseProjectSecurityScope()
        projectDirectoryURL = nil
        projectFiles = []
        projectEntries = []
        UserDefaults.standard.removeObject(forKey: lastProjectPathKey)
        UserDefaults.standard.removeObject(forKey: lastProjectBookmarkKey)
        if let selectedProjectFile {
            projectName = selectedProjectFile.url.deletingPathExtension().lastPathComponent
            lastBuildText = "正在编辑 \(selectedProjectFile.name)"
            rememberCurrentSelection(selectedProjectFile)
        } else {
            projectName = "未命名程序"
            lastBuildText = "尚未打开源码"
            UserDefaults.standard.removeObject(forKey: lastProjectPathKey)
        }
        if let closedName {
            appendBuildLog("已关闭文件夹：\(closedName)")
        }
    }

    func reportUnsupportedWorkspaceFile(_ entry: WorkspaceEntry) {
        showAlert(
            "当前不可编辑",
            "\(entry.name) 已显示在资源管理器中，但当前编辑器只编辑 .c 和 .h 文件。"
        )
    }

    func openProjectFile(_ file: ProjectFile) {
        guard ["c", "h"].contains(file.fileExtension) else {
            showAlert("只读工程文件", "\(file.name) 会参与工程配置，但当前编辑器只编辑 C 和头文件。")
            return
        }

        guard fileSize(file.url) <= ResourceLimits.maximumSourceBytes else {
            showAlert("源码文件过大", "为防止内存异常，代码编辑器最多打开 1,000,000 字节的单个源码文件。")
            return
        }

        do {
            sourceCode = try String(contentsOf: file.url, encoding: .utf8)
            sourceFileName = file.name
            selectedProjectFile = file
            selectedSourceSnapshot = sourceFileSnapshot(for: file.url)
            rememberOpenFile(file)
            if projectDirectoryURL == nil {
                projectName = file.url.deletingPathExtension().lastPathComponent
            }
            sourceIsDirty = false
            invalidateCompiledFirmware()
            lastBuildText = "正在编辑 \(file.name)"
            rememberCurrentSelection(file)
        } catch {
            showAlert("无法打开源码", error.localizedDescription)
        }
    }

    func newSource() {
        sourceCode = ""
        sourceFileName = "main.c"
        if projectDirectoryURL == nil {
            projectName = "未命名程序"
        }
        selectedProjectFile = nil
        selectedSourceSnapshot = nil
        sourceIsDirty = false
        invalidateCompiledFirmware()
        buildErrorCount = 0
        buildWarningCount = 0
        lastBuildDuration = 0
        lastBuildText = "已新建空白 C 程序"
        appendBuildLog("已新建空白 C 程序。")
    }

    func markSourceDirty() {
        if isCompiling {
            buildTask?.cancel()
            activeBuildController?.cancel(
                forceTerminationGrace: ResourceLimits.forceTerminationGrace
            )
            progress = 0
            operationText = "代码已修改，正在停止旧编译"
            lastBuildText = "代码已修改，正在停止旧编译"
            appendBuildLog("编译期间代码发生修改，正在停止旧编译进程。")
        } else if hasFreshBuild || !sourceIsDirty {
            lastBuildText = "代码已修改，请重新编译"
        }
        sourceEditGeneration &+= 1
        sourceIsDirty = true
        invalidateCompiledFirmware()
    }

    @discardableResult
    func saveCurrentSource(allowExternalOverwrite: Bool = false) -> Bool {
        guard let selectedProjectFile else { return false }
        guard allowExternalOverwrite || !currentSourceHasExternalChanges else {
            showAlert(
                "磁盘上的源码已经变化",
                "为防止覆盖访达、其他编辑器或 AI 的修改，本次保存已停止。"
                    + "请点击“保存”并选择另存为，或确认仍要覆盖。"
            )
            return false
        }
        guard sourceCode.utf8.count <= Int(ResourceLimits.maximumSourceBytes) else {
            showAlert("源码过大", "为防止异常资源占用，保存的源码不能超过 1,000,000 字节。")
            return false
        }
        do {
            try sourceCode.write(to: selectedProjectFile.url, atomically: true, encoding: .utf8)
            selectedSourceSnapshot = sourceFileSnapshot(for: selectedProjectFile.url)
            sourceIsDirty = false
            lastBuildText = "已保存 \(selectedProjectFile.name)"
            appendBuildLog("已保存源码：\(selectedProjectFile.url.path)")
            rememberOpenFile(selectedProjectFile)
            rememberCurrentSelection(selectedProjectFile)
            return true
        } catch {
            showAlert("无法保存源码", error.localizedDescription)
            return false
        }
    }

    func openSource(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        guard fileSize(url) <= ResourceLimits.maximumSourceBytes else {
            showAlert("源码文件过大", "为防止内存异常，代码编辑器最多打开 1,000,000 字节的单个源码文件。")
            return
        }

        do {
            sourceCode = try String(contentsOf: url, encoding: .utf8)
            sourceFileName = url.lastPathComponent
            let file = ProjectFile(url: url)
            selectedProjectFile = file
            selectedSourceSnapshot = sourceFileSnapshot(for: url)
            rememberOpenFile(file)
            if projectDirectoryURL == nil {
                projectName = url.deletingPathExtension().lastPathComponent
            }
            sourceIsDirty = false
            invalidateCompiledFirmware()
            lastBuildText = "已打开 \(url.lastPathComponent)"
            appendBuildLog("已打开源码：\(url.path)")
            rememberCurrentSelection(file)
        } catch {
            showAlert("无法打开源码", error.localizedDescription)
        }
    }

    @discardableResult
    func saveSource(_ url: URL) -> Bool {
        guard sourceCode.utf8.count <= Int(ResourceLimits.maximumSourceBytes) else {
            showAlert("源码过大", "为防止异常资源占用，保存的源码不能超过 1,000,000 字节。")
            return false
        }
        do {
            try sourceCode.write(to: url, atomically: true, encoding: .utf8)
            sourceFileName = url.lastPathComponent
            if projectDirectoryURL == nil {
                projectName = url.deletingPathExtension().lastPathComponent
            }
            let file = ProjectFile(url: url)
            selectedProjectFile = file
            selectedSourceSnapshot = sourceFileSnapshot(for: url)
            rememberOpenFile(file)
            sourceIsDirty = false
            lastBuildText = "源码已保存"
            appendBuildLog("源码已保存：\(url.path)")
            rememberCurrentSelection(file)
            if let projectDirectoryURL,
               WorkspacePathSafety.isWithinProject(
                   url,
                   projectRoot: projectDirectoryURL,
                   allowRoot: false
               ) {
                refreshProjectFiles()
            }
            return true
        } catch {
            showAlert("无法保存源码", error.localizedDescription)
            return false
        }
    }

    func closeOpenFile(_ file: ProjectFile) {
        let wasSelected = selectedProjectFile == file
        openFiles.removeAll {
            $0.url.standardizedFileURL.path == file.url.standardizedFileURL.path
        }
        guard wasSelected else { return }

        if let replacement = openFiles.last {
            openProjectFile(replacement)
        } else {
            newSource()
        }
    }

    private func rememberOpenFile(_ file: ProjectFile) {
        guard !openFiles.contains(where: {
            $0.url.standardizedFileURL.path == file.url.standardizedFileURL.path
        }) else {
            return
        }
        openFiles.append(file)
        if openFiles.count > ResourceLimits.maximumOpenEditors {
            openFiles.removeFirst(openFiles.count - ResourceLimits.maximumOpenEditors)
        }
    }

    private func startProjectScan(
        directory: URL,
        isRefresh: Bool,
        preferredSourcePath: String?
    ) {
        guard !isDetecting, !isFlashing, !isCompiling else {
            showAlert("当前操作尚未结束", "请等待检测、编译或烧录完成后再打开文件夹。")
            return
        }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            showAlert("无法打开文件夹", "所选路径不存在或不是文件夹。")
            return
        }

        cancelProjectScan()
        let scanID = UUID()
        let editGenerationAtStart = sourceEditGeneration
        activeProjectScanID = scanID
        isScanningProject = true
        lastBuildText = isRefresh ? "正在刷新文件夹" : "正在扫描文件夹"

        let worker = Task.detached(priority: .userInitiated) {
            WorkspaceScanner.scan(
                directory: directory,
                maximumEntries: ResourceLimits.maximumProjectEntries
            )
        }
        projectScanWorker = worker
        projectScanTask = Task { [weak self] in
            let result = await worker.value

            guard let self,
                  self.activeProjectScanID == scanID
            else {
                return
            }

            self.projectScanTask = nil
            self.projectScanWorker = nil
            self.activeProjectScanID = nil
            self.isScanningProject = false
            defer { self.performBootstrapProbeDetectionIfIdle() }
            guard !result.isCancelled else { return }

            self.finishProjectScan(
                result,
                directory: directory,
                isRefresh: isRefresh,
                preferredSourcePath: preferredSourcePath,
                editGenerationAtStart: editGenerationAtStart
            )
        }
    }

    private func cancelProjectScan() {
        projectScanTask?.cancel()
        projectScanWorker?.cancel()
        projectScanTask = nil
        projectScanWorker = nil
        activeProjectScanID = nil
        isScanningProject = false
    }

    private func finishProjectScan(
        _ result: WorkspaceScanResult,
        directory: URL,
        isRefresh: Bool,
        preferredSourcePath: String?,
        editGenerationAtStart: UInt64
    ) {
        if !isRefresh, sourceEditGeneration != editGenerationAtStart {
            lastBuildText = "代码已修改，已取消切换工程"
            appendBuildLog("已取消切换工程：扫描期间当前代码发生了修改。")
            showAlert(
                "没有切换工程",
                "扫描文件夹期间当前代码发生了修改。为防止丢失输入，软件保留了原来的编辑内容。"
            )
            return
        }

        if result.isTruncated {
            let message = "该文件夹超过 2,000 项安全上限。为防止漏编译或误判文件已删除，"
                + "软件没有载入这份不完整列表；请选择更具体的工程子文件夹。"
            lastBuildText = "文件夹项目过多，未载入不完整结果"
            appendBuildLog("⚠ \(message)")
            showAlert("文件夹过大", message)
            return
        }

        if result.failureCount > 0 {
            let retainedDetails = result.issues.prefix(3).map { issue in
                "\(issue.path)：\(issue.message)"
            }.joined(separator: "\n")
            let detailSuffix = retainedDetails.isEmpty ? "" : "\n\n部分错误：\n\(retainedDetails)"
            let message = "读取文件夹时遇到 \(result.failureCount) 个文件系统错误。"
                + "为防止漏编译或把文件误判为已删除，软件没有载入这份不完整列表。"
                + detailSuffix
            lastBuildText = "文件夹读取不完整，未载入"
            appendBuildLog("⚠ \(message)")
            showAlert("文件夹读取失败", message)
            return
        }

        let sourceFiles = result.entries
            .filter {
                !$0.isDirectory && ["c", "h", "s", "ld"].contains($0.fileExtension)
            }
            .map { ProjectFile(url: $0.url) }
            .sorted {
                let leftIsMain = $0.name.lowercased() == "main.c"
                let rightIsMain = $1.name.lowercased() == "main.c"
                if leftIsMain != rightIsMain {
                    return leftIsMain
                }
                return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
            }

        if isRefresh {
            guard projectDirectoryURL?.standardizedFileURL.path
                    == directory.standardizedFileURL.path
            else {
                return
            }
            projectEntries = result.entries
            projectFiles = sourceFiles
            lastBuildText = "文件列表已刷新"
            reconcileOpenEditorsAfterRefresh(
                entries: result.entries,
                sourceFiles: sourceFiles,
                projectRoot: directory
            )
            appendBuildLog("已刷新工程文件：\(result.entries.count) 项")
            return
        }

        openFiles = []
        selectedProjectFile = nil
        selectedSourceSnapshot = nil
        sourceCode = ""
        sourceFileName = "main.c"
        sourceIsDirty = false
        invalidateCompiledFirmware()
        projectDirectoryURL = directory
        projectName = directory.lastPathComponent
        projectEntries = result.entries
        projectFiles = sourceFiles
        rememberProject(directory)

        let preferredURL = preferredSourcePath.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        if let preferredURL,
           FileManager.default.fileExists(atPath: preferredURL.path) {
            if let matching = sourceFiles.first(where: {
                $0.url.standardizedFileURL.path == preferredURL.path
                    && ["c", "h"].contains($0.fileExtension)
            }) {
                openProjectFile(matching)
            } else {
                openSource(preferredURL)
            }
        } else if let firstEditable = sourceFiles.first(where: {
            ["c", "h"].contains($0.fileExtension)
        }) {
            openProjectFile(firstEditable)
        } else {
            newSource()
            lastBuildText = "空工程已打开，可在资源管理器中新建 C 文件"
        }

        if isEditingProjectFile {
            lastBuildText = "已打开工程 \(projectName)"
        }
        appendBuildLog(
            "已打开工程：\(directory.path)（\(result.entries.count) 项，"
                + "\(sourceFiles.count) 个工程文件）"
        )
        startProjectMonitor(for: directory)
    }

    private func reconcileOpenEditorsAfterRefresh(
        entries: [WorkspaceEntry],
        sourceFiles: [ProjectFile],
        projectRoot: URL
    ) {
        let rootURL = WorkspacePathSafety.canonical(projectRoot)
        let existingFilePaths = Set(entries.lazy.filter { !$0.isDirectory }.map {
            WorkspacePathSafety.canonical($0.url).path
        })
        let selectedPath = selectedProjectFile.map {
            WorkspacePathSafety.canonical($0.url).path
        }
        let selectedIsMissing = selectedPath.map {
            WorkspacePathSafety.isWithinProject(
                URL(fileURLWithPath: $0),
                projectRoot: rootURL,
                allowRoot: false
            ) && !existingFilePaths.contains($0)
        } ?? false

        openFiles.removeAll { file in
            let path = WorkspacePathSafety.canonical(file.url).path
            guard WorkspacePathSafety.isWithinProject(
                file.url,
                projectRoot: rootURL,
                allowRoot: false
            ), !existingFilePaths.contains(path) else {
                return false
            }
            return !(sourceIsDirty && path == selectedPath)
        }

        guard selectedIsMissing else { return }
        if sourceIsDirty {
            lastBuildText = "源文件已从磁盘移除，未保存修改仍保留"
            appendBuildLog("⚠ 当前源码已从磁盘移除；编辑器内容仍保留，保存可重新创建该文件。")
            return
        }

        selectedProjectFile = nil
        selectedSourceSnapshot = nil
        if let replacement = sourceFiles.first(where: {
            ["c", "h"].contains($0.fileExtension)
        }) {
            openProjectFile(replacement)
        } else {
            newSource()
            lastBuildText = "工程中暂无 C/H 文件"
        }
    }

    private func rememberProject(_ directory: URL) {
        let defaults = UserDefaults.standard
        let projectPath = directory.standardizedFileURL.path
        defaults.set("project", forKey: lastWorkspaceKindKey)
        defaults.set(projectPath, forKey: lastProjectPathKey)
        recentProjectPaths.removeAll { $0 == projectPath }
        recentProjectPaths.insert(projectPath, at: 0)
        if recentProjectPaths.count > 8 {
            recentProjectPaths.removeLast(recentProjectPaths.count - 8)
        }
        defaults.set(recentProjectPaths, forKey: recentProjectPathsKey)
        do {
            let bookmark = try directory.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: lastProjectBookmarkKey)
        } catch {
            appendBuildLog("⚠ 未能保存工程文件夹权限：\(error.localizedDescription)")
        }
    }

    private func retainSecurityScope(for directory: URL) {
        let canonicalURL = directory.standardizedFileURL
        if projectSecurityScopedURL?.standardizedFileURL.path == canonicalURL.path {
            return
        }
        releaseProjectSecurityScope()
        if canonicalURL.startAccessingSecurityScopedResource() {
            projectSecurityScopedURL = canonicalURL
        }
    }

    private func releaseProjectSecurityScope() {
        projectSecurityScopedURL?.stopAccessingSecurityScopedResource()
        projectSecurityScopedURL = nil
    }

    func openRecentProject(atPath path: String) {
        guard !isBusy else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            recentProjectPaths.removeAll { $0 == path }
            UserDefaults.standard.set(recentProjectPaths, forKey: recentProjectPathsKey)
            showAlert("工程不存在", "这个最近工程已经移动或删除，已从列表中移除。")
            return
        }
        openProject(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func startProjectMonitor(for directory: URL) {
        stopProjectMonitor()
        let descriptor = Darwin.open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let monitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )
        monitor.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleProjectMonitorRefresh()
            }
        }
        monitor.setCancelHandler {
            Darwin.close(descriptor)
        }
        projectMonitor = monitor
        monitor.resume()
    }

    private func scheduleProjectMonitorRefresh() {
        projectMonitorRefreshTask?.cancel()
        projectMonitorRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.isBusy {
                self.scheduleProjectMonitorRefresh()
            } else {
                self.refreshProjectFiles()
            }
        }
    }

    private func stopProjectMonitor() {
        projectMonitorRefreshTask?.cancel()
        projectMonitorRefreshTask = nil
        projectMonitor?.cancel()
        projectMonitor = nil
    }

    private func rememberCurrentSelection(_ file: ProjectFile) {
        let defaults = UserDefaults.standard
        defaults.set(file.url.standardizedFileURL.path, forKey: lastSourcePathKey)
        if let projectDirectoryURL {
            defaults.set("project", forKey: lastWorkspaceKindKey)
            defaults.set(projectDirectoryURL.standardizedFileURL.path, forKey: lastProjectPathKey)
        } else {
            defaults.set("source", forKey: lastWorkspaceKindKey)
        }
    }

    private func restoreLastWorkspace() {
        let defaults = UserDefaults.standard
        let fileManager = FileManager.default
        let sourcePath = defaults.string(forKey: lastSourcePathKey)

        if let bookmark = defaults.data(forKey: lastProjectBookmarkKey) {
            var isStale = false
            do {
                let directory = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                retainSecurityScope(for: directory)
                if fileManager.fileExists(atPath: directory.path) {
                    if isStale {
                        rememberProject(directory)
                    }
                    startProjectScan(
                        directory: directory,
                        isRefresh: false,
                        preferredSourcePath: sourcePath
                    )
                    return
                }
            } catch {
                appendBuildLog("⚠ 上次的工程权限已失效，尝试从原路径恢复。")
            }
            defaults.removeObject(forKey: lastProjectBookmarkKey)
            releaseProjectSecurityScope()
        }

        if let projectPath = defaults.string(forKey: lastProjectPathKey) {
            if fileManager.fileExists(atPath: projectPath) {
                let directory = URL(fileURLWithPath: projectPath, isDirectory: true)
                retainSecurityScope(for: directory)
                startProjectScan(
                    directory: directory,
                    isRefresh: false,
                    preferredSourcePath: sourcePath
                )
                return
            }
            defaults.removeObject(forKey: lastProjectPathKey)
        }

        if let sourcePath, fileManager.fileExists(atPath: sourcePath) {
            openSource(URL(fileURLWithPath: sourcePath))
        }
    }

    func clearBuildLog() {
        buildLog = "编译日志已清空。\n"
        buildIssues = []
    }

    func cleanBuild() {
        guard !isBusy else { return }
        let workspace = buildWorkspaceURL
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: workspace.path) {
                try fileManager.removeItem(at: workspace)
            }
            firmwareURL = nil
            hasFreshBuild = false
            flashUsed = 0
            ramUsed = 0
            buildErrorCount = 0
            buildWarningCount = 0
            buildIssues = []
            lastBuildDuration = 0
            lastBuildText = "工程已清理"
            appendBuildLog("✓ Clean：已删除目标文件、HEX、BIN、ELF 和 MAP。")
        } catch {
            showAlert("清理失败", error.localizedDescription)
        }
    }

    func rebuild(flashAfterBuild: Bool = false) {
        cleanBuild()
        compileSource(flashAfterBuild: flashAfterBuild)
    }

    /// Imports the current clipboard into the open C source, then compiles and
    /// flashes only if the compilation succeeds. The normal flash path still
    /// performs its probe and target-ID verification before erase/download.
    func importClipboardAndBuildAndFlash() {
        guard let unavailableReason = aiOneClickUnavailableReason else {
            guard let rawClipboardText = NSPasteboard.general.string(forType: .string) else {
                showAlert("剪贴板没有代码", "请先复制 AI 生成的 C 代码，再点击右上角火箭按钮。")
                return
            }

            let importedSource = ClipboardCSource.normalized(from: rawClipboardText)
            guard !importedSource.isEmpty else {
                showAlert("剪贴板没有代码", "剪贴板中的文本为空，未替换当前源码。")
                return
            }
            guard importedSource.utf8.count <= Int(ResourceLimits.maximumSourceBytes) else {
                showAlert("源码过大", "剪贴板代码超过 1,000,000 字节安全上限，未导入。")
                return
            }

            sourceCode = importedSource
            markSourceDirty()
            appendBuildLog("已从剪贴板导入 AI 代码：\(sourceFileName)")
            operationText = "已导入 AI 代码，准备编译"
            compileSource(flashAfterBuild: true)
            return
        }

        showAlert("暂时不能一键烧录", unavailableReason)
    }

    func revealBuildFolder() {
        let workspace = buildWorkspaceURL
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([workspace])
    }

    func resetTarget() {
        guard let cliURL, hasCLI, !isBusy else { return }
        isDetecting = true
        probeStatus = .busy
        operationText = "正在复位目标芯片"
        appendLog("发送硬件复位命令…")
        run(
            cliURL: cliURL,
            arguments: ["-c", "port=SWD", "mode=UR", "reset=HWrst", "freq=\(swdFrequency)", "-rst"],
            timeout: ResourceLimits.resetCommandTimeout
        ) { [weak self] result in
            guard let self else { return }
            self.isDetecting = false
            self.appendLog(result.output)
            if result.exitCode == 0,
               !STM32ProgrammerOutputValidator.containsFailureEvidence(result.output) {
                self.probeStatus = .connected
                self.operationText = "目标芯片已复位"
                self.appendLog("✓ Reset：芯片已重新运行。")
            } else {
                self.probeStatus = .failed
                self.operationText = "复位失败"
                self.showAlert("复位失败", self.friendlyFailureMessage(result.output))
            }
        }
    }

    func compileSource(flashAfterBuild: Bool = false) {
        guard let compilerURL, let objcopyURL, let sizeToolURL, canCompile else {
            showAlert("无法编译", "没有找到 ARM GCC，或代码内容为空。")
            return
        }
        guard
            let startupURL = Bundle.main.url(
                forResource: "startup_stm32f103c8t6",
                withExtension: "s",
                subdirectory: "Toolchain"
            ),
            let linkerURL = Bundle.main.url(
                forResource: "stm32f103c8t6",
                withExtension: "ld",
                subdirectory: "Toolchain"
            )
        else {
            showAlert("编译资源缺失", "应用内没有找到 STM32F103C8T6 启动文件或链接脚本。")
            return
        }

        let fileManager = FileManager.default
        guard !currentSourceHasExternalChanges else {
            showAlert(
                "编译已停止",
                "磁盘上的当前源码已被其他程序修改。为防止编辑器内容和实际编译内容不一致，"
                    + "请先使用“保存”处理冲突，或关闭后重新打开该文件。"
            )
            return
        }
        if sourceIsDirty, selectedProjectFile != nil {
            guard saveCurrentSource() else {
                lastBuildText = "保存失败，已取消编译"
                appendBuildLog("✗ 保存失败，为避免编译旧代码，本次编译已取消。")
                return
            }
        }

        let workspace = buildWorkspaceURL
        firmwareURL = nil
        hasFreshBuild = false
        let mainURL = workspace.appendingPathComponent("main.c")
        let startupObjectURL = workspace.appendingPathComponent("startup.o")
        let elfURL = workspace.appendingPathComponent("firmware.elf")
        let hexURL = workspace.appendingPathComponent("firmware.hex")
        let binURL = workspace.appendingPathComponent("firmware.bin")
        let mapURL = workspace.appendingPathComponent("firmware.map")
        let buildsProject = isEditingProjectFile
        let projectSources = buildsProject
            ? projectFiles.filter { $0.fileExtension == "c" }.map(\.url)
            : []
        let sourceURLs = buildsProject ? projectSources : [mainURL]

        if !buildsProject {
            guard Int64(sourceCode.utf8.count) <= ResourceLimits.maximumSourceBytes else {
                showAlert("源码内容过大", "单文件编译上限为 1,000,000 字节。")
                return
            }
        } else {
            guard projectSources.count <= ResourceLimits.maximumCompileSources else {
                showAlert("工程文件过多", "单次最多编译 128 个 C 源文件。")
                return
            }
            guard projectSources.allSatisfy({ fileSize($0) <= ResourceLimits.maximumSourceBytes }) else {
                showAlert("工程源码过大", "工程中存在超过 1,000,000 字节的单个 C 源文件。")
                return
            }
        }

        var includeDirectories: [URL] = []
        if buildsProject, let projectDirectoryURL {
            includeDirectories.append(projectDirectoryURL)
            includeDirectories += projectFiles
                .filter { $0.fileExtension == "h" }
                .map { $0.url.deletingLastPathComponent() }
        } else if let selectedProjectFile {
            includeDirectories.append(selectedProjectFile.url.deletingLastPathComponent())
        }

        let uniqueIncludeDirectories = Dictionary(
            grouping: includeDirectories,
            by: { $0.standardizedFileURL.path }
        )
        .values
        .compactMap(\.first)
        .sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }

        guard uniqueIncludeDirectories.count <= ResourceLimits.maximumIncludeDirectories else {
            showAlert("头文件目录过多", "单次编译最多使用 128 个头文件目录。")
            return
        }

        do {
            try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
            if !buildsProject {
                try sourceCode.write(to: mainURL, atomically: true, encoding: .utf8)
            }
            let oldObjects = (try? fileManager.contentsOfDirectory(
                at: workspace,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "o" }) ?? []
            for staleURL in oldObjects + [elfURL, hexURL, binURL, mapURL]
                where fileManager.fileExists(atPath: staleURL.path) {
                try fileManager.removeItem(at: staleURL)
            }
        } catch {
            showAlert("无法准备编译", error.localizedDescription)
            return
        }

        let buildStartedAt = Date()
        isCompiling = true
        progress = 0.10
        operationText = "正在编译 C 代码"
        lastBuildText = "正在编译"
        buildErrorCount = 0
        buildWarningCount = 0
        buildIssues = []
        appendBuildLog("────────────────────────")
        let buildTargetName = buildsProject
            ? projectName
            : URL(fileURLWithPath: sourceFileName).deletingPathExtension().lastPathComponent
        appendBuildLog("Build target '\(buildTargetName)'")

        var commonFlags = [
            "-mcpu=cortex-m3",
            "-mthumb",
            optimizationLevel.compilerFlag,
            "-ffreestanding",
            "-fdata-sections",
            "-ffunction-sections",
            "-Wall",
            "-Wextra"
        ]
        if warningsAsErrors {
            commonFlags.append("-Werror")
        }
        for includeDirectory in uniqueIncludeDirectories {
            commonFlags += ["-I", includeDirectory.path]
        }

        let buildID = UUID()
        let processController = ProcessController()
        activeBuildID = buildID
        activeBuildController = processController
        buildTask = Task.detached(priority: .userInitiated) {
            await withTaskCancellationHandler(operation: {
                var combinedOutput = BoundedTextAccumulator(
                    maximumCharacters: ResourceLimits.maximumAggregateBuildOutputCharacters
                )
                var objectURLs: [URL] = []

                for (index, sourceURL) in sourceURLs.enumerated() {
                    if Self.buildCancellationRequested(processController) {
                        await self.finishCompilationCancellation(buildID: buildID)
                        return
                    }
                    let safeName = sourceURL.deletingPathExtension().lastPathComponent
                        .replacingOccurrences(
                            of: "[^A-Za-z0-9_-]",
                            with: "_",
                            options: .regularExpression
                        )
                    let objectURL = workspace.appendingPathComponent("\(index)_\(safeName).o")
                    let result = Self.executeCommand(
                        compilerURL,
                        commonFlags + ["-c", sourceURL.path, "-o", objectURL.path],
                        controller: processController
                    )
                    combinedOutput.append("$ Compile \(sourceURL.lastPathComponent)\n\(result.output)\n")
                    if Self.buildCancellationRequested(processController) {
                        await self.finishCompilationCancellation(buildID: buildID)
                        return
                    }
                    guard result.exitCode == 0 else {
                        await self.finishCompilation(
                            buildID: buildID,
                            success: false,
                            output: combinedOutput.text,
                            firmwareURL: nil,
                            flashAfterBuild: false,
                            flashBytes: 0,
                            ramBytes: 0,
                            duration: Date().timeIntervalSince(buildStartedAt)
                        )
                        return
                    }
                    objectURLs.append(objectURL)
                }

                let startupResult = Self.executeCommand(
                    compilerURL,
                    commonFlags + ["-c", startupURL.path, "-o", startupObjectURL.path],
                    controller: processController
                )
                combinedOutput.append("$ 编译 startup\n\(startupResult.output)\n")
                if Self.buildCancellationRequested(processController) {
                    await self.finishCompilationCancellation(buildID: buildID)
                    return
                }
                guard startupResult.exitCode == 0 else {
                    await self.finishCompilation(
                        buildID: buildID,
                        success: false,
                        output: combinedOutput.text,
                        firmwareURL: nil,
                        flashAfterBuild: false,
                        flashBytes: 0,
                        ramBytes: 0,
                        duration: Date().timeIntervalSince(buildStartedAt)
                    )
                    return
                }

                let linkArguments = commonFlags + [
                    "-T", linkerURL.path,
                    "-nostdlib",
                    "-Wl,--gc-sections",
                    "-Wl,-Map=\(mapURL.path)",
                    startupObjectURL.path,
                ] + objectURLs.map(\.path) + [
                    "-o", elfURL.path
                ]
                let linkResult = Self.executeCommand(
                    compilerURL,
                    linkArguments,
                    controller: processController
                )
                combinedOutput.append("$ 链接 firmware.elf\n\(linkResult.output)\n")
                if Self.buildCancellationRequested(processController) {
                    await self.finishCompilationCancellation(buildID: buildID)
                    return
                }
                guard linkResult.exitCode == 0 else {
                    await self.finishCompilation(
                        buildID: buildID,
                        success: false,
                        output: combinedOutput.text,
                        firmwareURL: nil,
                        flashAfterBuild: false,
                        flashBytes: 0,
                        ramBytes: 0,
                        duration: Date().timeIntervalSince(buildStartedAt)
                    )
                    return
                }

                let hexResult = Self.executeCommand(
                    objcopyURL,
                    ["-O", "ihex", elfURL.path, hexURL.path],
                    controller: processController
                )
                combinedOutput.append("$ 生成 firmware.hex\n\(hexResult.output)\n")
                if Self.buildCancellationRequested(processController) {
                    await self.finishCompilationCancellation(buildID: buildID)
                    return
                }
                guard hexResult.exitCode == 0 else {
                    await self.finishCompilation(
                        buildID: buildID,
                        success: false,
                        output: combinedOutput.text,
                        firmwareURL: nil,
                        flashAfterBuild: false,
                        flashBytes: 0,
                        ramBytes: 0,
                        duration: Date().timeIntervalSince(buildStartedAt)
                    )
                    return
                }

                let binResult = Self.executeCommand(
                    objcopyURL,
                    ["-O", "binary", elfURL.path, binURL.path],
                    controller: processController
                )
                combinedOutput.append("$ 生成 firmware.bin\n\(binResult.output)\n")
                if Self.buildCancellationRequested(processController) {
                    await self.finishCompilationCancellation(buildID: buildID)
                    return
                }
                guard binResult.exitCode == 0 else {
                    await self.finishCompilation(
                        buildID: buildID,
                        success: false,
                        output: combinedOutput.text,
                        firmwareURL: nil,
                        flashAfterBuild: false,
                        flashBytes: 0,
                        ramBytes: 0,
                        duration: Date().timeIntervalSince(buildStartedAt)
                    )
                    return
                }

                let sizeResult = Self.executeCommand(
                    sizeToolURL,
                    [elfURL.path],
                    controller: processController
                )
                combinedOutput.append("$ Program Size\n\(sizeResult.output)\n")
                if Self.buildCancellationRequested(processController) {
                    await self.finishCompilationCancellation(buildID: buildID)
                    return
                }
                guard sizeResult.exitCode == 0 else {
                    await self.finishCompilation(
                        buildID: buildID,
                        success: false,
                        output: combinedOutput.text,
                        firmwareURL: nil,
                        flashAfterBuild: false,
                        flashBytes: 0,
                        ramBytes: 0,
                        duration: Date().timeIntervalSince(buildStartedAt)
                    )
                    return
                }
                let memory = Self.parseProgramSize(sizeResult.output)

                await self.finishCompilation(
                    buildID: buildID,
                    success: true,
                    output: combinedOutput.text,
                    firmwareURL: hexURL,
                    flashAfterBuild: flashAfterBuild,
                    flashBytes: memory.flash,
                    ramBytes: memory.ram,
                    duration: Date().timeIntervalSince(buildStartedAt)
                )
            }, onCancel: {
                processController.cancel(
                    forceTerminationGrace: ResourceLimits.forceTerminationGrace
                )
            })
        }
    }

    private var buildWorkspaceURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("STM32Flasher", isDirectory: true)
            .appendingPathComponent("Workspace", isDirectory: true)
    }

    private var normalizedAddress: String {
        let raw = binaryAddress.lowercased().replacingOccurrences(of: "0x", with: "")
        return "0x\(raw.uppercased())"
    }

    private func invalidateCompiledFirmware() {
        firmwareURL = nil
        hasFreshBuild = false
        flashUsed = 0
        ramUsed = 0
    }

    private func validateFirmwareBeforeFlash(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            showAlert("找不到固件", "固件文件已被移动或删除，请重新选择。")
            return false
        }

        let size = fileSize(url)
        guard size > 0, size <= ResourceLimits.maximumFirmwareBytes else {
            showAlert("固件无效", "固件为空、无法读取，或已超过 16 MiB 上限，请重新选择。")
            return false
        }

        if isBinaryFirmware && !isValidAddress {
            showAlert("写入地址无效", "STM32F103C8T6 的第一版允许地址范围为 0x08000000～0x0800FFFF。")
            return false
        }
        if isBinaryFirmware,
           let address = parsedBinaryAddress,
           !FirmwareFlashValidator.binaryRangeIsValid(startAddress: address, byteCount: size) {
            showAlert(
                "BIN 写入区间越界",
                "BIN 的起始地址加文件长度不能超过 0x08010000（64 KiB Flash 末端）。"
            )
            return false
        }
        return true
    }

    private func finishCompilation(
        buildID: UUID,
        success: Bool,
        output: String,
        firmwareURL: URL?,
        flashAfterBuild: Bool,
        flashBytes: Int,
        ramBytes: Int,
        duration: TimeInterval
    ) {
        guard activeBuildID == buildID else { return }
        activeBuildID = nil
        buildTask = nil
        activeBuildController = nil
        isCompiling = false
        progress = success ? 1 : 0
        appendBuildLogBlock(output)
        buildIssues = Self.parseBuildIssues(output)
        buildErrorCount = output.components(separatedBy: .newlines)
            .filter { $0.localizedCaseInsensitiveContains("error:") }
            .count
        buildWarningCount = output.components(separatedBy: .newlines)
            .filter { $0.localizedCaseInsensitiveContains("warning:") }
            .count
        flashUsed = flashBytes
        ramUsed = ramBytes
        lastBuildDuration = duration

        if success, let firmwareURL {
            self.firmwareURL = firmwareURL
            hasFreshBuild = true
            operationText = "编译完成"
            lastBuildText = "0 Error(s), \(buildWarningCount) Warning(s) · \(String(format: "%.2f", duration)) 秒"
            appendBuildLog("✓ 编译成功：\(firmwareURL.path)")
            appendBuildLog("Program Size: Flash=\(flashBytes) B, RAM=\(ramBytes) B")
            appendBuildLog("0 Error(s), \(buildWarningCount) Warning(s)")
            appendLog("代码编译成功，已载入固件：\(firmwareURL.lastPathComponent)")
            if flashAfterBuild {
                flash()
            } else {
                showAlert(
                    "编译成功",
                    "0 个错误，\(buildWarningCount) 个警告。\nFlash \(flashBytes) B，RAM \(ramBytes) B。\nfirmware.hex 已载入烧录区。"
                )
            }
        } else {
            self.firmwareURL = nil
            hasFreshBuild = false
            operationText = "编译失败"
            lastBuildText = "\(buildErrorCount) Error(s), \(buildWarningCount) Warning(s)"
            appendBuildLog("✗ 编译失败。请检查日志中的行号和错误信息。")
            NSSound(named: "Basso")?.play()
            showAlert("编译失败", "C 代码没有通过 ARM GCC 编译，请查看编译日志。")
        }
    }

    private func finishCompilationCancellation(buildID: UUID) {
        guard activeBuildID == buildID else { return }
        activeBuildID = nil
        buildTask = nil
        activeBuildController = nil
        isCompiling = false
        progress = 0
        firmwareURL = nil
        hasFreshBuild = false
        flashUsed = 0
        ramUsed = 0

        if sourceIsDirty {
            operationText = "代码已修改，旧编译已停止"
            lastBuildText = "代码已修改，请重新编译"
            appendBuildLog("✓ 旧编译进程已停止；修改后的代码尚未编译。")
        } else {
            operationText = "编译已停止"
            lastBuildText = "编译已停止"
            appendBuildLog("✓ 编译进程已停止。")
        }
    }

    nonisolated private static func buildCancellationRequested(
        _ controller: ProcessController
    ) -> Bool {
        controller.isCancelled || Task.isCancelled
    }

    nonisolated private static func parseProgramSize(_ output: String) -> (flash: Int, ram: Int) {
        for line in output.components(separatedBy: .newlines).reversed() {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 3,
                  let text = Int(columns[0]),
                  let data = Int(columns[1]),
                  let bss = Int(columns[2])
            else { continue }
            return (flash: text + data, ram: data + bss)
        }
        return (0, 0)
    }

    nonisolated private static func parseBuildIssues(_ output: String) -> [BuildIssue] {
        let pattern = #"^(.+?):([0-9]+):([0-9]+):\s*(fatal error|error|warning|note):\s*(.+)$"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.anchorsMatchLines]
        ) else {
            return []
        }

        let source = output as NSString
        let matches = expression.matches(
            in: output,
            range: NSRange(location: 0, length: source.length)
        )
        return matches.prefix(200).compactMap { match in
            guard match.numberOfRanges == 6,
                  let line = Int(source.substring(with: match.range(at: 2))),
                  let column = Int(source.substring(with: match.range(at: 3)))
            else {
                return nil
            }
            let severityText = source.substring(with: match.range(at: 4))
            let severity: BuildIssueSeverity = severityText.contains("error")
                ? .error
                : (severityText == "warning" ? .warning : .note)
            return BuildIssue(
                fileURL: URL(fileURLWithPath: source.substring(with: match.range(at: 1))),
                line: line,
                column: column,
                severity: severity,
                message: source.substring(with: match.range(at: 5))
            )
        }
    }

    func navigateToBuildIssue(_ issue: BuildIssue) {
        let issueURL = issue.fileURL.standardizedFileURL
        let workspaceMainURL = buildWorkspaceURL
            .appendingPathComponent("main.c")
            .standardizedFileURL

        if issueURL.path == workspaceMainURL.path, selectedProjectFile == nil {
            requestSourceLine(issue.line)
            return
        }

        guard FileManager.default.fileExists(atPath: issueURL.path) else {
            showAlert("找不到源码", "报错对应的文件已经移动或删除。")
            return
        }
        if sourceIsDirty,
           selectedProjectFile?.url.standardizedFileURL.path != issueURL.path {
            showAlert("当前代码尚未保存", "请先保存当前文件，再跳转到其他文件的报错位置。")
            return
        }
        openProjectFile(ProjectFile(url: issueURL))
        requestSourceLine(issue.line)
    }

    private func requestSourceLine(_ line: Int) {
        requestedSourceLine = nil
        DispatchQueue.main.async { [weak self] in
            self?.requestedSourceLine = line
        }
    }

    nonisolated private static func executeCommand(
        _ executableURL: URL,
        _ arguments: [String],
        controller: ProcessController
    ) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = ProcessInfo.processInfo.environment.merging([
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8"
        ]) { _, new in new }

        do {
            guard try controller.launch(
                process,
                timeout: ResourceLimits.compilerCommandTimeout,
                forceTerminationGrace: ResourceLimits.forceTerminationGrace,
                interruptIO: {
                    try? pipe.fileHandleForReading.close()
                }
            ) else {
                return CommandResult(exitCode: -2, output: "编译已取消。")
            }
            defer { controller.finish(process) }
            let data = readBoundedOutput(
                from: pipe.fileHandleForReading,
                maximumBytes: ResourceLimits.maximumCommandOutputBytes
            )
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            switch controller.stopReason {
            case .cancelled:
                return CommandResult(exitCode: -2, output: "编译已取消。")
            case .timedOut:
                return CommandResult(
                    exitCode: -3,
                    output: "\(executableURL.lastPathComponent) 执行超过 120 秒，已终止。"
                )
            case nil:
                return CommandResult(exitCode: process.terminationStatus, output: output)
            }
        } catch {
            if controller.isCancelled || Task.isCancelled {
                return CommandResult(exitCode: -2, output: "编译已取消。")
            }
            return CommandResult(exitCode: -1, output: "无法运行 \(executableURL.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    private func run(
        cliURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        cleanup: @escaping @Sendable () -> Void = {},
        completion: @escaping @MainActor (CommandResult) -> Void
    ) {
        let process = Process()
        let processController = ProcessController()
        let pipe = Pipe()
        process.executableURL = cliURL
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = ProcessInfo.processInfo.environment.merging([
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8"
        ]) { _, new in new }

        let operationID = UUID()
        activeOperationID = operationID
        activeProcessController = processController

        Task.detached(priority: .userInitiated) {
            defer { cleanup() }
            do {
                guard try processController.launch(
                    process,
                    timeout: timeout,
                    forceTerminationGrace: ResourceLimits.forceTerminationGrace,
                    interruptIO: {
                        try? pipe.fileHandleForReading.close()
                    }
                ) else {
                    return
                }
                defer { processController.finish(process) }
                let data = Self.readBoundedOutput(
                    from: pipe.fileHandleForReading,
                    maximumBytes: ResourceLimits.maximumCommandOutputBytes
                )
                process.waitUntilExit()
                let rawOutput = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                let output = rawOutput
                    .replacingOccurrences(
                        of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
                        with: "",
                        options: .regularExpression
                    )
                    .replacingOccurrences(of: "\r", with: "\n")
                let result: CommandResult
                switch processController.stopReason {
                case .cancelled:
                    result = CommandResult(exitCode: -2, output: "操作已取消。")
                case .timedOut:
                    result = CommandResult(
                        exitCode: -3,
                        output: "烧录引擎执行超过 \(Int(timeout)) 秒，已终止。\n\(output)"
                    )
                case nil:
                    result = CommandResult(exitCode: process.terminationStatus, output: output)
                }
                await MainActor.run { [weak self] in
                    guard let self, self.activeOperationID == operationID else { return }
            self.activeOperationID = nil
                    self.activeProcessController = nil
                    completion(result)
                }
            } catch {
                let result = CommandResult(exitCode: -1, output: "无法启动烧录引擎：\(error.localizedDescription)")
                await MainActor.run { [weak self] in
                    guard let self, self.activeOperationID == operationID else { return }
                    self.activeOperationID = nil
                    self.activeProcessController = nil
                    completion(result)
                }
            }
        }
    }

    private func outputContainsProbe(_ output: String) -> Bool {
        let lower = output.lowercased()
        if lower.contains("no st-link detected") || lower.contains("no debug probe detected") {
            return false
        }
        return lower.contains("st-link") || lower.contains("stlink sn") || lower.contains("serial number")
    }

    private func parseProbeName(_ output: String) -> String {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.localizedCaseInsensitiveContains("ST-LINK/V3") { return "ST-Link V3" }
            if trimmed.localizedCaseInsensitiveContains("ST-LINK/V2-1") { return "ST-Link V2-1" }
            if trimmed.localizedCaseInsensitiveContains("ST-LINK/V2") { return "ST-Link V2" }
        }
        return "ST-Link"
    }

    private func friendlyFailureMessage(_ output: String) -> String {
        let lower = output.lowercased()
        if lower.contains("执行超过") || lower.contains("timed out") {
            return "烧录引擎响应超时，操作已被停止。请重新插拔 ST-Link、降低 SWD 频率后重试。"
        }
        if lower.contains("no st-link") || lower.contains("no debug probe") {
            return "没有检测到 ST-Link。请重新插拔 USB，并确认烧录器指示灯已亮。"
        }
        if lower.contains("no device found") || lower.contains("target") && lower.contains("not found") {
            return "已找到 ST-Link，但没有连接到目标芯片。请检查 GND、SWDIO、SWCLK、NRST 和目标板供电。"
        }
        if lower.contains("cannot connect") || lower.contains("connection failed") {
            return "无法通过 SWD 连接芯片。建议连接 NRST 后重试，并确认 BOOT0 没有悬空。"
        }
        if lower.contains("verification") && lower.contains("failed") {
            return "固件写入后校验失败。请降低 SWD 频率、检查供电稳定性后重试。"
        }
        if lower.contains("read out protection") || lower.contains("rdp") {
            return "芯片可能启用了读保护。解除保护会擦除 Flash，请先使用官方工具确认选项字节。"
        }
        return "烧录引擎返回错误。请复制下方日志，我可以根据日志继续定位。"
    }

    private func probeDiagnostic(
        for output: String,
        probeWasFound: Bool
    ) -> (title: String, detail: String) {
        let lower = output.lowercased()

        if lower.contains("执行超过") || lower.contains("timed out") {
            return (
                "设备响应超时",
                "重新插拔 ST-Link 后重试；仍超时可把 SWD 频率降到 1000 kHz。"
            )
        }
        if !probeWasFound || lower.contains("no st-link") || lower.contains("no debug probe") {
            return (
                "USB 未识别 ST-Link",
                "问题在电脑到烧录器之间；请换 USB 口或数据线，无需检查 SWD 接线。"
            )
        }
        if let voltage = parsedTargetVoltage(from: output), voltage < 0.5 {
            return (
                "目标板未供电",
                "ST-Link 已识别，但目标电压接近 0 V；请检查 3.3V 和共地。"
            )
        }
        if lower.contains("usb communication") || lower.contains("st-link error") {
            return (
                "ST-Link 通信异常",
                "探针出现 USB 通信错误，请重新插拔，必要时更换数据线或 USB 口。"
            )
        }
        if lower.contains("read out protection") || lower.contains("rdp") {
            return (
                "芯片处于保护状态",
                "检测到读保护；不要直接解除，解除保护可能清空芯片 Flash。"
            )
        }
        if lower.contains("no device found") || (lower.contains("target") && lower.contains("not found")) {
            return (
                "目标芯片未响应",
                "ST-Link 已识别；请检查 GND、SWDIO、SWCLK、3.3V，必要时连接 NRST。"
            )
        }
        if lower.contains("cannot connect") || lower.contains("connection failed") {
            return (
                "SWD 连接失败",
                "检查 SWDIO、SWCLK、GND 和供电；连接 NRST 后可再降低 SWD 频率重试。"
            )
        }
        return (
            "检测工具返回异常",
            "ST-Link 已识别但目标确认失败；查看下方原始日志可获得具体错误。"
        )
    }

    private func parsedTargetVoltage(from output: String) -> Double? {
        let pattern = #"(?i)target\s+voltage\s*[:=]\s*([0-9]+(?:\.[0-9]+)?)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: output,
                  range: NSRange(output.startIndex..., in: output)
              ),
              let range = Range(match.range(at: 1), in: output)
        else { return nil }
        return Double(output[range])
    }

    private func redactedCommand(_ arguments: [String]) -> String {
        arguments.map { argument in
            argument.contains(" ") ? "\"\(argument)\"" : argument
        }.joined(separator: " ")
    }

    private func appendLog(_ message: String) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        logText = Self.appendingBounded(
            "[\(Self.logTimeFormatter.string(from: Date()))] \(text)\n",
            to: logText,
            maximumCharacters: ResourceLimits.maximumLogCharacters
        )
    }

    private func appendBuildLog(_ message: String) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        buildLog = Self.appendingBounded(
            "[\(Self.logTimeFormatter.string(from: Date()))] \(text)\n",
            to: buildLog,
            maximumCharacters: ResourceLimits.maximumLogCharacters
        )
    }

    private func appendBuildLogBlock(_ message: String) {
        guard !message.isEmpty else { return }
        buildLog = Self.appendingBounded(
            message.hasSuffix("\n") ? message : message + "\n",
            to: buildLog,
            maximumCharacters: ResourceLimits.maximumLogCharacters
        )
    }

    nonisolated private static func readBoundedOutput(
        from handle: FileHandle,
        maximumBytes: Int
    ) -> Data {
        var captured = Data()
        var wasTruncated = false

        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                let remaining = maximumBytes - captured.count
                if remaining > 0 {
                    captured.append(chunk.prefix(remaining))
                }
                if chunk.count > remaining {
                    wasTruncated = true
                }
            }
        } catch {
            // Cancellation and timeout deliberately close the read side to
            // prevent descendants from keeping this operation alive.
        }

        if wasTruncated {
            captured.append(Data("\n[输出超过 1 MiB，后续内容已丢弃]\n".utf8))
        }
        return captured
    }

    nonisolated private static func appendingBounded(
        _ addition: String,
        to existing: String,
        maximumCharacters: Int
    ) -> String {
        let combined = existing + addition
        guard combined.count > maximumCharacters else { return combined }
        let marker = "[较早日志已自动清理，防止内存持续增长]\n"
        let available = max(0, maximumCharacters - marker.count)
        return marker + String(combined.suffix(available))
    }

    private func showAlert(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
        isShowingAlert = true
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func sourceFileSnapshot(for url: URL) -> WorkspaceFileRevision? {
        WorkspaceFileRevisionReader.read(url)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
