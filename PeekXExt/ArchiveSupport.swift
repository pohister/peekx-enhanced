// PeekX - Archive Preview Support
// Copyright © 2025 ALTIC. All rights reserved.

import Foundation
import UniformTypeIdentifiers

struct ArchiveEntry {
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let modificationDate: Date?
    let kindDescription: String
    let isEncrypted: Bool
}

struct ArchiveListing {
    let archiveURL: URL
    let formatDescription: String
    let entries: [ArchiveEntry]
    let warning: String?
}

protocol ArchiveProvider {
    func canOpen(_ url: URL, contentType: UTType?) -> Bool
    func listContents(of url: URL) throws -> ArchiveListing
    func extractEntry(_ entryPath: String, from archiveURL: URL, to destinationURL: URL) throws
}

final class ArchiveProviderRegistry {
    static let shared = ArchiveProviderRegistry()

    private let providers: [ArchiveProvider]

    init(providers: [ArchiveProvider] = [LibarchiveArchiveProvider()]) {
        self.providers = providers
    }

    func provider(for url: URL, contentType: UTType?) -> ArchiveProvider? {
        providers.first { $0.canOpen(url, contentType: contentType) }
    }
}

enum ArchiveProviderError: LocalizedError {
    case couldNotCreateReader
    case unsupportedArchive(URL)
    case entryNotFound(String)
    case openFailed(URL, String)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .couldNotCreateReader:
            return "Could not initialize the archive reader."
        case .unsupportedArchive(let url):
            return "\(url.lastPathComponent) is not a supported archive."
        case .entryNotFound(let path):
            return "\(path) was not found in the archive."
        case .openFailed(let url, let message):
            return "Could not open \(url.lastPathComponent): \(message)"
        case .readFailed(let message):
            return "Could not read archive contents: \(message)"
        }
    }
}

final class LibarchiveArchiveProvider: ArchiveProvider {
    private let archiveType = UTType("public.archive")
    private let supportedTypeIdentifiers: Set<String> = [
        "public.archive",
        "public.zip-archive",
        "com.winzip.zipx-archive",
        "public.tar-archive",
        "org.gnu.gnu-zip-tar-archive",
        "public.tar-bzip2-archive",
        "org.tukaani.tar-xz-archive",
        "com.facebook.zstandard-tar-archive",
        "org.7-zip.7-zip-archive",
        "com.rarlab.rar-archive",
        "public.iso-image",
        "public.cpio-archive",
        "com.apple.xar-archive",
        "com.microsoft.cab",
        "public.archive.lha",
        "com.sun.java-archive",
        "com.sun.web-application-archive",
        "org.gnu.gnu-zip-archive",
        "public.bzip2-archive",
        "org.tukaani.xz-archive",
        "org.tukaani.lzma-archive",
        "com.facebook.zstandard-archive",
        "public.lz4-archive",
        "public.z-archive"
    ]

    private let supportedSuffixes: Set<String> = [
        ".zip", ".zipx", ".jar", ".war", ".ear",
        ".tar", ".tgz", ".tar.gz", ".tbz", ".tbz2", ".tar.bz2",
        ".txz", ".tar.xz", ".tzst", ".tar.zst",
        ".7z", ".rar", ".iso", ".cpio", ".xar", ".cab",
        ".lha", ".lzh", ".warc", ".ar", ".deb", ".rpm",
        ".gz", ".bz2", ".xz", ".lzma", ".zst", ".lz4", ".z"
    ]

    func canOpen(_ url: URL, contentType: UTType?) -> Bool {
        if let identifier = contentType?.identifier, supportedTypeIdentifiers.contains(identifier) {
            return true
        }

        if let archiveType, contentType?.conforms(to: archiveType) == true {
            return true
        }

        let filename = url.lastPathComponent.lowercased()
        return supportedSuffixes.contains { filename.hasSuffix($0) }
    }

