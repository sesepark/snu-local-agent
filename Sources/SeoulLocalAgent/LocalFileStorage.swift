import Foundation

/// Every local file this app owns holds personal data, so it is written with
/// owner-only permissions from the moment it is created rather than being
/// relaxed for the window between `write` and a later `chmod`. The write is
/// staged through a temporary file so a crash or a full disk can never leave a
/// truncated state file, preference file, or transcript archive behind.
enum LocalFileStorage {
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
/// the bundle `build-app-bundle.sh` writes into `dist/`. The last resort is the
/// conventional place to clone this repository, so an app copied somewhere odd
/// still has one more guess before it gives up.
enum ProjectRoot {
    static let fallback = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appending(path: "Projects/snu-local-agent", directoryHint: .isDirectory).path

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

    // MARK: - 체크아웃 없이 받은 앱

    /// 러너 스크립트가 실제로 있는 자리.
    ///
    /// `.dmg`로 앱만 받은 사람에게는 체크아웃이 없다. 그래서 빌드할 때 `scripts/`를
    /// 번들 안에 함께 넣고, 있으면 그쪽을 먼저 쓴다. 개발 중에는 번들이 없거나
    /// 오래된 사본일 수 있으므로 체크아웃이 그다음이다.
    static func script(_ name: String) -> String {
        let bundled = Bundle.main.bundleURL
            .appending(path: "Contents/Resources/scripts", directoryHint: .isDirectory)
            .appending(path: name).path
        if FileManager.default.fileExists(atPath: bundled) { return bundled }
        return resolving("scripts/\(name)")
    }

    /// 파이썬 가상환경이 사는 자리.
    ///
    /// 번들 안에 둘 수 없다 — 서명된 앱 번들은 읽기 전용이고, 거기에 무언가를 쓰면
    /// 서명이 깨져 Gatekeeper가 앱을 막는다. 그래서 언제나 사용자 폴더 아래다.
    static let venvsDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appending(path: "Library/Application Support/SeoulLocalAgent/venvs", directoryHint: .isDirectory)

    /// 새 자리를 먼저 보고, 없으면 체크아웃 안의 옛 자리를 쓴다. 이미 예전 방식으로
    /// 환경을 만들어 둔 사람의 설치를 깨지 않기 위한 것이다.
    static func venv(_ relativePath: String) -> String {
        let current = venvsDirectory.appending(path: relativePath).path
        if FileManager.default.fileExists(atPath: current) { return current }
        let legacy = resolving(relativePath)
        return FileManager.default.fileExists(atPath: legacy) ? legacy : current
    }
}
