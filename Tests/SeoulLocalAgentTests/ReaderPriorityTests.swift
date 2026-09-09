#if canImport(Testing)
import Testing
import Foundation
@testable import SeoulLocalAgent

/// The reader's own corrections to the model's filing.
///
/// Every case here came from the reader looking at a real morning's briefing and
/// naming what was in the wrong bucket — a terms-of-service amendment sitting
/// among things to do, a scholarship they could actually apply for filed as
/// reading material. The rules move an item one step and no further, so these
/// tests care as much about what stays put as about what moves.
@Suite("Reader priority rules")
struct ReaderPriorityTests {

    private func item(
        category: BriefCategory,
        subject: String,
        body: String,
        importance: Int = 3,
        nextAction: String = "원문 확인",
        pinned: Bool? = nil
    ) -> ClassifiedItem {
        let source = SourceItem(
            id: "gmail:1", source: SourceName.gmail, account: "a@b.c", author: "발신자",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000), subject: subject, body: body,
            link: URL(string: "https://example.invalid/1")!, stableID: "gmail:1"
        )
        var value = ClassifiedItem(
            sourceItem: source, facts: "", category: category, summary: subject,
            reason: "모델 판단", importance: importance, nextAction: nextAction, deadline: ""
        )
        value.pinnedByUserRule = pinned
        value.bodyExcerpt = body
        value.contentFingerprint = "fingerprint"
        return value
    }

    private func moved(_ item: ClassifiedItem) -> ClassifiedItem {
        ReaderPriorityRules.applying(ReaderPriorityRules.adjustment(for: item), to: item)
    }

    // MARK: - 격하

    @Test("A terms-of-service amendment drops a step")
    func policyNoticeIsDemoted() {
        let result = moved(item(
            category: .reference,
            subject: "Microsoft 서비스 이용 약관 업데이트 안내",
            body: "서비스 이용 약관이 10월 1일부터 변경됩니다. 전문은 웹사이트에서 확인할 수 있습니다."
        ))
        #expect(result.category == .excluded)
        #expect(result.importance == 1)
    }

    /// The escape clause every Korean notice of this kind carries. Reading it as
    /// something the reader must do would exempt the whole class from the rule.
    @Test("The standard 해지 clause is not a duty")
    func optionalCancellationIsStillBoilerplate() {
        let result = moved(item(
            category: .reference,
            subject: "[쿠팡페이] 이용약관 개정 안내",
            body: "전자금융거래 이용약관이 9월 20일자로 개정됩니다. 개정 내용에 동의하지 않는 고객은 시행일 전까지 서비스 해지를 요청할 수 있습니다."
        ))
        #expect(result.category == .excluded)
    }

    @Test("A terms notice that demands something is left alone")
    func policyNoticeWithADutyStays() {
        let result = moved(item(
            category: .action,
            subject: "이용약관 재동의 안내",
            body: "개정 약관에 대한 재동의 절차를 9월 5일까지 완료하지 않으면 계정 이용이 제한될 수 있습니다."
        ))
        #expect(result.category == .action)
    }

    @Test("A deployment failure on the reader's own project drops a step")
    func deployFailureIsDemoted() {
        let result = moved(item(
            category: .action,
            subject: "cookierunhub 배포 실패",
            body: "main 브랜치의 배포 파이프라인이 빌드 단계에서 실패했습니다. 이전 버전이 계속 서비스되고 있습니다.",
            importance: 3
        ))
        #expect(result.category == .reference)
        #expect(result.importance == 2)
        // Nothing is being asked of the reader, so it must not keep a task's verb.
        #expect(result.nextAction.isEmpty)
    }

    /// GitHub sends these in English even when the reader's own briefing renders
    /// them in Korean, and a list of Korean phrases matched none of them.
    @Test("An English build notification is recognised too")
    func englishDeployFailureIsDemoted() {
        var source = item(
            category: .action,
            subject: "[example/webapp] Run failed: Deploy production - main (0f73d60)",
            body: "Deploy production workflow run. Jobs: frontend-check failed, backend-test succeeded, deploy skipped."
        )
        source.displayTitle = "cookierunhub 배포 파이프라인 실패"
        #expect(moved(source).category == .reference)
    }

    @Test("Somebody asking the reader to fix a build is still a request")
    func aPersonAskingIsNotABot() {
        let result = moved(item(
            category: .action,
            subject: "빌드 실패 확인 부탁",
            body: "어제 올린 커밋 이후로 빌드가 실패합니다. 오늘 중으로 확인 부탁드립니다."
        ))
        #expect(result.category == .action)
    }

    @Test("A deployment failure that took a service down stays a task")
    func outageIsNotDemoted() {
        let result = moved(item(
            category: .action,
            subject: "배포 실패로 서비스 중단",
            body: "배포가 실패해 서비스 중단이 발생했습니다. 즉시 롤백이 필요합니다."
        ))
        #expect(result.category == .action)
    }

    // MARK: - 격상

    @Test("A scholarship the reader can apply for rises a step")
    func scholarshipApplicationIsPromoted() {
        let result = moved(item(
            category: .reference,
            subject: "선한인재장학생 신청 안내",
            body: "2학기 장학생을 모집합니다. 재단 홈페이지에서 9월 12일 18시까지 신청서를 제출하면 됩니다.",
            importance: 2
        ))
        #expect(result.category == .action)
        #expect(result.importance == 3)
        // An item in 오늘 꼭 할 일 whose next action reads "원문 확인" is not a task.
        #expect(result.nextAction != "원문 확인")
        #expect(!result.nextAction.isEmpty)
    }

    /// The model's own "확인만 필요" is as empty as "원문 확인" once an item sits in
    /// 오늘 꼭 할 일, so a promotion replaces it too.
    @Test("A promotion replaces a next action that says nothing")
    func vagueActionsAreReplaced() {
        var source = item(
            category: .reference,
            subject: "피지컬 AI 포럼 2026 참가 등록 안내",
            body: "학생 참가 등록은 9월 25일까지 받습니다."
        )
        source.displayNextAction = "확인만 필요"
        let result = moved(source)
        #expect(result.category == .action)
        #expect(result.nextAction == "참가 신청 마감을 확인하고 등록 여부를 정하세요.")
    }

    @Test("An announcement of who won a scholarship is not an application")
    func scholarshipResultStays() {
        let result = moved(item(
            category: .reference,
            subject: "2026 장학생 선정 결과 발표",
            body: "장학생 선정 결과를 안내합니다. 선정자는 홈페이지에서 확인할 수 있습니다."
        ))
        #expect(result.category == .reference)
    }

    @Test("A forum in the reader's own field rises a step")
    func interestForumIsPromoted() {
        let result = moved(item(
            category: .reference,
            subject: "피지컬 AI 포럼 2026 참가 등록 안내",
            body: "10월 8일 피지컬 AI 포럼을 개최합니다. 학생 참가 등록은 9월 25일까지 받습니다."
        ))
        #expect(result.category == .action)
    }

    @Test("The same forum in another field does not move")
    func unrelatedForumStays() {
        let result = moved(item(
            category: .reference,
            subject: "산업수학 특강 사전등록 안내",
            body: "9월 12일 산업수학 특강을 개최합니다. 9월 5일까지 사전등록에서 신청할 수 있습니다."
        ))
        #expect(result.category == .reference)
    }

    @Test("Interest alone is not enough without a way in")
    func interestWithoutParticipationStays() {
        let result = moved(item(
            category: .reference,
            subject: "로보틱스 산업 동향 뉴스레터",
            body: "이번 달 로보틱스 산업의 투자 동향을 정리했습니다."
        ))
        #expect(result.category == .reference)
    }

    @Test("A field the reader removed from 관심 분야 stops being promoted")
    func interestsAreTheReadersOwn() {
        let source = item(
            category: .reference,
            subject: "피지컬 AI 포럼 2026 참가 등록 안내",
            body: "학생 참가 등록은 9월 25일까지 받습니다."
        )
        var preferences = BriefingPreferences.defaults
        preferences.interestPatterns = ["양자컴퓨팅"]
        #expect(ReaderPriorityRules.adjustment(for: source, preferences: preferences) == nil)
    }

    // MARK: - 경계

    @Test("An explicit user rule outranks every rule here")
    func pinnedItemsAreUntouched() {
        let result = moved(item(
            category: .action,
            subject: "이용약관 개정 안내",
            body: "약관이 변경됩니다.",
            pinned: true
        ))
        #expect(result.category == .action)
    }

    @Test("Nothing moves more than one step")
    func demotionStopsAtTheBottom() {
        let result = moved(item(
            category: .excluded,
            subject: "이용약관 개정 안내",
            body: "약관이 변경됩니다.",
            importance: 1
        ))
        #expect(result.category == .excluded)
        #expect(result.importance == 1)
    }

    @Test("Rebuilding an item keeps what the archive needs to show it")
    func adjustmentKeepsStoredFields() {
        let result = moved(item(
            category: .reference,
            subject: "선한인재장학생 신청 안내",
            body: "9월 12일까지 신청서를 제출하면 됩니다."
        ))
        #expect(result.bodyExcerpt?.isEmpty == false)
        #expect(result.contentFingerprint == "fingerprint")
    }

    /// The gate demotes optional opportunities; the reader's rules promote
    /// scholarship applications. Run in the wrong order they cancel out, and the
    /// item lands in 오늘 꼭 할 일 with its next action rewritten to "원문 확인".
    @Test("The quality gate does not undo a promotion")
    func gateAndRulesAgree() {
        let source = item(
            category: .action,
            subject: "선한인재장학생 신청 안내",
            body: "장학생을 모집합니다. 9월 12일 18시까지 신청서를 제출하세요.",
            importance: 4, nextAction: "장학금 신청서 제출"
        )
        let result = BriefingQualityGate.normalized([source])[0]
        #expect(result.category == .action)
        #expect(result.nextAction == "장학금 신청서 제출")
    }
}
#endif
