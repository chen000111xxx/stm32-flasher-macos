import AppKit
import SwiftUI

@main
struct EditorLogicTests {
    @MainActor
    static func main() {
        _ = NSApplication.shared

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false

        let textView = BoundedUndoTextView(
            frame: window.contentView?.bounds ?? .zero
        )
        textView.allowsUndo = true
        window.contentView = textView
        window.makeFirstResponder(textView)
        textView.configureUndoManager()

        guard let undoManager = textView.undoManager else {
            fatalError("编辑器撤销测试失败：NSTextView 没有可用的 undo manager")
        }
        require(undoManager.levelsOfUndo == 30, "撤销历史必须限制为 30 层")

        var boundText = "旧文件"
        let editor = SyntaxHighlightedCodeEditor(
            text: Binding(
                get: { boundText },
                set: { boundText = $0 }
            ),
            onTextChange: {}
        )
        let coordinator = editor.makeCoordinator()
        coordinator.textView = textView

        textView.string = "旧文件内容"
        undoManager.registerUndo(withTarget: textView) { target in
            target.string = "不应恢复的旧文件内容"
        }
        require(undoManager.canUndo, "测试必须先建立旧文件的撤销记录")

        coordinator.replaceText(
            in: textView,
            with: "新文件内容",
            clearingUndoHistory: true
        )
        require(!undoManager.canUndo, "切换文件后必须清空旧文件撤销记录")
        undoManager.undo()
        require(textView.string == "新文件内容", "撤销不得把旧文件内容写入新文件")
        require(undoManager.levelsOfUndo == 30, "切换文件后撤销上限仍须保持 30 层")

        let lineSource = "first\nsecond\nthird" as NSString
        require(
            EditorLineNumberRulerView.lineNumber(at: 0, in: lineSource) == 1,
            "首字符必须属于第 1 行"
        )
        require(
            EditorLineNumberRulerView.lineNumber(at: 6, in: lineSource) == 2,
            "第二行起点必须显示第 2 行"
        )
        require(
            EditorLineNumberRulerView.lineNumber(at: lineSource.length, in: lineSource) == 3,
            "文件末尾必须保持正确行号"
        )

        let defaults = UserDefaults.standard
        let previousFontSize = defaults.object(forKey: "EditorFontSize")
        defer {
            if let previousFontSize {
                defaults.set(previousFontSize, forKey: "EditorFontSize")
            } else {
                defaults.removeObject(forKey: "EditorFontSize")
            }
        }

        defaults.removeObject(forKey: "EditorFontSize")
        let appearance = AppearanceSettings()
        require(appearance.editorFontSize == 13, "代码字号初始值必须是 13")

        appearance.zoomEditorIn()
        require(appearance.editorFontSize == 14, "放大代码必须增加 1 点字号")
        appearance.zoomEditorOut()
        require(appearance.editorFontSize == 13, "缩小代码必须减少 1 点字号")
        appearance.editorFontSizeBinding.wrappedValue = 100
        require(appearance.editorFontSize == 26, "字号必须限制在最大值 26")
        appearance.editorFontSizeBinding.wrappedValue = -100
        require(appearance.editorFontSize == 10, "字号必须限制在最小值 10")
        appearance.resetEditorZoom()
        require(appearance.editorFontSize == 13, "恢复代码字号必须回到 13")

        print("编辑器测试通过：撤销隔离、行号和字号缩放均正常。")
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError("编辑器撤销测试失败：\(message)")
        }
    }
}
