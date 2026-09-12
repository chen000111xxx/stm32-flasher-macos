# STM32 烧录器 for macOS

一个面向 **STM32F103C8T6 + ST-Link** 的原生 macOS 烧录工具。

软件只围绕一件事设计：选择固件或 C 工程，编译（可选），检测 ST-Link，
擦除、写入、校验并复位目标芯片。

## 主要功能

- 支持 `.hex`、`.bin`、`.elf` 固件
- 自动寻找 ST 官方 `STM32_Programmer_CLI`
- 支持 ARM GCC 编译 C 工程并自动载入生成的固件
- 资源管理器支持文件夹套文件夹、创建、重命名、移动、复制和拖拽归类
- 文件菜单和右键菜单提供打开、打开方式、保存、另存为、访达显示等标准操作
- 编译、烧录、日志和文件扫描均有取消、超时和资源上限保护
- 修改代码后会自动作废旧固件，避免误烧录上一次构建结果
- 白色简洁 macOS 界面，代码编辑器支持行号、语法高亮和字号缩放

## 系统要求

- macOS 13 或更高版本（Apple Silicon arm64 构建）
- [STM32CubeProgrammer](https://www.st.com/en/development-tools/stm32cubeprog.html)
  （使用真实 ST-Link 烧录时需要）
- `arm-none-eabi-gcc`（需要在本机编译 C 工程时需要）

软件不会上传源码，不会自动联网安装工具链，也不会在没有用户操作时烧录设备。

## 构建与测试

在仓库根目录执行：

```bash
cd STM32Flasher
./Scripts/check.sh
```

检查脚本会构建签名应用，并运行文件树、编辑器、剪贴板导入和安全边界测试。
构建产物为：

```text
STM32Flasher/build/STM32 烧录器.app
```

## 工程结构

```text
STM32Flasher/
├── Sources/       SwiftUI 界面、资源管理器、编译和烧录逻辑
├── Resources/     Info.plist、图标、链接脚本和启动文件
├── Tests/         不依赖真实硬件的逻辑测试与 CLI 固件测试夹具
├── Scripts/       可重复的构建与检查脚本
└── docs/          AI 协作任务模板
```

更详细的模块边界和安全限制见 [`STM32Flasher/ARCHITECTURE.md`](STM32Flasher/ARCHITECTURE.md)，
使用说明见 [`STM32Flasher/使用说明.md`](STM32Flasher/使用说明.md)。

## 目标芯片限制

当前版本针对 STM32F103C8T6 的 64 KiB Flash / 20 KiB RAM 做了保护性校验。
其他 STM32 型号可以使用通用固件文件，但烧录前请确认设备型号和地址范围。

## 开源许可

许可证将在首次公开发布前确定。请在发布前选择并加入 MIT、GPLv3 或其他你希望采用的许可证。
