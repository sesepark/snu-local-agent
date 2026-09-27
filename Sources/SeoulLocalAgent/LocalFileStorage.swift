import Foundation

/// Every local file this app owns holds personal data, so it is written with
/// owner-only permissions from the moment it is created rather than being
/// relaxed for the window between `write` and a later `chmod`. The write is
/// staged through a temporary file so a crash or a full disk can never leave a
/// truncated state file, preference file, or transcript archive behind.
enum LocalFileStorage {
    static func copyPreservingDestination(_ source: URL, to target: URL) throws {
        if source.standardizedFileURL == target.standardizedFileURL { return }
        let staged = target.deletingLastPathComponent().appending(path: ".export-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: target)
        }
    }
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw AgentError.processFailed("폴더를 만들지 못했습니다 [\(directory.path)]: \(error.localizedDescription)")
        }
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw AgentError.processFailed("파일을 쓰지 못했습니다 [\(url.path)]")
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw AgentError.processFailed("파일을 교체하지 못했습니다 [\(url.path)]: \(error.localizedDescription)")
        }
        // `replaceItemAt` can carry the previous file's permissions forward.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Where this checkout lives.
///
/// Four features shell out to a Python environment inside the project folder,
/// and every one of them had the author's own absolute path compiled in. Moving
/// or renaming the folder broke all four at once, each with a message naming a
/// setup script at a path that no longer existed. The environment variable comes
/// first so the location can be stated outright; otherwise the app walks up from
/// its own binary, which is correct both for `swift run` out of `.build` and for
/// the bundle `build-app-bundle.sh` writes into `dist/`. The original path stays
/// as the last resort so an app copied elsewhere still finds a working checkout.
enum ProjectRoot {
    static let fallback = "/Users/sehwan/Projects/local_llm"

    /// A folder is the checkout when it holds the `scripts` directory these
    /// helpers live in — a cheap check that cannot match a random ancestor.
    private static func isCheckout(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let scripts = url.appending(path: "scripts", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: scripts.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static let path: String = {
        if let declared = ProcessInfo.processInfo.environment["SEOUL_LOCAL_AGENT_ROOT"],
           isCheckout(URL(fileURLWithPath: declared, isDirectory: true)) {
            return declared
        }
        var directory = URL(fileURLWithPath: Bundle.main.bundlePath).resolvingSymlinksInPath()
        for _ in 0..<8 {
            directory.deleteLastPathComponent()
            guard directory.path != "/" else { break }
            if isCheckout(directory) { return directory.path }
        }
        return fallback
    }()

    static func resolving(_ relativePath: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).appending(path: relativePath).path
    }
}
