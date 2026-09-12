import SwiftUI

struct ThemePalette {
    let canvas: Color
    let sidebar: Color
    let panel: Color
    let elevated: Color
    let editor: Color
    let console: Color
    let selected: Color
    let hover: Color
    let border: Color
    let strongBorder: Color
    let primaryText: Color
    let secondaryText: Color
    let mutedText: Color
    let faintText: Color
    let accent: Color
    let success: Color
    let warning: Color
    let danger: Color
}

enum IDETheme: String {
    case codexLight

    static var current: IDETheme { .codexLight }

    var palette: ThemePalette {
        ThemePalette(
            canvas: Color(red: 0.988, green: 0.988, blue: 0.980),
            sidebar: Color(red: 0.965, green: 0.965, blue: 0.950),
            panel: .white,
            elevated: Color(red: 0.950, green: 0.950, blue: 0.935),
            editor: .white,
            console: Color(red: 0.975, green: 0.975, blue: 0.965),
            selected: Color(red: 0.910, green: 0.910, blue: 0.890),
            hover: Color(red: 0.935, green: 0.935, blue: 0.920),
            border: Color.black.opacity(0.08),
            strongBorder: Color.black.opacity(0.13),
            primaryText: Color(red: 0.105, green: 0.105, blue: 0.100),
            secondaryText: Color(red: 0.275, green: 0.275, blue: 0.260),
            mutedText: Color(red: 0.430, green: 0.430, blue: 0.405),
            faintText: Color(red: 0.610, green: 0.610, blue: 0.580),
            accent: Color(red: 0.055, green: 0.580, blue: 0.435),
            success: Color(red: 0.035, green: 0.560, blue: 0.330),
            warning: Color(red: 0.780, green: 0.455, blue: 0.080),
            danger: Color(red: 0.790, green: 0.160, blue: 0.145)
        )
    }
}

@MainActor
final class AppearanceSettings: ObservableObject {
    static let minimumEditorFontSize = 10.0
    static let maximumEditorFontSize = 26.0
    static let defaultEditorFontSize = 13.0

    private enum Key {
        static let editorFontSize = "EditorFontSize"
        static let wrapsEditorLines = "WrapsEditorLines"
        static let showsBuildOutput = "ShowsBuildOutput"
    }

    @Published private(set) var editorFontSize: Double

    var editorFontSizeBinding: Binding<Double> {
        Binding(
            get: { self.editorFontSize },
            set: { self.setEditorFontSize($0) }
        )
    }

    @Published var wrapsEditorLines: Bool {
        didSet { UserDefaults.standard.set(wrapsEditorLines, forKey: Key.wrapsEditorLines) }
    }

    @Published var showsBuildOutput: Bool {
        didSet { UserDefaults.standard.set(showsBuildOutput, forKey: Key.showsBuildOutput) }
    }

    init() {
        let defaults = UserDefaults.standard
        let savedFontSize = defaults.double(forKey: Key.editorFontSize)
        editorFontSize = savedFontSize == 0
            ? Self.defaultEditorFontSize
            : min(
                max(savedFontSize, Self.minimumEditorFontSize),
                Self.maximumEditorFontSize
            )
        wrapsEditorLines = defaults.object(forKey: Key.wrapsEditorLines) as? Bool ?? false
        showsBuildOutput = defaults.object(forKey: Key.showsBuildOutput) as? Bool ?? true
    }

    func reset() {
        setEditorFontSize(Self.defaultEditorFontSize)
        wrapsEditorLines = false
        showsBuildOutput = true
    }

    func zoomEditorIn() {
        setEditorFontSize(editorFontSize + 1)
    }

    func zoomEditorOut() {
        setEditorFontSize(editorFontSize - 1)
    }

    func resetEditorZoom() {
        setEditorFontSize(Self.defaultEditorFontSize)
    }

    func setEditorFontSize(_ value: Double) {
        let boundedValue = min(
            max(value, Self.minimumEditorFontSize),
            Self.maximumEditorFontSize
        )
        UserDefaults.standard.set(boundedValue, forKey: Key.editorFontSize)
        guard editorFontSize != boundedValue else { return }
        editorFontSize = boundedValue
    }
}
