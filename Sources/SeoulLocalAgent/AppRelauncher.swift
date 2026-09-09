import AppKit
import Foundation

/// 앱을 끄고 같은 번들을 다시 켠다.
///
/// 코드를 고쳐 번들을 다시 만든 뒤 끄고 켜는 일이 잦아 만든 단추다. 프로세스는 자기 자신을
/// 다시 켤 수 없다 — 끝나는 순간 그 일을 할 손이 없다. 그래서 셸 한 줄을 떼어 놓고 끝낸다:
/// 그 셸은 우리 PID가 사라지기를 기다렸다가 같은 경로를 `open`으로 연다. 번들 밖(SwiftPM
/// 디버그 바이너리)에서 돌 때는 실행 파일을 같은 인자로 다시 띄운다.
///
/// 종료는 `NSApp.terminate`로 정상 경로를 밟으므로 터널·카메라·헬퍼 정리가 그대로 된다.
/// 떼어 놓은 셸은 이 앱의 "자식을 남기지 않는다" 규칙의 유일한 의도된 예외이고, 앱이 다시
/// 뜨는 순간 끝난다. 종료가 취소되어(녹음 중 확인 창 등) 우리가 살아 있으면 셸은 60초 뒤
/// 아무 일도 하지 않고 끝난다 — 두 번째 인스턴스를 만들지 않는다.
enum AppRelauncher {
    /// 다시 켤 때 열어 둘 화면. 고치던 화면으로 바로 돌아오게 한다.
    @MainActor
    static func relaunch(section: String?) {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let command = shellCommand(
            pid: pid, bundle: Bundle.main.bundleURL, executable: Bundle.main.executableURL,
            arguments: Array(CommandLine.arguments.dropFirst()), section: section
        ) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        // 부모가 죽어도 살아야 하는 유일한 자식이다. 표준 입출력을 어디에도 묶지 않는다 —
        // 우리 파이프에 묶이면 우리가 끝나는 순간 SIGPIPE로 함께 죽는다.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
    }

    /// 떼어 놓을 셸 한 줄. 화면에서 떼어 둔 것은 인용과 대기 조건을 시험으로 박아 두기 위해서다.
    ///
    /// `kill -0`은 그 PID가 살아 있는지만 묻는다. 0.2초마다 물어 사라지면 연다. 300번(60초)
    /// 넘게 살아 있으면 종료가 취소된 것이므로 그냥 끝난다.
    static func shellCommand(
        pid: Int32, bundle: URL, executable: URL?, arguments: [String], section: String?
    ) -> String? {
        let wait = "i=0; while /bin/kill -0 \(pid) 2>/dev/null; do i=$((i+1)); [ $i -ge 300 ] && exit 0; /bin/sleep 0.2; done; "
        if bundle.pathExtension == "app" {
            var line = wait + "/usr/bin/open -n \(quote(bundle.path))"
            if let section, !section.isEmpty {
                line += " --args --section \(quote(section))"
            }
            return line
        }
        guard let executable else { return nil }
        var passed = arguments
        if let index = passed.firstIndex(of: "--section"), index + 1 < passed.count {
            passed.removeSubrange(index...index + 1)
        }
        if let section, !section.isEmpty {
            passed += ["--section", section]
        }
        let rest = ([executable.path] + passed).map(quote).joined(separator: " ")
        // 번들이 아니면 `open`이 열 수 없으므로 실행 파일을 배경으로 직접 띄운다.
        return wait + "\(rest) >/dev/null 2>&1 &"
    }

    /// 셸에 안전하게 넘길 인용. 홑따옴표 안에서는 홑따옴표만 특별하다.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
