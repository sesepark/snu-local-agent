import Foundation
import Testing
@testable import SeoulLocalAgent

@Suite("앱 재시작")
struct AppRelauncherTests {
    /// 번들로 도는 앱은 `open`으로 같은 경로를 다시 열고, 보던 화면으로 돌아온다.
    @Test("번들은 우리 PID가 사라진 뒤 같은 경로를 open으로 연다")
    func relaunchesBundleAfterExit() throws {
        let line = try #require(AppRelauncher.shellCommand(
            pid: 4242, bundle: URL(fileURLWithPath: "/Users/x/dist/Seoul Local Agent.app"),
            executable: nil, arguments: [], section: "soarmRecord"
        ))
        // 살아 있는 동안 기다리고, 60초(300 × 0.2초)가 넘으면 두 번째 인스턴스를 만들지 않고 끝난다.
        #expect(line.contains("while /bin/kill -0 4242"))
        #expect(line.contains("[ $i -ge 300 ] && exit 0"))
        // 공백이 든 경로는 인용되고, 화면 이름이 인자로 따라간다.
        #expect(line.contains("/usr/bin/open -n '/Users/x/dist/Seoul Local Agent.app' --args --section 'soarmRecord'"))
    }

    @Test("번들이 아니면 실행 파일을 같은 인자로 다시 띄우되 화면 인자는 하나만 남긴다")
    func relaunchesBinaryWithArguments() throws {
        let line = try #require(AppRelauncher.shellCommand(
            pid: 7, bundle: URL(fileURLWithPath: "/Users/x/.build/debug"),
            executable: URL(fileURLWithPath: "/Users/x/.build/debug/SeoulLocalAgent"),
            arguments: ["--section", "overview", "--force-dark"], section: "soarmData"
        ))
        #expect(line.hasSuffix("'/Users/x/.build/debug/SeoulLocalAgent' '--force-dark' '--section' 'soarmData' >/dev/null 2>&1 &"))
        #expect(!line.contains("'overview'"))
        // 실행 파일 경로를 모르면 다시 켤 길이 없다.
        #expect(AppRelauncher.shellCommand(
            pid: 7, bundle: URL(fileURLWithPath: "/tmp/debug"), executable: nil, arguments: [], section: nil
        ) == nil)
    }

    @Test("홑따옴표가 든 경로도 셸에 그대로 넘어간다")
    func quotesSingleQuotes() {
        #expect(AppRelauncher.quote("it's") == "'it'\\''s'")
        #expect(AppRelauncher.quote("plain") == "'plain'")
    }
}
