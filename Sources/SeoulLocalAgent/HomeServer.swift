import Foundation

/// 프린터가 붙어 있는 집 서버 하나를 가리키는 설정.
///
/// 이 앱에서 SSH 너머로 닿는 기계는 프린터 서버 하나뿐이다. 주소와 계정은 개인 정보라
/// 소스에 박지 않고, `GmailAccountStore`와 같은 규칙으로 이 기기 안의 파일에만 둔다.
/// 설정하지 않으면 프린트 화면은 아무것도 하지 않는다 — 앱을 처음 받은 사람에게는
/// 그 상태가 기본값이다.
struct HomeServer: Codable, Equatable, Sendable {
    /// 집에서 쓰는 주소. LAN의 고정 IP이거나 호스트 이름이다.
    var host = ""
    /// 집 밖에서 쓰는 주소. 비워 두어도 된다.
    ///
    /// 같은 서버로 가는 **두 번째 길**이다. 맥이 집 네트워크를 벗어나면 LAN 주소는 닿지
    /// 않는데, 서버가 Tailscale 같은 것으로 같은 사설망에 있으면 그 주소로는 여전히 닿는다.
    /// 두 칸을 두고 먼저 열리는 쪽을 쓰면 어디에 있든 같은 화면이 뜬다.
    ///
    /// 주소를 하나로 합치지 않은 이유: 사설망 주소만 남기면 그 사설망이 꺼져 있을 때
    /// **집에서도** 닿지 못한다. 집 안에서 쓰는 길과 밖에서 쓰는 길은 서로의 대비책이다.
    var alternateHost = ""
    var user = ""
    var sshPort = 22

    var isConfigured: Bool {
        !candidateHosts.isEmpty && !user.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 시도해 볼 주소들. 적어 둔 순서대로이고, 빈 칸과 중복은 빠진다.
    var candidateHosts: [String] {
        var seen = Set<String>()
        return [host, alternateHost]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func sshTarget(host: String) -> String {
        "\(user.trimmingCharacters(in: .whitespaces))@\(host)"
    }

    /// 화면에 적을 이름. 첫 번째 후보 주소를 쓴다.
    var sshTarget: String { sshTarget(host: candidateHosts.first ?? "") }

    static func validPort(_ value: Int) -> Int { min(max(value, 1), 65535) }

    /// 없는 키는 기본값으로 둔다.
    ///
    /// Swift가 합성해 주는 디코더는 **기본값이 있어도** 키가 없으면 실패한다. 설정 파일은
    /// 앱보다 오래 살아 있는 것이므로, 필드가 늘거나 줄어도 읽히는 편이 옳다.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? ""
        alternateHost = try values.decodeIfPresent(String.self, forKey: .alternateHost) ?? ""
        user = try values.decodeIfPresent(String.self, forKey: .user) ?? ""
        sshPort = try values.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22
    }

    init(host: String = "", alternateHost: String = "", user: String = "", sshPort: Int = 22) {
        self.host = host
        self.alternateHost = alternateHost
        self.user = user
        self.sshPort = sshPort
    }

    /// 저장된 파일이 손으로 고쳐졌을 수도 있으므로 읽을 때 한 번 걸러 낸다.
    func sanitised() -> HomeServer {
        HomeServer(
            host: host.trimmingCharacters(in: .whitespaces),
            alternateHost: alternateHost.trimmingCharacters(in: .whitespaces),
            user: user.trimmingCharacters(in: .whitespaces),
            sshPort: Self.validPort(sshPort)
        )
    }
}

struct HomeServerStore: Sendable {
    private let url: URL

    init(directory: URL? = nil) {
        let root = directory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Application Support/SeoulLocalAgent", directoryHint: .isDirectory)
        url = root.appending(path: "home-server.json")
    }

    var debugURL: URL { url }

    func load() -> HomeServer {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(HomeServer.self, from: data) else { return HomeServer() }
        return value.sanitised()
    }

    func save(_ server: HomeServer) throws {
        try LocalFileStorage.write(try JSONEncoder().encode(server.sanitised()), to: url)
    }
}

/// 이 앱만 쓰는 SSH 열쇠 한 쌍.
///
/// 앱은 샌드박스 밖에서도 `~/.ssh`를 읽지 않는다. 터미널에서 되는 접속이 앱에서는 되지
/// 않는 이유가 그것이고, 그래서 열쇠를 따로 만들어 서버에 한 번 등록시킨다. 이 열쇠의
/// 힘은 서버의 `authorized_keys`에서 언제든 지울 수 있다는 데 있다.
struct HomeServerKey: Sendable {
    let directory: URL
    let name: String

    init(directory: URL? = nil, name: String = "home") {
        self.directory = directory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Application Support/SeoulLocalAgent", directoryHint: .isDirectory)
        self.name = name
    }

    var privateKey: URL { directory.appending(path: "\(name)-tunnel-key") }
    var publicKey: URL { directory.appending(path: "\(name)-tunnel-key.pub") }
    /// `~/.ssh/known_hosts`도 같은 이유로 읽을 수 없으므로 여기에 따로 쌓는다.
    var knownHosts: URL { directory.appending(path: "\(name)-known-hosts") }