    func listContents(of url: URL) throws -> ArchiveListing {
        guard canOpen(url, contentType: try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) else {
            throw ArchiveProviderError.unsupportedArchive(url)
        }

        guard let archive = archive_read_new() else {
            throw ArchiveProviderError.couldNotCreateReader
        }
        defer { archive_read_free(archive) }

        guard archive_read_support_filter_all(archive) == archiveOK,
              archive_read_support_format_all(archive) == archiveOK else {
            throw ArchiveProviderError.readFailed(errorMessage(from: archive))
        }

        let openStatus = url.withUnsafeFileSystemRepresentation { path in
            archive_read_open_filename(archive, path, 64 * 1024)
        }
        guard openStatus == archiveOK else {
            throw ArchiveProviderError.openFailed(url, errorMessage(from: archive))
        }

        var entries: [ArchiveEntry] = []
        var warning: String?
        var detectedFormat = "Archive"

        while true {
            var entryPointer: OpaquePointer?
            let status = archive_read_next_header(archive, &entryPointer)

            if let formatName = string(from: archive_format_name(archive)), !formatName.isEmpty {
                detectedFormat = formatName
            }

            if status == archiveEOF {
                break
            }

            if status < archiveWarn {
                let message = errorMessage(from: archive)
                if entries.isEmpty {
                    throw ArchiveProviderError.readFailed(message)
                }
                warning = message
                break
            }

            guard let entryPointer,
                  let path = normalizedPath(from: entryPointer),
                  !path.isEmpty else {
                continue
            }

            entries.append(makeEntry(from: entryPointer, path: path))

            let skipStatus = archive_read_data_skip(archive)
            if skipStatus < archiveWarn {
                let message = errorMessage(from: archive)
                if entries.isEmpty {
                    throw ArchiveProviderError.readFailed(message)
                }
                warning = message
                break
            }
        }

        return ArchiveListing(
            archiveURL: url,
            formatDescription: detectedFormat,
            entries: entries,
            warning: warning
        )
    }

    func extractEntry(_ entryPath: String, from archiveURL: URL, to destinationURL: URL) throws {
        guard let archive = archive_read_new() else {
            throw ArchiveProviderError.couldNotCreateReader
        }
        defer { archive_read_free(archive) }

        guard archive_read_support_filter_all(archive) == archiveOK,
              archive_read_support_format_all(archive) == archiveOK else {
            throw ArchiveProviderError.readFailed(errorMessage(from: archive))
        }

        let openStatus = archiveURL.withUnsafeFileSystemRepresentation { path in
            archive_read_open_filename(archive, path, 64 * 1024)
        }
        guard openStatus == archiveOK else {
            throw ArchiveProviderError.openFailed(archiveURL, errorMessage(from: archive))
        }

        let targetPath = entryPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        while true {
            var entryPointer: OpaquePointer?
            let status = archive_read_next_header(archive, &entryPointer)

            if status == archiveEOF {
                break
            }

            if status < archiveWarn {
                throw ArchiveProviderError.readFailed(errorMessage(from: archive))
            }

            guard let entryPointer,
                  let path = normalizedPath(from: entryPointer),
                  path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == targetPath else {
                let skipStatus = archive_read_data_skip(archive)
                if skipStatus < archiveWarn {
                    throw ArchiveProviderError.readFailed(errorMessage(from: archive))
                }
                continue
            }

            guard archive_entry_filetype(entryPointer) != archiveEntryDirectory else {
                throw ArchiveProviderError.readFailed("\(entryPath) is a folder.")
            }

            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)

            let handle = try FileHandle(forWritingTo: destinationURL)
            defer { try? handle.close() }

            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                    archive_read_data(archive, rawBuffer.baseAddress, rawBuffer.count)
                }

                if bytesRead == 0 {
                    break
                }
                if bytesRead < 0 {
                    throw ArchiveProviderError.readFailed(errorMessage(from: archive))
                }

