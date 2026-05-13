// PeekX - 调试日志
// Copyright © 2025 ALTIC. All rights reserved.

import Foundation

final class DebugLogger {
    static let shared = DebugLogger()

    private let fileURL: URL
    // Quick Look 扩展里的标准输出不稳定，异步写入临时日志更适合排查现场问题。
    private let queue = DispatchQueue(label: "com.peekx.logger", qos: .utility)
    private let mirrorsToConsole = false
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let maxSize: UInt64 = 256 * 1024

    private init() {
        let sandboxTempLog = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PeekXExt.log")
        fileURL = sandboxTempLog
    }

    func log(_ message: String) {
        let date = Date()
        queue.async {
            let timestamp = self.formatter.string(from: date)
            let entry = "[\(timestamp)] \(message)\n"
            if let data = entry.data(using: .utf8) {
                self.append(data)
            }
            if self.mirrorsToConsole {
                NSLog("%@", message)
            }
        }
    }

    func locationDescription() -> String { fileURL.path }

    private func append(_ data: Data) {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) == false {
                try data.write(to: fileURL, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            }
            pruneIfNeeded(fileURL)
        } catch {
            NSLog("PeekX logger error for %@: %@", fileURL.path, error.localizedDescription)
        }
    }

    private func pruneIfNeeded(_ fileURL: URL) {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? UInt64,
            size > maxSize
        else { return }

        if let data = try? Data(contentsOf: fileURL) {
            let trimmed = data.suffix(Int(maxSize / 2))
            try? trimmed.write(to: fileURL, options: .atomic)
        }
    }
}
