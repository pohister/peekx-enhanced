# PeekX-enhanced

PeekX-enhanced 是一个基于 PeekX 改造的 macOS Quick Look 扩展，用来在访达中直接预览文件夹、压缩包内容以及常见文件格式。选中文件夹、压缩包或文件后按空格即可查看，无需先打开 Finder 子窗口或解压压缩包。

本版本重点增强了压缩包列表预览、Markdown 渲染预览和右侧文件预览体验。

## 功能

- 文件夹内容预览：以树状列表展示文件夹内的完整目录结构。
- 压缩包内容预览：列出压缩包内部目录和文件，不需要先解压。
- 多格式压缩包支持：基于内置 libarchive，覆盖 zip、tar、tar.gz、tar.bz2、tar.xz、7z、rar、iso、cpio、xar、cab 等常见格式。
- 右侧文件预览：支持 macOS Quick Look 原生可预览的图片、PDF、音频、视频、Office 文档等格式。
- Markdown 预览：支持 `.md` / `.markdown` 文件的渲染预览。
- 文本预览：支持常见源码、脚本、配置文件和纯文本文件。
- 压缩包内文件预览：对可安全读取的压缩包成员，会临时提取到沙盒缓存中并尝试使用原生预览。
- 快速选择响应：左侧列表点击后立即选中，右侧预览异步加载。
- 横向和纵向滚动：适配长文件名、宽内容和大图预览。

## 使用方式

1. 在 Finder 中选中文件夹、压缩包或支持的文件。
2. 按空格打开 Quick Look。
3. 左侧浏览文件列表或压缩包目录。
4. 点击左侧项目后，在右侧查看预览和文件信息。

压缩包内部路径会以类似下面的形式表示：

```text
archive.zip!/path/in/archive
```

## 支持的内容

### 文件夹

文件夹预览会显示完整目录树、文件夹数量、文件数量和总大小。界面不再按类型分类筛选，默认展示全部内容。

### 压缩包

压缩包读取使用工程内置的 libarchive 静态库，不依赖 `/usr/bin/tar`、`zipinfo` 等外部命令。

已注册的常见类型包括：

- ZIP
- TAR / TAR.GZ / TAR.BZ2 / TAR.XZ
- 7-Zip
- RAR
- ISO
- CPIO
- XAR
- CAB
- LHA/LZH

如果压缩包损坏、格式不支持或无法读取，会在预览界面显示错误状态。对于能列出目录但无法读取内容的压缩包，仍会尽量展示可获得的条目元数据。

### Markdown

Markdown 文件会在白色背景中渲染显示，支持常见标题、列表、代码块、引用、链接、表格和基础行内样式。

### 原生文件预览

右侧预览会优先使用 macOS 原生 Quick Look / 系统框架能力展示内容，例如：

- 图片：JPEG、PNG、HEIC 等
- PDF
- 音频和视频
- DOCX
- 文本、源码、脚本、JSON、XML、YAML 等

## 构建

要求：

- macOS 14.0 或更高版本
- Xcode
- Apple Silicon 或 Intel Mac

构建命令：

```bash
git clone https://github.com/pohister/PeekX-enhanced.git
cd PeekX-enhanced
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PeekX.xcodeproj -scheme PeekX -configuration Debug build
```

也可以直接用 Xcode 打开：

```bash
open PeekX.xcodeproj
```

然后选择 `PeekX` scheme 并构建。

## 安装和刷新 Quick Look

构建后，把生成的 `PeekX.app` 放到 `/Applications`，启动一次应用以注册 Quick Look 扩展。

如果 Finder 仍然没有使用新扩展，可以刷新 Quick Look：

```bash
qlmanage -r
qlmanage -r cache
killall Finder
```

也可以结束 Quick Look 相关进程后重新预览：

```bash
pkill -f PeekXExt || true
pkill -f QuickLookUIService || true
pkill -f quicklookd || true
```

## 工程结构

```text
PeekX/
├── PeekX/                         # 主应用
│   ├── PeekXApp.swift             # 应用入口和扩展注册提示
│   └── Info.plist                 # 应用支持的文档类型声明
├── PeekXExt/                      # Quick Look 扩展
│   ├── PreviewViewController.swift
│   ├── ArchiveSupport.swift       # 压缩包 provider、listing、entry、libarchive 封装
│   └── Info.plist                 # Quick Look 支持的 UTType
└── ThirdParty/libarchive/         # 内置 libarchive 头文件、静态库和许可证
```

## 实现说明

- `ArchiveProvider` / `ArchiveProviderRegistry` 负责压缩包后端扩展。
- `LibarchiveArchiveProvider` 是当前默认实现。
- `FileItem` 同时表示真实文件系统项目和压缩包内虚拟项目。
- 压缩包预览默认先列目录和元数据；选中成员文件时才按需提取到临时目录用于预览。
- UI 使用 AppKit 实现，文件内容预览结合 QuickLook、PDFKit、AVKit 和系统缩略图能力。

## 隐私

PeekX-enhanced 在本机运行，不上传文件内容，不收集遥测数据。扩展只访问你在 Finder 中主动触发 Quick Look 的文件、文件夹或压缩包。

## 排障

检查扩展是否注册：

```bash
pluginkit -m -v -p com.apple.quicklook.preview | grep PeekX
```

如果预览仍显示旧版本，先刷新缓存并重启 Finder：

```bash
qlmanage -r
qlmanage -r cache
killall Finder
```

如果压缩包不能列出内容，请确认格式本身没有损坏，并尝试用系统归档工具或其他解压软件验证该压缩包是否可读。

## License

PeekX-enhanced 使用 MIT License。第三方 libarchive 相关文件保留其原始许可证，见 `ThirdParty/libarchive/licenses/COPYING`。
