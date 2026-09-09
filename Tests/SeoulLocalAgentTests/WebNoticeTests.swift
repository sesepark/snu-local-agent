import Foundation
#if canImport(Testing)
import Testing
@testable import SeoulLocalAgent

@Suite("웹 공지 수집")
struct WebNoticeTests {
    private static func site(_ url: String = "https://cls.snu.ac.kr/notice/") -> WebNoticeSite {
        WebNoticeSite(name: "테스트 게시판", url: URL(string: url)!)
    }

    @Test("RSS 항목에서 제목·주소·날짜를 읽는다")
    func parsesRSS() {
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>공지</title>
        <item>
          <title><![CDATA[2026학년도 2학기 장학금 신청 안내]]></title>
          <link>https://cls.snu.ac.kr/?kboard_content_redirect=3042</link>
          <pubDate>Wed, 26 Aug 2026 13:32:20 +0000</pubDate>
          <description><![CDATA[<p>9월 9일까지 포털에서 신청하세요.&nbsp;</p>]]></description>
        </item>
        <item>
          <title>수강신청 정정 기간 안내</title>
          <link>https://cls.snu.ac.kr/?kboard_content_redirect=3043</link>
        </item>
        </channel></rss>
        """
        let entries = FeedParserProbe.parse(feed, base: "https://cls.snu.ac.kr/feed/")
        #expect(entries.count == 2)
        #expect(entries[0].title == "2026학년도 2학기 장학금 신청 안내")
        #expect(entries[0].link.absoluteString.hasSuffix("3042"))
        // Tags and entities in the description must not survive into the briefing.
        #expect(entries[0].summary.contains("9월 9일까지"))
        #expect(!entries[0].summary.contains("<p>"))
        #expect(!entries[0].summary.contains("&nbsp;"))
        #expect(entries[0].published != nil)
        // A board that omits the date is still a usable entry.
        #expect(entries[1].published == nil)
    }

    @Test("Atom 항목은 링크가 속성에 있어도 읽는다")
    func parsesAtomLinkAttribute() {
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
        <entry>
          <title>대학원 입시설명회 개최 안내</title>
          <link rel="alternate" href="https://ece.snu.ac.kr/notice?bbsidx=57920"/>
          <updated>2026-08-27T04:10:00Z</updated>
          <summary>9월 3일 개최합니다.</summary>
        </entry>
        </feed>
        """
        let entries = FeedParserProbe.parse(feed, base: "https://ece.snu.ac.kr/feed")
        #expect(entries.count == 1)
        #expect(entries[0].link.absoluteString.contains("bbsidx=57920"))
        #expect(entries[0].published != nil)
    }

    @Test("HTML 게시판에서 공지 링크만 골라낸다")
    func extractsNoticeLinksFromHTML() {
        let html = """
        <html><body>
        <nav><a href="/research-faculty/faculty/emeritus">명예교수 및 전직교수</a>
             <a href="https://ssai.snu.ac.kr/">연합전공 인공지능 반도체공학</a></nav>
        <ul class="board">
          <li><a href="?md=v&amp;bbsidx=57983">2027학년도 전기 학사&#183;대학원 연계과정 선발 모집 안내</a></li>
          <li><a href="/community/admissions?md=v&bbsidx=57920"><span>대학원</span> 입시설명회 개최 안내</a></li>
          <li><a href="?md=v&bbsidx=57983">같은 글로 이어지는 두 번째 링크</a></li>
          <li><a href="?md=v&bbsidx=57900">짧음</a></li>
        </ul>
        </body></html>
        """
        let page = URL(string: "https://ece.snu.ac.kr/community/admissions?sc=y")!
        let entries = HTMLNoticeExtractor.entries(in: html, pageURL: page)

        // Navigation carries no post id, so it never reaches the briefing.
        #expect(!entries.contains { $0.title.contains("명예교수") })
        #expect(!entries.contains { $0.link.host != "ece.snu.ac.kr" })
        // Same post linked twice stays one entry, and a too-short label is dropped.
        #expect(entries.count == 2)
        #expect(entries[0].title.contains("연계과정 선발 모집"))
        // Entities in the href must be decoded or the query breaks.
        #expect(entries[0].link.absoluteString.contains("bbsidx=57983"))
        #expect(!entries[0].link.absoluteString.contains("&amp;"))
        // Markup inside the anchor is stripped, not glued together.
        #expect(entries[1].title == "대학원 입시설명회 개최 안내")
        #expect(entries[1].link.absoluteString.hasPrefix("https://ece.snu.ac.kr/community/admissions"))
    }