                try handle.write(contentsOf: Data(buffer.prefix(bytesRead)))
            }

            if archive_entry_mtime_is_set(entryPointer) != 0 {
                let seconds = TimeInterval(archive_entry_mtime(entryPointer))
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: seconds)],
                    ofItemAtPath: destinationURL.path
                )
            }
            return
        }

        throw ArchiveProviderError.entryNotFound(entryPath)
    }

    private func makeEntry(from entryPointer: OpaquePointer, path: String) -> ArchiveEntry {
        let fileType = archive_entry_filetype(entryPointer)
        let directory = fileType == archiveEntryDirectory || path.hasSuffix("/")
        let size = archive_entry_size_is_set(entryPointer) != 0 ? archive_entry_size(entryPointer) : nil
        let date: Date?
        if archive_entry_mtime_is_set(entryPointer) != 0 {
            let seconds = TimeInterval(archive_entry_mtime(entryPointer))
            let nanoseconds = TimeInterval(archive_entry_mtime_nsec(entryPointer)) / 1_000_000_000
            date = Date(timeIntervalSince1970: seconds + nanoseconds)
        } else {
            date = nil
        }

        return ArchiveEntry(
            path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            isDirectory: directory,
            size: size,
            modificationDate: date,
            kindDescription: kindDescription(for: path, isDirectory: directory, isEncrypted: archive_entry_is_encrypted(entryPointer) != 0),
            isEncrypted: archive_entry_is_encrypted(entryPointer) != 0
        )
    }

    private func kindDescription(for path: String, isDirectory: Bool, isEncrypted: Bool) -> String {
        if isDirectory {
            return isEncrypted ? "Encrypted Folder" : "Folder"
        }

        let ext = (path as NSString).pathExtension
        let base = ext.isEmpty ? "File" : (UTType(filenameExtension: ext)?.localizedDescription ?? "File")
        return isEncrypted ? "Encrypted \(base)" : base
    }

    private func normalizedPath(from entryPointer: OpaquePointer) -> String? {
        let rawPath = string(from: archive_entry_pathname_utf8(entryPointer))
            ?? string(from: archive_entry_pathname(entryPointer))
        guard var path = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }

        while path.hasPrefix("./") {
            path.removeFirst(2)
        }
        while path.hasPrefix("/") {
            path.removeFirst()
        }
        return path
    }

    private func errorMessage(from archive: OpaquePointer?) -> String {
        string(from: archive_error_string(archive)) ?? "Unknown archive error"
    }

    private func string(from pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        return String(validatingUTF8: pointer)
    }
}

private let archiveOK: Int32 = 0
private let archiveEOF: Int32 = 1
private let archiveWarn: Int32 = -20
private let archiveEntryDirectory: UInt32 = 0o040000

@_silgen_name("archive_read_new")
private func archive_read_new() -> OpaquePointer?

@_silgen_name("archive_read_free")
@discardableResult
private func archive_read_free(_ archive: OpaquePointer?) -> Int32

@_silgen_name("archive_read_support_filter_all")
@discardableResult
private func archive_read_support_filter_all(_ archive: OpaquePointer?) -> Int32

@_silgen_name("archive_read_support_format_all")
@discardableResult
private func archive_read_support_format_all(_ archive: OpaquePointer?) -> Int32

@_silgen_name("archive_read_open_filename")
@discardableResult
private func archive_read_open_filename(_ archive: OpaquePointer?, _ filename: UnsafePointer<CChar>?, _ blockSize: Int) -> Int32

@_silgen_name("archive_read_next_header")
@discardableResult
private func archive_read_next_header(_ archive: OpaquePointer?, _ entry: UnsafeMutablePointer<OpaquePointer?>?) -> Int32

@_silgen_name("archive_read_data_skip")
@discardableResult
private func archive_read_data_skip(_ archive: OpaquePointer?) -> Int32

@_silgen_name("archive_read_data")
private func archive_read_data(_ archive: OpaquePointer?, _ buffer: UnsafeMutableRawPointer?, _ length: Int) -> Int

@_silgen_name("archive_error_string")
private func archive_error_string(_ archive: OpaquePointer?) -> UnsafePointer<CChar>?

@_silgen_name("archive_format_name")
private func archive_format_name(_ archive: OpaquePointer?) -> UnsafePointer<CChar>?

@_silgen_name("archive_entry_pathname_utf8")
private func archive_entry_pathname_utf8(_ entry: OpaquePointer?) -> UnsafePointer<CChar>?

@_silgen_name("archive_entry_pathname")
private func archive_entry_pathname(_ entry: OpaquePointer?) -> UnsafePointer<CChar>?

@_silgen_name("archive_entry_filetype")
private func archive_entry_filetype(_ entry: OpaquePointer?) -> UInt32

@_silgen_name("archive_entry_size")
private func archive_entry_size(_ entry: OpaquePointer?) -> Int64

@_silgen_name("archive_entry_size_is_set")
private func archive_entry_size_is_set(_ entry: OpaquePointer?) -> Int32

@_silgen_name("archive_entry_mtime")
private func archive_entry_mtime(_ entry: OpaquePointer?) -> Int64

@_silgen_name("archive_entry_mtime_nsec")
private func archive_entry_mtime_nsec(_ entry: OpaquePointer?) -> Int64

@_silgen_name("archive_entry_mtime_is_set")
private func archive_entry_mtime_is_set(_ entry: OpaquePointer?) -> Int32

@_silgen_name("archive_entry_is_encrypted")
private func archive_entry_is_encrypted(_ entry: OpaquePointer?) -> Int32
