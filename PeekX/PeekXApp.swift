//
//  PeekXApp.swift
//  PeekX
//

import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement

// MARK: - 应用入口

@main
struct PeekXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - 应用代理

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var officePreviewScanTimer: Timer?
    private var officePreviewRequestsInProgress = Set<String>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 只作为菜单栏应用运行，不在 Dock 中显示图标。
        NSApp.setActivationPolicy(.accessory)

        requestNotificationPermission()
        checkAndRefreshExtensionIfNeeded()
        startOfficePreviewHelper()

        // 创建菜单栏按钮，点击后打开设置窗口。
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let icon = NSImage(named: "MenuIcon") ??
                       NSImage(systemSymbolName: "eye",
                               accessibilityDescription: "PeekX")!
            icon.isTemplate = true
            button.image = icon
            button.action = #selector(toggleSettings)
            button.target = self
        }

        // 不自动退出，保持常驻以便菜单栏入口可用。
    }

    // MARK: - 设置窗口

    @objc private func toggleSettings() {
        if let window = settingsWindow, window.isVisible {
            window.close()
            return
        }

        let contentView = SettingsView {
            NSApp.terminate(nil)
        }
        let hosting = NSHostingView(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PeekX"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)

        // 尽量让设置窗口贴近菜单栏图标弹出。
        if let button = statusItem.button, let screen = button.window?.screen {
            let buttonFrame = button.window!.convertToScreen(button.frame)
            let windowOrigin = NSPoint(
                x: buttonFrame.midX - window.frame.width / 2,
                y: buttonFrame.minY - window.frame.height - 8
            )
            window.setFrameTopLeftPoint(windowOrigin)
        }

        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 扩展刷新

    private func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func checkAndRefreshExtensionIfNeeded() {
        let defaults = UserDefaults.standard
        let lastVersionKey = "PeekXLastLaunchedVersion"

        guard let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let bld = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        else { return }

        let full = "\(ver).\(bld)"
        let last = defaults.string(forKey: lastVersionKey)

        if last != full {
            refreshQuickLookExtension()
            defaults.set(full, forKey: lastVersionKey)
            if last != nil { showUpdateNotification() }
        }
    }

    private func refreshQuickLookExtension() {
        // 版本变化后刷新 Quick Look 服务，避免系统继续使用旧扩展缓存。
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["-9", "quicklookd"]
        try? kill.run()
        kill.waitUntilExit()

        // 给 launchd 一点时间重新拉起 quicklookd。
        Thread.sleep(forTimeInterval: 1.0)

        // 通知新的 quicklookd 重新加载预览生成器。
        let reload = Process()
        reload.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        reload.arguments = ["-r"]
        try? reload.run()
        reload.waitUntilExit()

        // 让 Finder 重新连接到新的 quicklookd 实例。
        let killFinder = Process()
        killFinder.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killFinder.arguments = ["-9", "Finder"]
        try? killFinder.run()
    }

    private func showUpdateNotification() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = "PeekX Updated"
            content.body = "Quick Look extension has been refreshed"
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request) { _ in }
        }
    }

    // MARK: - Office 原生预览 helper

    private func startOfficePreviewHelper() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleOfficePreviewRequest(_:)),
            name: Notification.Name("com.pohister.PeekX.officePreviewRequest"),
            object: nil
        )

        officePreviewScanTimer?.invalidate()
        officePreviewScanTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.scanOfficePreviewRequests()
        }
    }

    @objc private func handleOfficePreviewRequest(_ notification: Notification) {
        guard let requestPath = notification.userInfo?["requestPath"] as? String else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            self.processOfficePreviewRequest(requestPath: requestPath)
        }
    }

    private func scanOfficePreviewRequests() {
        let rootURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.pohister.PeekX.PeekXExt/Data/tmp/PeekXArchivePreviews", isDirectory: true)

        guard FileManager.default.fileExists(atPath: rootURL.path),
              let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              )
        else { return }

        while let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent == "request.json" else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard Date().timeIntervalSince(modified) < 60 else { continue }

            let requestPath = url.path
            let responsePath = url.deletingLastPathComponent().appendingPathComponent("response.json").path

            guard !FileManager.default.fileExists(atPath: responsePath),
                  !officePreviewRequestsInProgress.contains(requestPath)
            else { continue }

            officePreviewRequestsInProgress.insert(requestPath)
            DispatchQueue.global(qos: .userInitiated).async {
                self.processOfficePreviewRequest(requestPath: requestPath)
                DispatchQueue.main.async {
                    self.officePreviewRequestsInProgress.remove(requestPath)
                }
            }
        }
    }

    private func processOfficePreviewRequest(requestPath: String) {
        let requestURL = URL(fileURLWithPath: requestPath)
        var responseURL: URL?
        var requestID = UUID().uuidString

        do {
            let requestData = try Data(contentsOf: requestURL)
            let request = try JSONDecoder().decode(OfficePreviewHelperRequest.self, from: requestData)
            requestID = request.requestID
            responseURL = URL(fileURLWithPath: request.responsePath)

            let htmlURL = try exportOfficePreviewHTML(inputPath: request.inputPath, outputPath: request.outputPath)
            let response = OfficePreviewHelperResponse(
                requestID: request.requestID,
                status: "ok",
                htmlPath: htmlURL.path,
                error: nil
            )
            try JSONEncoder().encode(response).write(to: URL(fileURLWithPath: request.responsePath), options: .atomic)
        } catch {
            guard let responseURL else { return }
            let response = OfficePreviewHelperResponse(
                requestID: requestID,
                status: "error",
                htmlPath: nil,
                error: error.localizedDescription
            )
            try? JSONEncoder().encode(response).write(to: responseURL, options: .atomic)
        }
    }

    private func exportOfficePreviewHTML(inputPath: String, outputPath: String) throws -> URL {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: outputPath, isDirectory: true),
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", "-o", outputPath, inputPath]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        try process.run()
        guard semaphore.wait(timeout: .now() + 12) == .success else {
            process.terminate()
            throw OfficePreviewHelperError.timedOut
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw OfficePreviewHelperError.exportFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let htmlURL = findPreviewHTML(in: URL(fileURLWithPath: outputPath, isDirectory: true)) else {
            throw OfficePreviewHelperError.missingHTML
        }
        return htmlURL
    }

    private func findPreviewHTML(in directory: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "Preview.html" {
                return url
            }
        }
        return nil
    }
}