    @Test("첫 수집은 기준선만 잡고 새 글을 만들지 않는다")
    func firstVisitOnlyRecordsBaseline() {
        let board = Self.site()
        var store = WebNoticeSeenStore()
        let existing = [
            WebNoticeEntry(title: "이미 올라와 있던 공지", link: URL(string: "https://cls.snu.ac.kr/a/1")!, summary: "", published: nil),
            WebNoticeEntry(title: "이미 올라와 있던 두 번째 공지", link: URL(string: "https://cls.snu.ac.kr/a/2")!, summary: "", published: nil),
        ]
        // Reporting a board's whole front page as news would bury the briefing.
        #expect(!store.hasBaseline(for: board))
        store.record(existing, for: board)
        #expect(store.hasBaseline(for: board))
        #expect(store.unseen(existing, for: board).isEmpty)

        let fresh = WebNoticeEntry(title: "새로 올라온 공지", link: URL(string: "https://cls.snu.ac.kr/a/3")!, summary: "", published: nil)
        let unseen = store.unseen([fresh] + existing, for: board)
        #expect(unseen.map(\.title) == ["새로 올라온 공지"])
    }

    @Test("기억하는 주소 수에 상한이 있다")
    func seenListIsBounded() {
        let board = Self.site()
        var store = WebNoticeSeenStore()
        let many = (0..<(WebNoticeSeenStore.perSiteLimit + 50)).map {
            WebNoticeEntry(title: "공지 \($0)", link: URL(string: "https://cls.snu.ac.kr/a/\($0)")!, summary: "", published: nil)
        }
        store.record(many, for: board)
        #expect(store.seen[board.id]?.count == WebNoticeSeenStore.perSiteLimit)
        // The newest posts are the ones worth remembering.
        #expect(store.seen[board.id]?.first?.hasSuffix("/a/0") == true)
    }