    var exists: Bool { FileManager.default.fileExists(atPath: privateKey.path) }

    var publicKeyText: String {
        (try? String(contentsOf: publicKey, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 서버에 이 열쇠를 등록하는 명령. 사용자가 한 번 실행한다.
    func authorizationCommand(for server: HomeServer) -> String {
        let port = server.sshPort == 22 ? "" : "-p \(server.sshPort) "
        return "ssh-copy-id \(port)-i '\(publicKey.path)' \(server.sshTarget)"
    }

    /// 없으면 만든다. 암호는 걸지 않는다 — 앱은 암호를 물을 창이 없다.
    @discardableResult
    func ensureExists() throws -> Bool {
        if exists { return false }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 반쯤 만들어진 쌍이 남아 있으면 ssh-keygen이 덮어쓰기를 물어보다 멈춘다.
        try? FileManager.default.removeItem(at: publicKey)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = [
            "-t", "ed25519", "-N", "", "-q",
            "-C", "snu-local-agent-\(name)",
            "-f", privateKey.path,
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw HomeServerError.keyCreationFailed(error.localizedDescription)
        }
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0, exists else {
            throw HomeServerError.keyCreationFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return true
    }
}

enum HomeServerError: LocalizedError, Equatable {
    case keyCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .keyCreationFailed(let detail): "열쇠를 만들지 못했습니다: \(detail)"
        }
    }
}

extension HomeServer {
    /// ssh가 뱉은 stderr 한 줄을 사람이 할 수 있는 조치로 바꾼다.
    ///
    /// 원문을 지우지 않고 **덧붙인다.** 사람이 검색해야 할 때 필요한 것은 원문이고,
    /// 지금 눌러야 할 것을 알려 주는 것은 그 아래 줄이다.
    static func hint(
        for stderr: String, server: HomeServer, key: HomeServerKey = HomeServerKey(),
        settingsPath: String = "설정 › 프린터"
    ) -> String {
        if stderr.contains("Permission denied") {
            // 사용자의 평소 열쇠가 아니라 **이 앱의 열쇠**를 등록해야 한다. 앱은 `~/.ssh`를
            // 읽지 않으므로 터미널에서 되는 접속이 여기서는 되지 않는다.
            return "\(stderr)\n이 앱 전용 공개키가 서버에 등록되어 있지 않습니다. 터미널에서 아래를 한 번 실행하세요 (\(settingsPath)에서 복사할 수 있습니다):\n\(key.authorizationCommand(for: server))"
        }
        if stderr.contains("Host key verification failed") {
            return "\(stderr)\n서버의 host key가 처음 본 것과 달라졌습니다. 서버를 다시 설치한 것이 맞다면 \(key.knownHosts.lastPathComponent) 파일에서 해당 줄을 지우고 다시 시도하세요."
        }
        if stderr.contains("Could not resolve hostname") {
            return "\(stderr)\n\(settingsPath)의 주소를 확인하세요."
        }
        if stderr.contains("No route to host") || stderr.contains("Operation timed out") {
            let common = "\(stderr)\n서버가 켜져 있고 같은 네트워크에 있는지 확인하세요. 처음이라면 macOS의 로컬 네트워크 접근 허용을 묻는 창이 떴는지도 보세요."
            if server.candidateHosts.count < 2 {
                return common + "\n집 밖에서도 쓰려면 \(settingsPath)의 `집 밖에서 쓸 주소`에 사설망 주소를 넣으세요."
            }
            return common + "\n집 밖이라면 사설망이 이 Mac과 서버 양쪽에서 돌고 있는지도 확인하세요."
        }
        return stderr
    }

    /// 여러 주소를 시도해 모두 실패했을 때의 한 덩어리.
    static func failureText(
        _ failures: [(host: String, reason: String)], server: HomeServer, key: HomeServerKey,
        settingsPath: String = "설정 › 프린터"
    ) -> String {
        guard let first = failures.first else { return "연결할 주소가 없습니다" }
        if failures.count == 1 {
            return hint(for: first.reason, server: server, key: key, settingsPath: settingsPath)
        }
        let lines = failures.map { "· \($0.host): \($0.reason.split(separator: "\n").last.map(String.init) ?? $0.reason)" }
        // 조치 힌트는 **가장 구체적인** 실패에서 만든다. 첫 주소의 사유로만 만들면, 집 밖에서
        // 처음 설정할 때 LAN은 시간 초과이고 사설망은 열쇠 거절인데 힌트는 "같은 네트워크에
        // 있는지"가 되고 정작 필요한 `ssh-copy-id` 명령은 사라진다.
        let telling = failures.first { $0.reason.contains("Permission denied") || $0.reason.contains("Host key") }
            ?? failures.first { $0.reason.contains("Address already in use") || $0.reason.contains("bind") }
            ?? first
        return "적어 둔 주소 어느 쪽으로도 닿지 못했습니다.\n"
            + lines.joined(separator: "\n")
            + "\n"
            + hint(for: telling.reason, server: server, key: key, settingsPath: settingsPath)
    }
}
