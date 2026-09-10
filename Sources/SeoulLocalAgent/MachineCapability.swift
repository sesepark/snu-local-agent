import Foundation

/// What this Mac can actually run locally, and which model that implies.
///
/// The app was built on a 64GB M2 Max, but it is published for other members to
/// download, and their Macs may have 16GB. Rather than sorting machines into
/// named tiers, this applies one rule: **the weights have to fit in half of
/// physical memory.** Unified memory is shared with the OS, the app, and every
/// other process; past roughly half, nothing crashes — the machine simply starts
/// swapping and everything gets slower without saying so. `MinerU.virtualVRAMGigabytes`
/// already follows the machine for the same reason, and this is that idea applied
/// to the language model.
enum LocalModelCatalog {
    struct Entry: Sendable, Equatable, Identifiable {
        /// The Ollama tag, exactly as `ollama pull` wants it.
        let tag: String
        /// Download size in GiB, measured against registry.ollama.ai on 2026-09-09.
        /// Weights dominate resident size, so this is what gets compared to the budget.
        let gigabytes: Double
        let summary: String

        var id: String { tag }
        /// What the user needs to type to get it.
        var pullCommand: String { "ollama pull \(tag)" }
    }

    static let qwen36 = Entry(tag: "qwen3.6:35b-a3b-nvfp4", gigabytes: 22.0,
                              summary: "35B 중 3B만 활성. 이 앱이 기준으로 삼고 실측한 모델입니다.")
    static let qwen3 = Entry(tag: "qwen3:30b-a3b-q4_K_M", gigabytes: 17.3,
                             summary: "30B 중 3B 활성. 36GB 맥까지 내려갑니다.")
    static let gptOSS = Entry(tag: "gpt-oss:20b", gigabytes: 12.8,
                              summary: "20B 중 3.6B 활성. 32GB 맥에서 쓸 수 있는 가장 큰 선택입니다.")

    /// Largest first. All three are 4-bit MoE: at equal memory a mixture-of-experts
    /// activates a fraction of its parameters per token, so it answers several times
    /// faster than a dense model of the same footprint, which is why no dense entry
    /// appears here.
    static let entries: [Entry] = [qwen36, qwen3, gptOSS]

    /// 국산 모델. 자동 선택 목록에는 넣지 않는다 — 위 세 개는 전부 MoE라 같은 메모리에서
    /// 몇 배 빠르고, EXAONE은 조밀(dense) 모델이라 자동으로 고르면 느려진 이유를 사용자가
    /// 알 수 없다. 대신 설정에서 한 번 눌러 고를 수 있게 따로 둔다. 한국어 공지와 메일이
    /// 입력의 대부분이라, 한국어로 학습된 모델을 쓰고 싶다는 선택은 근거가 있다.
    static let exaone78 = Entry(tag: "exaone3.5:7.8b", gigabytes: 4.8,
                                summary: "LG AI Research의 한국어·영어 모델. 16GB 맥에서도 돕니다.")
    static let exaone32 = Entry(tag: "exaone3.5:32b", gigabytes: 19.0,
                                summary: "같은 계열의 큰 쪽. 48GB 이상에서 권합니다.")
    static let exaone24 = Entry(tag: "exaone3.5:2.4b", gigabytes: 1.6,
                                summary: "가장 작은 국산 선택. 8GB 맥의 마지막 수단입니다.")

    /// 큰 것부터. 화면은 이 순서대로 보여 주고, 맞지 않는 것은 흐리게 둔다.
    static let koreanEntries: [Entry] = [exaone32, exaone78, exaone24]

    /// Named when nothing fits. The app will not run it on such a machine, but the
    /// readiness screen still needs something concrete to talk about.
    static var smallest: Entry { gptOSS }

    /// The largest entry whose weights fit the budget, or `nil` when even the
    /// smallest one does not.
    static func largestFitting(gigabytes budget: Double) -> Entry? {
        entries.first { $0.gigabytes <= budget }
    }

    static func entry(tagged tag: String) -> Entry? {
        (entries + koreanEntries).first { $0.tag == tag }
    }
}

/// A measurement of this machine, taken once at launch.
struct MachineCapability: Sendable, Equatable {
    let physicalMemoryGigabytes: Double
    /// `Apple M2 Max`, or whatever `sysctl` reports. Shown to the user so they can
    /// tell at a glance that the app looked at the right machine.
    let chip: String

    /// Half of physical memory. The other half is not spare — it is the OS, this
    /// app's own screens, the transcription runner, and whatever else is open.
    var modelBudgetGigabytes: Double { physicalMemoryGigabytes / 2 }

    /// The model this machine should use, before the user overrides anything.
    var fittingModel: LocalModelCatalog.Entry? {
        LocalModelCatalog.largestFitting(gigabytes: modelBudgetGigabytes)
    }

    /// Whether running a language model on this Mac is realistic at all. When it
    /// is not, the app does not pretend: the local pipeline is switched off and the
    /// briefing asks for a remote key instead of failing halfway through.
    var canRunLocalModel: Bool { fittingModel != nil }

    static func measure() -> MachineCapability {
        MachineCapability(
            physicalMemoryGigabytes: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
            chip: Self.sysctlString("machdep.cpu.brand_string")
                ?? Self.sysctlString("hw.model")
                ?? "알 수 없는 기종"
        )
    }

    /// Measured once. Physical memory does not change while the app runs, and every
    /// screen that asks should get the same answer.
    static let current = MachineCapability.measure()

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// One line for the readiness screen: what was measured and what follows from it.
    var summary: String {
        let memory = String(format: "%.0f", physicalMemoryGigabytes.rounded())
        guard let model = fittingModel else {
            return "\(chip) · 메모리 \(memory)GB — 로컬 모델을 돌리기에는 부족합니다."
        }
        return "\(chip) · 메모리 \(memory)GB — \(model.tag)까지 감당합니다."
    }
}