    @Test("공지 항목은 출처와 링크를 그대로 지닌 수집 항목이 된다")
    func entryBecomesSourceItem() {
        let board = WebNoticeSite(name: "자유전공학부", url: URL(string: "https://cls.snu.ac.kr/notice/")!)
        let entry = WebNoticeEntry(
            title: "장학금 신청 안내",
            link: URL(string: "https://cls.snu.ac.kr/a/1")!,
            summary: "9월 9일 18시까지 포털에서 신청서를 제출하십시오.",
            published: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let item = entry.sourceItem(site: board)
        #expect(item.source == SourceName.web)
        #expect(item.account == "자유전공학부")
        #expect(item.link == entry.link)
        #expect(item.timestamp == entry.published)
        // The body must be the richer of the two, so a summary-less board still
        // passes the evidence gate on its title alone.
        #expect(item.body.contains("9월 9일"))
        #expect(InboxEvidenceGate.isUsable(item.body))
        #expect(item.stableID == "web:https://cls.snu.ac.kr/a/1")
    }

    @Test("타 단과대 게시판은 지원 가능한 기회만 통과시킨다")
    func otherCollegeGateKeepsOpportunities() {
        // 본인 대상이 아닌 내부 행정은 마감이 있어도 걸러진다.
        #expect(!OtherCollegeNoticeGate.allows("2026학년도 후기 학위수여식 및 졸업 사정 안내"))
        #expect(!OtherCollegeNoticeGate.allows("2학기 학위논문 심사 일정 안내"))
        #expect(!OtherCollegeNoticeGate.allows("302동 강의실 변경 안내"))
        #expect(!OtherCollegeNoticeGate.allows("2026학년도 교과목 수요조사"))
        // 지원할 수 있는 것은 남는다.
        #expect(OtherCollegeNoticeGate.allows("제12회 창업 아이디어 경진대회 참가팀 모집"))
        #expect(OtherCollegeNoticeGate.allows("2027학년도 1학기 교환학생 파견 1차 모집"))
        #expect(OtherCollegeNoticeGate.allows("성적우수 장학금 신청 안내"))
        // 내부 낱말이 들어 있어도 지원할 기회면 통과한다. 이 게이트는 관련성 판단이
        // 아니라 명백한 서류 공지만 덜어내는 좁은 문이다.
        #expect(OtherCollegeNoticeGate.allows("졸업예정자 대상 취업 멘토링 프로그램 참가자 모집"))
        // 판단이 서지 않는 제목은 모델로 넘긴다.
        #expect(OtherCollegeNoticeGate.allows("2026 SNU-UPenn 국제심포지엄 개최"))
    }

    @Test("타 단과대 항목만 audience를 달고 나간다")
    func audienceMarksOtherCollegeBoards() {
        let entry = WebNoticeEntry(title: "창업 경진대회 참가팀 모집",
                                   link: URL(string: "https://cba.snu.ac.kr/a/1")!, summary: "", published: nil)
        let other = WebNoticeSite(name: "경영대학", url: URL(string: "https://cba.snu.ac.kr/notice")!, interest: .programsOnly)
        let mine = WebNoticeSite(name: "자유전공학부", url: URL(string: "https://cls.snu.ac.kr/notice/")!)
        #expect(entry.sourceItem(site: other).audience?.contains("경영대학") == true)
        // 본인 소속 게시판에는 붙지 않는다. 모든 메시지에 빈 필드를 보내지 않기 위해서다.
        #expect(entry.sourceItem(site: mine).audience == nil)
    }

    @Test("관심 수준이 없는 예전 설정 파일도 읽힌다")
    func legacyConfigurationDecodes() throws {
        let json = """
        {"sites":[{"name":"자유전공학부","url":"https://cls.snu.ac.kr/notice/"}]}
        """
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "web-notices.json")
        try Data(json.utf8).write(to: url)

        let sites = WebNoticeConfiguration.load(url: url)
        // The stored entry keeps its place; the fields it predates take their
        // defaults rather than dropping the board.
        #expect(sites[0].name == "자유전공학부")
        #expect(sites[0].enabled)
        #expect(sites[0].interest == .direct)
    }

