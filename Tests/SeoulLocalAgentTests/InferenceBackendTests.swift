import Foundation
import Testing
@testable import SeoulLocalAgent

/// 판단 위치를 고르는 설정과, 고른 곳이 준비되지 않았을 때 무엇을 말하는지.
///
/// 이 앱의 기본 전제는 "본문이 이 Mac을 떠나지 않는다"이다. 그 전제가 설정 하나로
/// 깨질 수 있게 된 이상, **기본값이 여전히 로컬이라는 것**은 테스트로 붙들어 둔다.
@Suite("판단 위치", .serialized)
struct InferenceBackendTests {
    /// 테스트끼리 UserDefaults를 물려받지 않도록 쓰고 나면 지운다.
    private func withDefaults(_ values: [String: Any], _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = ["inferenceBackend", "inferencePreset", "inferenceBaseURL", "inferenceRemoteModel"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        for (key, value) in values { defaults.set(value, forKey: key) }
        try body()
    }

    @Test("아무것도 고르지 않으면 이 Mac 안에서 판단한다")
    func defaultsToLocal() {
        withDefaults(["inferenceBackend": ""]) {
            #expect(InferenceSettings.backend == .local)
            // 로컬일 때는 원격 설정이 비어 있어도 막을 이유가 없다.
            #expect(InferenceSettings.remoteConfigurationProblem() == nil)
        }
    }

    @Test("프리셋을 고르면 주소와 모델의 기본값이 따라온다")
    func presetSuppliesDefaults() {
        withDefaults(["inferencePreset": RemoteInferencePreset.upstage.id,
                      "inferenceBaseURL": "", "inferenceRemoteModel": ""]) {
            #expect(InferenceSettings.baseURL == "https://api.upstage.ai/v1")
            #expect(InferenceSettings.remoteModel == "solar-pro2")
        }
    }

    @Test("직접 적은 값이 프리셋을 이긴다")
    func explicitValueWins() {
        withDefaults(["inferencePreset": RemoteInferencePreset.upstage.id,
                      "inferenceBaseURL": "http://192.168.0.9:11434/v1",
                      "inferenceRemoteModel": "exaone3.5:7.8b"]) {
            #expect(InferenceSettings.baseURL == "http://192.168.0.9:11434/v1")
            #expect(InferenceSettings.remoteModel == "exaone3.5:7.8b")
        }
    }

    /// 요청을 보내고 401을 받아 보게 두는 대신, 무엇이 비었는지 이름으로 말한다.
    @Test("원격을 골랐는데 주소가 비면 그 사실을 이름으로 말한다")
    func namesTheMissingPiece() {
        withDefaults(["inferenceBackend": "remote",
                      "inferencePreset": RemoteInferencePreset.custom.id,
                      "inferenceBaseURL": "", "inferenceRemoteModel": "solar-pro2"]) {
            let problem = InferenceSettings.remoteConfigurationProblem()
            #expect(problem?.contains("API 주소") == true)
        }
    }

    @Test("실패 문구는 고른 쪽의 이름을 부른다")
    func failureNounFollowsBackend() {
        #expect(InferenceBackend.local.noun == "로컬 모델")
        #expect(InferenceBackend.remote.noun == "API 모델")
    }

    /// 401과 429는 고치는 방법이 완전히 다르다. 상태 코드만 던지면 사용자는 둘을
    /// 구별하지 못하고 키를 다시 발급하며 시간을 쓴다.
    @Test("HTTP 상태마다 고칠 수 있는 말을 준다")
    func remoteFailureIsActionable() {
        let unauthorized = StructuredInference.remoteFailure(status: 401, body: Data())
        #expect(unauthorized.contains("키"))
        let throttled = StructuredInference.remoteFailure(status: 429, body: Data())
        #expect(throttled.contains("한도"))
        let reported = StructuredInference.remoteFailure(
            status: 500, body: Data(#"{"error":{"message":"upstream timeout"}}"#.utf8)
        )
        #expect(reported.contains("upstream timeout"))
    }

    /// 밖으로 내보내는 쪽을 켜기 전에, 무엇이 나가는지 같은 화면에서 읽을 수 있어야 한다.
    @Test("원격을 고르면 무엇이 전송되는지 화면이 먼저 말한다")
    func remoteStatesWhatLeaves() {
        #expect(InferenceBackend.local.privacyNote.contains("떠나지 않습니다"))
        #expect(InferenceBackend.remote.privacyNote.contains("전송"))
        // 파일 쪽은 이 설정과 무관하다는 것도 같이 말한다 — 이 앱을 쓰는 이유가 그것이다.
        #expect(InferenceBackend.remote.privacyNote.contains("이 Mac 안에서만"))
    }
}

@Suite("국산 로컬 모델")
struct KoreanModelCatalogTests {
    /// 자동 선택은 여전히 MoE만 고른다. 조밀 모델이 섞이면 같은 메모리에서 느려진 이유를
    /// 사용자가 알 수 없다.
    @Test("EXAONE은 자동 선택 목록에 끼어들지 않는다")
    func koreanModelsAreOptIn() {
        #expect(!LocalModelCatalog.entries.contains { $0.tag.hasPrefix("exaone") })
        #expect(LocalModelCatalog.koreanEntries.allSatisfy { $0.tag.hasPrefix("exaone3.5") })
    }

    @Test("설정에 적어 둔 국산 태그도 이름으로 찾힌다")
    func lookupSeesKoreanTags() throws {
        let entry = try #require(LocalModelCatalog.entry(tagged: "exaone3.5:7.8b"))
        #expect(entry.gigabytes == 4.8)
        #expect(entry.pullCommand == "ollama pull exaone3.5:7.8b")
    }

    /// 16GB 맥은 자동 선택으로는 아무것도 못 고른다. 국산 목록의 작은 쪽은 거기서도 돈다.
    @Test("작은 맥에서도 고를 수 있는 국산 선택이 있다")
    func smallMachineHasAKoreanOption() {
        let budget = 8.0 // 16GB 맥의 절반
        #expect(LocalModelCatalog.largestFitting(gigabytes: budget) == nil)
        #expect(LocalModelCatalog.koreanEntries.contains { $0.gigabytes <= budget })
    }
}
