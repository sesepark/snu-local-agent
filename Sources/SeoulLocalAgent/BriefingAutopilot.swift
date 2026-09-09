import Foundation
import AppKit
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// 밤에 아무도 쓰지 않을 때 브리핑을 스스로 한 번 돌리는 자리.
///
/// **이 앱은 지금까지 로그인·화면 열기·잠자기 해제 어느 것으로도 수집이나 추론을 시작하지
/// 않았고, 그 약속은 그대로다.** 여기서 더해지는 것은 그 셋과 다른 종류의 방아쇠다 —
/// 사건이 아니라 **상태**를 보고, 사람이 설정에서 직접 켠 경우에만 돈다. 화면을 열었다고,
/// 깨어났다고 도는 일은 여전히 없다.
///
/// 화면(뚜껑)이 닫히면 이 Mac은 잠들고, 잠든 동안에는 아무것도 돌지 않는다. 그래서 이
/// 방식이 실제로 걸리는 창은 **뚜껑을 열어 둔 채 전원을 꽂고 자리를 비운 밤**이다.
/// 예약 기상(`pmset repeat`)이나 launch agent 없이 얻을 수 있는 것은 여기까지이고,
/// 그 사실을 화면이 숨기지 않고 말한다.
enum BriefingAutopilot {
    /// 사람이 손을 뗀 것으로 보는 시간.
    ///
    /// 20분인 이유: 강의 노트를 읽다가 잠깐 자리를 비운 것과 자러 간 것을 가르는 선이고,
    /// AC에서 화면이 꺼지는 180분보다 한참 짧아 시스템이 잠들기 전에 걸린다.
    static let idleThreshold: TimeInterval = 20 * 60

    /// 같은 밤에 두 번 돌지 않게 하는 간격.
    static let minimumInterval: TimeInterval = 8 * 3600

    /// 이만큼 연달아 실패하면 그만둔다. 실패하는 이유가 무엇이든, 밤새 같은 실패를
    /// 반복하는 것은 고치는 데 도움이 되지 않고 배터리와 열만 쓴다.
    static let failureLimit = 2

    /// 왜 지금 돌지 않는가. **`nil`이 아니면 그 이유를 화면에 그대로 적는다.**
    ///
    /// 자동화는 안 돌았을 때 그 이유를 말해 주지 않으면 고장과 구별되지 않는다. 사람이
    /// 아침에 보는 것은 "어젯밤에 돌았나?"이고, 답이 "아니오"라면 곧바로 "왜?"가 따라온다.
    enum Blocker: Equatable {
        case disabled
        case outsideWindow(start: Int, end: Int)
        case onBattery
        case lidClosed
        case inUse(idleSeconds: Int)
        case busy(String)
        case hot
        case tooSoon(nextAt: Date)
        case failedTooOften