private struct OfficePreviewHelperRequest: Codable {
    let requestID: String
    let inputPath: String
    let outputPath: String
    let responsePath: String
}

private struct OfficePreviewHelperResponse: Codable {
    let requestID: String
    let status: String
    let htmlPath: String?
    let error: String?
}

private enum OfficePreviewHelperError: LocalizedError {
    case timedOut
    case missingHTML
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Office Quick Look export timed out."
        case .missingHTML:
            return "Office Quick Look did not produce Preview.html."
        case .exportFailed(let message):
            return "Office Quick Look export failed: \(message)"
        }
    }
}

// MARK: - 设置视图

struct SettingsView: View {
    let quitAction: () -> Void

    @State private var launchAtLogin: Bool = {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }()
    @State private var hasPermissions = false
    @State private var checkingPermissions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部应用信息。
            HStack {
                if let appIcon = NSApp.applicationIconImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 48, height: 48)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("PeekX").font(.title2).bold()
                    Text("Quick Look 预览增强")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider().padding(.horizontal, 20)

            // 登录时自动启动。
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("开机自启").font(.body)
                    Text("登录时自动启动 PeekX")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider().padding(.horizontal, 20)

            // 完全磁盘访问权限状态。
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("完全磁盘访问权限").font(.body)
                    Spacer()
                    if checkingPermissions {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    } else if hasPermissions {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("已授予")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                            Text("未授权")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }

                Text("PeekX 需要完全磁盘访问权限才能预览任意位置的文件和压缩包内容。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !checkingPermissions && !hasPermissions {
                    Button("打开系统设置授予权限") {
                        openFullDiskAccessSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider().padding(.horizontal, 20)

            // 底部操作按钮。
            HStack {
                Button("退出 PeekX") {
                    quitAction()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 380)
        .onAppear { checkPermissions() }
    }

    // MARK: - 操作

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func checkPermissions() {
        checkingPermissions = true
        DispatchQueue.global(qos: .userInitiated).async {
            let granted = Self.hasFullDiskAccess()
            DispatchQueue.main.async {
                hasPermissions = granted
                checkingPermissions = false
            }
        }
    }

    static func hasFullDiskAccess() -> Bool {
        // 通过读取受保护目录判断是否已经授予完全磁盘访问权限。
        let testPaths = [
            "\(NSHomeDirectory())/Library/Mail",
            "\(NSHomeDirectory())/Library/Safari",
            "\(NSHomeDirectory())/Library/Messages",
        ]
        for path in testPaths {
            let url = URL(fileURLWithPath: path)
            if let contents = try? FileManager.default.contentsOfDirectory(at: url,
                includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                // 能读取受保护目录，说明完全磁盘访问权限已授予。
                _ = contents
                return true
            }
        }
        // 兜底检查一个通常受完全磁盘访问保护的文件。
        let safariHistory = "\(NSHomeDirectory())/Library/Safari/History.db"
        if FileManager.default.isReadableFile(atPath: safariHistory) {
            return true
        }
        return false
    }

    private func openFullDiskAccessSettings() {
        // 打开系统设置中的“隐私与安全性 > 完全磁盘访问权限”。
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        )
    }
}
