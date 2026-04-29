//
//  PeekXApp.swift
//  PeekX
//

import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement

// MARK: - App Entry

@main
struct PeekXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ── Menu bar only (no Dock icon) ──
        NSApp.setActivationPolicy(.accessory)

        requestNotificationPermission()
        checkAndRefreshExtensionIfNeeded()

        // ── Build status bar item ──
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

        // ── Don't auto-quit; stay alive for the menu bar ──
    }

    // MARK: - Settings window

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

        // Position near the status item if possible
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

    // MARK: - Extension registration

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
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        reset.arguments = ["-r", "cache"]
        try? reset.run()
        reset.waitUntilExit()

        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["quicklookd"]
        try? kill.run()
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
}

// MARK: - Settings View

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
            // Header
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

            // ── Auto-launch ──
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

            // ── Permissions ──
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

            // ── Bottom actions ──
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

    // MARK: - Actions

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
        // Try to access a file that requires Full Disk Access
        let testPaths = [
            "\(NSHomeDirectory())/Library/Mail",
            "\(NSHomeDirectory())/Library/Safari",
            "\(NSHomeDirectory())/Library/Messages",
        ]
        for path in testPaths {
            let url = URL(fileURLWithPath: path)
            if let contents = try? FileManager.default.contentsOfDirectory(at: url,
                includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                // Successfully read a protected directory → FDA granted
                _ = contents
                return true
            }
        }
        // Fallback: try a known FDA-protected file
        let safariHistory = "\(NSHomeDirectory())/Library/Safari/History.db"
        if FileManager.default.isReadableFile(atPath: safariHistory) {
            return true
        }
        return false
    }

    private func openFullDiskAccessSettings() {
        // Opens System Settings → Privacy → Full Disk Access
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        )
    }
}