        var reason: String {
            switch self {
            case .disabled: return "자동 실행이 꺼져 있습니다"
            case .outsideWindow(let start, let end): return "실행 시간대(\(start)시–\(end)시)가 아닙니다"
            case .onBattery: return "전원이 연결되어 있지 않습니다"
            case .lidClosed: return "노트북이 닫혀 있습니다 — 닫히면 이 Mac은 잠들고, 잠든 동안에는 돌지 않습니다"
            case .inUse(let idle): return "아직 쓰고 있습니다 (\(idle / 60)분째 조용함 · \(Int(idleThreshold) / 60)분 필요)"
            case .busy(let what): return "\(what)이(가) 돌고 있습니다"
            case .hot: return "기기가 뜨거워 미룹니다"
            case .tooSoon(let next):
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "ko_KR")
                formatter.dateFormat = "M월 d일 HH시"
                return "최근에 이미 정리했습니다 (다음 가능 \(formatter.string(from: next)))"
            case .failedTooOften: return "자동 실행이 연달아 실패해 멈췄습니다. 한 번 직접 돌려 보세요"
            }
        }
    }

    /// 판단에 쓰는 값 전부. **바깥에서 읽어 넣는 이유는 이 결정을 시험할 수 있게 하기
    /// 위해서다** — 전원과 유휴 시간을 함수 안에서 직접 읽으면, 이 규칙을 확인하려면
    /// 실제로 밤에 전원을 뽑고 20분을 기다리는 수밖에 없다.
    struct Conditions {
        var isEnabled: Bool
        var now: Date
        var startHour: Int
        var windowHours: Int
        var isOnPower: Bool
        var isLidClosed: Bool
        var idleSeconds: TimeInterval
        /// 지금 돌고 있는 다른 일의 이름. 없으면 `nil`.
        var busyWith: String?
        var isHot: Bool
        var lastAttemptAt: Date?
        var consecutiveFailures: Int
    }

    /// 지금 돌아도 되는가. `nil`이면 돌아도 된다.
    static func blocker(_ conditions: Conditions) -> Blocker? {
        guard conditions.isEnabled else { return .disabled }
        if conditions.consecutiveFailures >= failureLimit { return .failedTooOften }
        let end = (conditions.startHour + conditions.windowHours) % 24
        guard isWithinWindow(conditions.now, start: conditions.startHour, hours: conditions.windowHours) else {
            return .outsideWindow(start: conditions.startHour, end: end)
        }
        // 전원을 뚜껑보다 먼저 본다. 배터리로는 어차피 돌리지 않으므로, 닫혀 있다는 말보다
        // 꽂으라는 말이 사람이 할 수 있는 일에 가깝다.
        guard conditions.isOnPower else { return .onBattery }
        guard !conditions.isLidClosed else { return .lidClosed }
        if let busy = conditions.busyWith { return .busy(busy) }
        guard !conditions.isHot else { return .hot }
        if let last = conditions.lastAttemptAt, conditions.now.timeIntervalSince(last) < minimumInterval {
            return .tooSoon(nextAt: last.addingTimeInterval(minimumInterval))
        }
        guard conditions.idleSeconds >= idleThreshold else { return .inUse(idleSeconds: Int(conditions.idleSeconds)) }
        return nil
    }

    /// 자정을 넘어가는 시간대(예: 23시–3시)도 맞게 판단한다.
    static func isWithinWindow(_ date: Date, start: Int, hours: Int) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let hour = calendar.component(.hour, from: date)
        guard hours < 24 else { return true }
        let end = (start + hours) % 24
        return start <= end ? (hour >= start && hour < end) : (hour >= start || hour < end)
    }

    // MARK: 기기에게 묻는 것들

    /// 전원이 꽂혀 있는가.
    static var isOnPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            // 배터리가 없는 기기에서는 목록이 비어 있다. 그때는 늘 전원이 있는 것이다.
            return true
        }
        guard !sources.isEmpty else { return true }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey] as? String else { continue }
            if state == kIOPSACPowerValue { return true }
        }
        return false
    }

    /// 마지막으로 사람이 무언가를 누르거나 움직인 뒤 흐른 시간.
    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .init(rawValue: ~0)!)
    }

    static var isHot: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: true
        default: false
        }
    }
}

/// 도는 동안 이 Mac이 유휴로 잠들지 않게 잡아 두는 표.
///
/// 이것이 없으면 3분짜리 실행이 절반에서 끊긴다 — 사람이 손을 뗀 상태에서 도는 것이
/// 전제이므로, 도는 내내 유휴이기 때문이다.
///
/// **뚜껑을 닫아 자는 것은 막지 않는다.** 그것은 사람이 분명하게 한 행동이고, 그것까지
/// 막으면 가방 안에서 계속 도는 노트북이 된다.
final class SleepGuard {
    private var assertion: IOPMAssertionID = 0
    private var held = false

    func hold(_ reason: String) {
        guard !held else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        guard result == kIOReturnSuccess else { return }
        assertion = id
        held = true
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(assertion)
        held = false
        assertion = 0
    }

    deinit { if held { IOPMAssertionRelease(assertion) } }
}
