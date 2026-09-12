import Foundation

enum CLIResolver {
    static func resolve() -> URL? {
        let fileManager = FileManager.default
        var candidates: [String] = []

        if let environmentPath = ProcessInfo.processInfo.environment["STM32_PROGRAMMER_CLI"] {
            candidates.append(environmentPath)
        }

        if let custom = UserDefaults.standard.string(forKey: "CustomSTM32ProgrammerCLIPath") {
            candidates.append(custom)
        }

        candidates += [
            "/Applications/STM32CubeProgrammer.app/Contents/Resources/bin/STM32_Programmer_CLI",
            "/Applications/STM32CubeProgrammer.app/Contents/MacOs/bin/STM32_Programmer_CLI",
            "/Applications/STM32CubeProgrammer.app/Contents/MacOS/bin/STM32_Programmer_CLI",
            "/Applications/STMicroelectronics/STM32Cube/STM32CubeProgrammer/STM32CubeProgrammer.app/Contents/Resources/bin/STM32_Programmer_CLI",
            "/Applications/STMicroelectronics/STM32Cube/STM32CubeProgrammer/STM32CubeProgrammer.app/Contents/MacOs/bin/STM32_Programmer_CLI",
            "/Applications/STMicroelectronics/STM32Cube/STM32CubeProgrammer/STM32CubeProgrammer.app/Contents/MacOS/bin/STM32_Programmer_CLI",
            "/Applications/STMicroelectronics/STM32Cube/STM32CubeProgrammer/bin/STM32_Programmer_CLI",
            "/opt/homebrew/bin/STM32_Programmer_CLI",
            "/usr/local/bin/STM32_Programmer_CLI"
        ]

        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }
}
enum CompilerResolver {
    static func resolve() -> (compiler: URL?, objcopy: URL?, size: URL?) {
        let fileManager = FileManager.default
        let compilerCandidates = [
            "/opt/homebrew/bin/arm-none-eabi-gcc",
            "/usr/local/bin/arm-none-eabi-gcc",
            "/usr/bin/arm-none-eabi-gcc"
        ]

        for compilerPath in compilerCandidates
            where fileManager.isExecutableFile(atPath: compilerPath) {
            let compilerURL = URL(fileURLWithPath: compilerPath)
            let objcopyURL = compilerURL
                .deletingLastPathComponent()
                .appendingPathComponent("arm-none-eabi-objcopy")
            let sizeURL = compilerURL
                .deletingLastPathComponent()
                .appendingPathComponent("arm-none-eabi-size")
            if fileManager.isExecutableFile(atPath: objcopyURL.path),
               fileManager.isExecutableFile(atPath: sizeURL.path) {
                return (compilerURL, objcopyURL, sizeURL)
            }
        }

        return (nil, nil, nil)
    }
}
