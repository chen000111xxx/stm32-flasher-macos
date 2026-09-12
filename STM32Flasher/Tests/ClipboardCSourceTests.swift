import Foundation

@main
struct ClipboardCSourceTests {
    static func main() {
        require(
            ClipboardCSource.normalized(from: "```c\nint main(void) { return 0; }\n```")
                == "int main(void) { return 0; }\n",
            "必须去除 AI 回答里的 Markdown 代码围栏"
        )

        require(
            ClipboardCSource.normalized(from: "\u{FEFF}#include <stdint.h>\r\n")
                == "#include <stdint.h>\n",
            "必须统一换行并移除 UTF-8 BOM"
        )

        require(
            ClipboardCSource.normalized(from: "说明\n```\nint value;\n```\n更多说明")
                == "int value;\n",
            "有说明文字时必须只导入围栏内的代码"
        )

        print("剪贴板 C 源码导入测试通过。")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("剪贴板导入测试失败：\(message)")
        }
    }
}