    /// A shadow run promises to change nothing, but the seen-set was written
    /// anyway. Because the baseline is a one-off, a dry run spent it: the next
    /// real run believed it had already seen every post on every board and
    /// reported nothing at all.
    @Test("모의 실행은 기준선을 쓰지 않는다")
    func shadowRunLeavesTheSeenSetAlone() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "web-notice-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = directory.appending(path: "feed.xml")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
        <item><title>공지 하나</title><link>https://cls.snu.ac.kr/a/1</link></item>
        <item><title>공지 둘</title><link>https://cls.snu.ac.kr/a/2</link></item>
        <item><title>공지 셋</title><link>https://cls.snu.ac.kr/a/3</link></item>
        </channel></rss>
        """.write(to: feedURL, atomically: true, encoding: .utf8)

        var board = Self.site()
        board.feed = feedURL
        let storeURL = directory.appending(path: "seen.json")
        var source = WebNoticeSource()
        source.sites = [board]
        source.storeURL = storeURL

        _ = await source.collect(persists: false)
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))

        _ = await source.collect(persists: true)
        #expect(FileManager.default.fileExists(atPath: storeURL.path))
        #expect(WebNoticeSeenStore.load(url: storeURL).hasBaseline(for: board))
    }

    @Test("기본 게시판 목록은 중복 없이 열린다")
    func catalogueIsWellFormed() {
        let sites = WebNoticeCatalog.defaults
        #expect(sites.count >= 15)
        #expect(Set(sites.map(\.id)).count == sites.count)
        #expect(sites.contains { $0.name.contains("OGA") && $0.enabled })
        #expect(sites.contains { $0.name.contains("자유전공학부") && $0.enabled })
        #expect(sites.contains { $0.name.contains("비교과") && $0.enabled })
        // A board that cannot be read is kept but switched off, never silently
        // dropped, so the check tool can tell when the site is fixed.
        #expect(sites.contains { !$0.enabled })
        // The user's own department and the university-wide offices stay direct;
        // the other colleges only contribute what he could apply to.
        #expect(sites.first { $0.name.contains("자유전공학부") }?.interest == .direct)
        #expect(sites.first { $0.name.contains("OGA") }?.interest == .direct)
        #expect(sites.first { $0.name.contains("전기") }?.interest == .direct)
        #expect(sites.first { $0.name.contains("인문대학") }?.interest == .programsOnly)
        #expect(sites.filter { $0.interest == .programsOnly }.count == 9)
        for site in sites {
            #expect(site.url.host?.hasSuffix("snu.ac.kr") == true)
        }
    }

    /// SNU 비교과 links every programme through `global.write`, the same shape the
    /// eGov boards use: without this the board reads as empty and the briefing
    /// reports it as broken every night.
    @Test("스크립트로 여는 목록도 주소를 만들어 읽는다")
    func extractsScriptLinkedRows() {
        let html = """
        <html><body>
        <li class="wait"><div class="img_wrap">
          <a href="#" onclick="global.write('PGM012002141', '/ptfol/pgm/view.do');"><img src="/comm/cmfile/openCrop.do?width=700" alt=".." /></a>
        </div>
        <div class="label_box"><a href="#" class="btn01" onclick="global.write('PGM012002141', '/ptfol/pgm/view.do');"><span>모집대기</span></a></div>
        <a href="#;" class="tit ellipsis" onclick="global.write('PGM012002141', '/ptfol/pgm/view.do');">(대학원생) 26-2학기 대인관계 향상 집단상담 프로그램</a>
        <a href="#;" class="apply_btn" onclick="global.write('PGM012002141', '/ptfol/pgm/view.do');"><span>신청하기</span></a>
        </li>
        <li><a href="#;" class="tit ellipsis" onclick="global.write('PGM012002182', '/ptfol/pgm/view.do');">제1회 TI:um Sprout 참가자 모집</a></li>
        <nav><a href="/menu/redirect.do?url=/ptfol/pgm/PBC0001/index.do">교육 (특강/세미나)</a></nav>
        </body></html>
        """
        let page = URL(string: "https://extra.snu.ac.kr/ptfol/pgm/index.do")!
        let entries = HTMLNoticeExtractor.entries(in: html, pageURL: page)

        #expect(entries.count == 2)
        // Three anchors carry the same programme; only the titled one survives, and
        // the thumbnail and the 신청하기 button are too short to be titles.
        #expect(entries[0].title == "(대학원생) 26-2학기 대인관계 향상 집단상담 프로그램")
        #expect(entries[0].link.absoluteString
            == "https://extra.snu.ac.kr/ptfol/pgm/view.do?currentPageNo=1&dataSeq=PGM012002141&parentSeq=PGM012002141")
        #expect(entries[1].link.absoluteString.contains("dataSeq=PGM012002182"))
        // The menu is a real address with no programme id behind it.
        #expect(!entries.contains { $0.title.contains("특강") })
    }

    /// The file on disk wins, which is how a board is disabled — but a Mac that
    /// already had the file would otherwise never see a board added later.
    @Test("설정 파일에 없던 새 게시판은 합쳐져 저장된다")
    func newCatalogueEntriesReachAnExistingFile() throws {
        let json = """
        {"sites":[{"name":"자유전공학부","url":"https://cls.snu.ac.kr/notice/","enabled":true,"interest":"direct"}]}
        """
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "web-notices.json")
        try Data(json.utf8).write(to: url)

        let sites = WebNoticeConfiguration.load(url: url)
        #expect(sites.count == WebNoticeCatalog.defaults.count)
        #expect(sites.first?.name == "자유전공학부")
        #expect(sites.contains { $0.url.host == "extra.snu.ac.kr" })
        // The merge is written back, so the list stays editable by hand.
        let reloaded = WebNoticeConfiguration.load(url: url)
        #expect(reloaded.count == sites.count)
    }
}

/// `FeedParser` is private to the source file; the suite exercises it through the
/// same entry point the collector uses.
private enum FeedParserProbe {
    static func parse(_ xml: String, base: String) -> [WebNoticeEntry] {
        WebNoticeSource.parseFeedForTesting(Data(xml.utf8), baseURL: URL(string: base)!)
    }
}
#endif
