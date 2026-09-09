#if canImport(Testing)
import Testing
import Foundation
@testable import SeoulLocalAgent

/// 밤에 스스로 도는 판단.
///
/// 이 결정만은 반드시 순수 함수로 시험한다. 전원과 유휴 시간을 함수 안에서 직접 읽으면,
/// 규칙 하나를 확인하려면 실제로 밤에 전원을 뽑고 20분을 기다리는 수밖에 없다.
@Suite("자동 브리핑 조건")
struct BriefingAutopilotTests {

    private func conditions(
        enabled: Bool = true, hour: Int = 2, onPower: Bool = true, lidClosed: Bool = false,
        idle: TimeInterval = 30 * 60, busy: String? = nil, hot: Bool = false,
        lastAttempt: Date? = nil, failures: Int = 0
    ) -> BriefingAutopilot.Conditions {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(bySettingHour: hour, minute: 30, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!
        return BriefingAutopilot.Conditions(
            isEnabled: enabled, now: now, startHour: 1, windowHours: 5,
            isOnPower: onPower, isLidClosed: lidClosed, idleSeconds: idle,
            busyWith: busy, isHot: hot, lastAttemptAt: lastAttempt, consecutiveFailures: failures
        )
    }

    @Test("조건이 모두 맞으면 돈다")
    func runsWhenEverythingLinesUp() {
        #expect(BriefingAutopilot.blocker(conditions()) == nil)
    }

    @Test("켜지 않았으면 아무 조건도 보지 않는다")
    func offMeansOff() {
        // 사람이 켜지 않은 자동 실행은 자동화가 아니라 놀라운 일이다.
        #expect(BriefingAutopilot.blocker(conditions(enabled: false)) == .disabled)
    }

    @Test("전원·뚜껑·사용 중·다른 작업·열은 각각 막는다")
    func everyGuardBlocks() {
        #expect(BriefingAutopilot.blocker(conditions(onPower: false)) == .onBattery)
        // 닫히면 이 Mac은 잠든다. 시작해 봐야 곧바로 끊긴다.
        #expect(BriefingAutopilot.blocker(conditions(lidClosed: true)) == .lidClosed)
        #expect(BriefingAutopilot.blocker(conditions(idle: 60)) == .inUse(idleSeconds: 60))
        #expect(BriefingAutopilot.blocker(conditions(busy: "전사")) == .busy("전사"))
        #expect(BriefingAutopilot.blocker(conditions(hot: true)) == .hot)
    }

    @Test("시간대 밖에서는 돌지 않는다")
    func outsideTheWindow() {
        guard case .outsideWindow(let start, let end)? = BriefingAutopilot.blocker(conditions(hour: 14)) else {
            Issue.record("시간대 밖인데 막히지 않았습니다"); return
        }
        #expect(start == 1)
        #expect(end == 6)
    }

    @Test("자정을 넘어가는 시간대도 맞게 판단한다")
    func windowCanCrossMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ hour: Int) -> Date { calendar.date(bySettingHour: hour, minute: 30, second: 0, of: base)! }
        // 23시 시작, 4시간 → 23·0·1·2시가 안이고 3시는 밖이다.
        #expect(BriefingAutopilot.isWithinWindow(at(23), start: 23, hours: 4))
        #expect(BriefingAutopilot.isWithinWindow(at(0), start: 23, hours: 4))
        #expect(BriefingAutopilot.isWithinWindow(at(2), start: 23, hours: 4))
        #expect(!BriefingAutopilot.isWithinWindow(at(3), start: 23, hours: 4))
        #expect(!BriefingAutopilot.isWithinWindow(at(12), start: 23, hours: 4))
    }

    @Test("하루에 한 번만 돈다")
    func onlyOncePerNight() {
        let now = conditions().now
        // 방금 돌았으면 같은 밤에 또 돌지 않는다.
        guard case .tooSoon? = BriefingAutopilot.blocker(conditions(lastAttempt: now.addingTimeInterval(-3_600))) else {
            Issue.record("한 시간 전에 돌았는데 또 돌려 합니다"); return
        }
        // 여덟 시간이 지났으면 다시 돈다.
        #expect(BriefingAutopilot.blocker(conditions(lastAttempt: now.addingTimeInterval(-9 * 3_600))) == nil)
    }

    @Test("연달아 실패하면 멈추고 사람을 부른다")
    func stopsAfterRepeatedFailures() {
        // 밤새 같은 실패를 반복하는 것은 고치는 데 도움이 되지 않고 배터리와 열만 쓴다.
        #expect(BriefingAutopilot.blocker(conditions(failures: 1)) == nil)
        #expect(BriefingAutopilot.blocker(conditions(failures: 2)) == .failedTooOften)
    }

    @Test("막힌 이유는 사람이 읽을 수 있는 한 문장이다")
    func everyBlockerExplainsItself() {
        let blockers: [BriefingAutopilot.Blocker] = [
            .disabled, .outsideWindow(start: 1, end: 6), .onBattery, .lidClosed,
            .inUse(idleSeconds: 120), .busy("전사"), .hot,
            .tooSoon(nextAt: Date(timeIntervalSince1970: 1_800_000_000)), .failedTooOften,
        ]
        for blocker in blockers {
            #expect(!blocker.reason.isEmpty)
            // 화면에 그대로 나가는 문장이므로 자리표시자가 남아 있으면 안 된다.
            #expect(!blocker.reason.contains("Optional"))
        }
    }
}
#endif
