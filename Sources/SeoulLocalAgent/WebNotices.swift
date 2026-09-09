import Foundation

/// A public notice board this Mac polls for new posts.
///
/// `feed` is filled in when the site publishes RSS or Atom, which is both cheaper
/// and far more stable than reading its HTML. Sites without one are scraped from
/// the list page instead.
enum WebNoticeInterest: String, Codable {
    /// The user's own department and the university-wide offices: everything on the
    /// board is potentially theirs to act on.
    case direct
    /// Another college's board. Almost all of it is that college's internal
    /// business; what matters is the occasional programme this user could apply to.
    case programsOnly
}

struct WebNoticeSite: Codable, Hashable, Identifiable {
    var name: String
    var url: URL
    var feed: URL?
    var enabled: Bool
    var interest: WebNoticeInterest

    var id: String { url.absoluteString }

    init(name: String, url: URL, feed: URL? = nil, enabled: Bool = true, interest: WebNoticeInterest = .direct) {
        self.name = name
        self.url = url
        self.feed = feed
        self.enabled = enabled
        self.interest = interest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(URL.self, forKey: .url)
        feed = try container.decodeIfPresent(URL.self, forKey: .feed)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        // Absent in files written before this field existed.
        interest = try container.decodeIfPresent(WebNoticeInterest.self, forKey: .interest) ?? .direct
    }
}

/// The boards the app starts with. These are public university pages, so unlike the
/// Gmail addresses they are not personal data and can live in source. The file on
/// disk wins once it exists, which is how a site is added, disabled, or corrected.
enum WebNoticeCatalog {
    static let kboardFeed = "/wp-content/plugins/kboard/rss.php"

    static let defaults: [WebNoticeSite] = [
        site("서울대 국제협력본부(OGA)", "https://oga.snu.ac.kr/notice-all", feed: "https://oga.snu.ac.kr\(kboardFeed)"),
        site("자유전공학부", "https://cls.snu.ac.kr/notice/", feed: "https://cls.snu.ac.kr\(kboardFeed)"),
        programs("사회과학대학", "https://social.snu.ac.kr/공지사항/", feed: "https://social.snu.ac.kr\(kboardFeed)"),
        // Its KBoard feed is empty and the category page renders no post links at
        // all, so there is nothing to read from either path. Left here, disabled,
        // so `--web-notices-check` can confirm if the site is ever fixed.
        site("사범대학", "https://edu.snu.ac.kr/category/board_17_gn_ldca7if5_20201130072915/", feed: "https://edu.snu.ac.kr\(kboardFeed)", enabled: false),
        programs("수의과대학", "https://vet.snu.ac.kr/category/board-3-BL-8Piv9u51-20211029154329/", feed: "https://vet.snu.ac.kr\(kboardFeed)"),
        site("생활과학대학", "https://che.snu.ac.kr/category/board-35-GN-EKIrl47t-20210226142951/", feed: "https://che.snu.ac.kr\(kboardFeed)", enabled: false),
        programs("약학대학", "https://snupharm.snu.ac.kr/공지사항/", feed: "https://snupharm.snu.ac.kr\(kboardFeed)"),
        site("학부대학", "https://snuc.snu.ac.kr/공지사항/", feed: "https://snuc.snu.ac.kr\(kboardFeed)"),
        site("전기·정보공학부", "https://ece.snu.ac.kr/community/admissions?sc=y"),
        site("서울대 SR", "https://snusr.snu.ac.kr/community/notice"),
        // Not a notice board: every row is a programme open for application,
        // university-wide, with its own 신청기간. The default filter on this page
        // is 모집중·마감임박·모집대기, so what is read is what can still be applied to.
        site("SNU 비교과", "https://extra.snu.ac.kr/ptfol/pgm/index.do"),
        programs("인문대학", "https://humanities.snu.ac.kr/community/notice"),
        programs("경영대학", "https://cba.snu.ac.kr/newsroom/notice?sc=y"),
        programs("농업생명과학대학", "https://cals.snu.ac.kr/board/notice"),
        programs("음악대학", "https://music.snu.ac.kr/notice"),
        programs("간호대학", "https://nursing.snu.ac.kr/board/notice"),
        site("공과대학", "https://eng.snu.ac.kr/communication/notice/notice"),
        programs("자연과학대학", "https://science.snu.ac.kr/news/announcement"),
        // These two link each post through a `javascript:` call rather than a URL,
        // so a scraped entry would carry no address to open. Disabled until the
        // eGov detail URL can be built reliably.
        site("치의학대학원", "https://dentistry.snu.ac.kr/fnt/nac/selectNoticeList.do?bbsId=BBS_0000000000001", enabled: false),
        site("의과대학", "https://medicine.snu.ac.kr/fnt/nac/selectNoticeList.do?bbsId=BBSMSTR_000000000001", enabled: false),
    ]

    /// A board of a college the user does not belong to. Only what they could
    /// personally apply to is worth a line in the briefing.
    private static func programs(_ name: String, _ url: String, feed: String? = nil, enabled: Bool = true) -> WebNoticeSite {
        var value = site(name, url, feed: feed, enabled: enabled)
        value.interest = .programsOnly
        return value
    }

    private static func site(_ name: String, _ url: String, feed: String? = nil, enabled: Bool = true) -> WebNoticeSite {
        // Korean paths have to be percent-encoded before `URL` will accept them.
        let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? url
        return WebNoticeSite(name: name, url: URL(string: encoded)!, feed: feed.flatMap(URL.init(string:)), enabled: enabled)
    }
}

struct WebNoticeConfiguration: Codable {
    var sites: [WebNoticeSite]

    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "SeoulLocalAgent/web-notices.json")

    /// Writes the catalogue out on first use so the list is discoverable and
    /// editable without touching the app.
    ///
    /// The file wins for every board it already names — that is how a site is
    /// disabled or corrected — but a board added to the catalogue afterwards
    /// would otherwise never reach a Mac that already has the file, so new
    /// entries are appended and the file is rewritten.
    static func load(url: URL = Self.url) -> [WebNoticeSite] {
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(Self.self, from: data), !stored.sites.isEmpty {
            let known = Set(stored.sites.map(\.id))
            let added = WebNoticeCatalog.defaults.filter { !known.contains($0.id) }
            guard !added.isEmpty else { return stored.sites }
            let merged = stored.sites + added
            try? LocalFileStorage.write(try JSONEncoder().encode(Self(sites: merged)), to: url)
            return merged
        }
        let configuration = Self(sites: WebNoticeCatalog.defaults)
        try? LocalFileStorage.write(try JSONEncoder().encode(configuration), to: url)
        return configuration.sites
    }
}

/// Which posts have already been reported, per site.
///
/// Notice boards disagree about date formats, time zones, and whether they publish
/// a date at all, so "new" is decided by the post's own URL rather than by parsing
/// a timestamp that half of these sites render differently. The first visit to a
/// board only records what is on it; reporting a board's entire front page as news
/// would bury a day's briefing.
struct WebNoticeSeenStore: Codable {
    var seen: [String: [String]] = [:]

    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "SeoulLocalAgent/web-notices-seen.json")
    static let perSiteLimit = 400

    static func load(url: URL = Self.url) -> Self {
        guard let data = try? Data(contentsOf: url), let store = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return store
    }

    func save(url: URL = Self.url) {
        try? LocalFileStorage.write(try JSONEncoder().encode(self), to: url)
    }

    func hasBaseline(for site: WebNoticeSite) -> Bool { seen[site.id] != nil }

    func unseen(_ entries: [WebNoticeEntry], for site: WebNoticeSite) -> [WebNoticeEntry] {
        let known = Set(seen[site.id] ?? [])
        return entries.filter { !known.contains($0.link.absoluteString) }
    }

    mutating func record(_ entries: [WebNoticeEntry], for site: WebNoticeSite) {
        let fresh = entries.map(\.link.absoluteString)
        let combined = fresh + (seen[site.id] ?? []).filter { !fresh.contains($0) }
        seen[site.id] = Array(combined.prefix(Self.perSiteLimit))
    }
}

struct WebNoticeEntry: Hashable {
    var title: String
    var link: URL
    var summary: String
    var published: Date?
}

struct WebNoticeSource {
    /// Notice boards are slow and occasionally wedge; a stuck one must not hold the
    /// whole briefing, and four at a time is enough to keep the pass short without
    /// hammering nineteen university servers at once.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh) SeoulLocalAgent/1.0"]
        return URLSession(configuration: configuration)
    }()
    private static let concurrency = 4

    var sites: [WebNoticeSite] = WebNoticeConfiguration.load()
    var storeURL: URL = WebNoticeSeenStore.url

    /// Reads every enabled board without touching the seen-set, so a structure
    /// change can be checked without spending a briefing to find out.
    func inspect() async -> [(WebNoticeSite, Result<[WebNoticeEntry], Error>)] {
        var results: [(WebNoticeSite, Result<[WebNoticeEntry], Error>)] = []
        let enabled = sites.filter(\.enabled)
        for group in stride(from: 0, to: enabled.count, by: Self.concurrency).map({
            Array(enabled[$0..<min($0 + Self.concurrency, enabled.count)])
        }) {
            results += await withTaskGroup(of: (WebNoticeSite, Result<[WebNoticeEntry], Error>).self) { tasks in
                for site in group {
                    tasks.addTask {
                        do { return (site, .success(try await Self.entries(for: site))) }
                        catch { return (site, .failure(error)) }
                }
                }
                var collected: [(WebNoticeSite, Result<[WebNoticeEntry], Error>)] = []
                for await outcome in tasks { collected.append(outcome) }
                return collected
            }
        }
        return results
    }

    /// `persists` is false for a shadow run. Without it a dry run spent the
    /// one-time baseline: the store was written anyway, so the next real run
    /// believed it had already seen every post on every board and reported
    /// nothing. A run that promises to change nothing has to include this file.
    func collect(persists: Bool = true) async -> SourceHarvest {
        let enabled = sites.filter(\.enabled)
        guard !enabled.isEmpty else { return SourceHarvest(items: []) }
        var store = WebNoticeSeenStore.load(url: storeURL)
        var items: [SourceItem] = []
        var failures: [String] = []
        var baselined: [String] = []

        for (site, result) in await inspect() {
            switch result {
            case .failure(let error):
                failures.append("\(site.name): \(error.localizedDescription)")
            case .success(let entries) where entries.isEmpty:
                failures.append("\(site.name): 목록에서 글을 찾지 못했습니다. 사이트 구조가 바뀌었을 수 있습니다.")
            case .success(let entries):
                if store.hasBaseline(for: site) {
                    items += store.unseen(entries, for: site)
                        .filter { site.interest == .direct || OtherCollegeNoticeGate.allows($0.title) }
                        .map { $0.sourceItem(site: site) }
                } else {
                    baselined.append(site.name)
                    }
                store.record(entries, for: site)
            }
        }
        if persists { store.save(url: storeURL) }

        var warnings: [String] = []
        if !baselined.isEmpty {
            warnings.append("웹 공지: \(baselined.count)곳의 현재 목록을 기준선으로 저장했습니다(첫 수집). 다음 실행부터 새 글만 보고합니다.")
        }
        if !failures.isEmpty {
            warnings.append("웹 공지: \(failures.count)곳을 읽지 못했습니다 (\(failures.prefix(3).joined(separator: " / "))).")
        }
        return SourceHarvest(items: items, warnings: warnings)
    }

    /// A feed is preferred, but an auto-discovered one is not always a real feed:
    /// one of these boards publishes an `rss.xml` holding a single link back to the
    /// board itself. Too few entries means fall back to the list page.
    private static func entries(for site: WebNoticeSite) async throws -> [WebNoticeEntry] {
        if let feed = site.feed {
            let parsed = try? await parseFeed(at: feed)
            if let parsed, parsed.count >= 3 { return parsed }
        }
        let (data, response) = try await session.data(from: site.url)
        try validate(response, site: site)
        return HTMLNoticeExtractor.entries(in: String(decoding: data, as: UTF8.self), pageURL: site.url)
    }

    /// The feed parser is private to this file; the tests reach it here rather than
    /// reaching over the network for a fixture.
    static func parseFeedForTesting(_ data: Data, baseURL: URL) -> [WebNoticeEntry] {
        FeedParser(data: data, baseURL: baseURL).parse()
    }

    private static func parseFeed(at url: URL) async throws -> [WebNoticeEntry] {
        let (data, response) = try await session.data(from: url)
        try validate(response, site: nil)
        return FeedParser(data: data, baseURL: url).parse()
    }

    private static func validate(_ response: URLResponse, site: WebNoticeSite?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard 200..<300 ~= http.statusCode else {
            throw AgentError.processFailed("HTTP \(http.statusCode)")
        }
    }
}

/// Keeps another college's routine paperwork out of the model's budget.
///
/// This is deliberately a narrow gate, not a relevance judgement: it drops a title
/// only when it is clearly that college's internal business *and* carries no sign
/// of something to apply for. Everything else still goes to the classifier, which
/// is the part that can read "지원 자격: 전교생" and decide properly.
enum OtherCollegeNoticeGate {
    private static let internalBusiness = ["졸업", "학위논문", "논문제출자격", "수요조사", "강의실",
                                           "휴강", "보강", "교원 초빙", "교수 초빙", "인사발령",
                                           "학칙", "교과과정 개편", "시간표"]
    private static let opportunity = ["모집", "선발", "신청", "공모", "장학", "지원", "참가", "인턴",
                                      "교환", "프로그램", "설명회", "특강", "세미나", "캠프", "대회",
                                      "공고", "접수", "펠로우", "수기", "공모전"]

    static func allows(_ title: String) -> Bool {
        guard internalBusiness.contains(where: title.contains) else { return true }
        return opportunity.contains(where: title.contains)
    }
}

extension WebNoticeEntry {
    func sourceItem(site: WebNoticeSite) -> SourceItem {
        let cleanTitle = InboxTextSanitizer.clean(title)
        let cleanSummary = InboxTextSanitizer.clean(summary)
        return SourceItem(
            id: "web:\(link.absoluteString)",
            source: SourceName.web,
            account: site.name,
            author: site.name,
            // A board without dates still needs an ordering, and "found just now"
            // is honest: the post is new to this Mac either way.
            timestamp: published ?? Date(),
            subject: cleanTitle,
            body: cleanSummary.count >= cleanTitle.count ? cleanSummary : cleanTitle,
            link: link,
            stableID: "web:\(link.absoluteString)",
            audience: site.interest == .programsOnly
                ? "본인 소속이 아닌 \(site.name) 게시판의 전체 공지"
                : nil
        )
    }
}

/// RSS 2.0 and Atom, which is all these boards publish.
private final class FeedParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private let baseURL: URL
    private var entries: [WebNoticeEntry] = []
    private var path: [String] = []
    private var text = ""
    private var title = ""
    private var link = ""
    private var summary = ""
    private var date: Date?
    private var inEntry = false

    init(data: Data, baseURL: URL) {
        parser = XMLParser(data: data)
        self.baseURL = baseURL
        super.init()
        parser.delegate = self
    }

    func parse() -> [WebNoticeEntry] {
        parser.parse()
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        path.append(element.lowercased())
        text = ""
        switch element.lowercased() {
        case "item", "entry":
            (inEntry, title, link, summary, date) = (true, "", "", "", nil)
        case "link" where inEntry:
            // Atom puts the target in an attribute; RSS puts it in the element text.
            if let href = attributes["href"], !href.isEmpty { link = href }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        defer { if !path.isEmpty { path.removeLast() } }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard inEntry else { return }
        switch element.lowercased() {
        case "title": title = value
        case "link" where link.isEmpty: link = value
        case "description", "summary", "content": if summary.isEmpty { summary = value.strippingTags() }
        case "pubdate", "published", "updated", "date": date = date ?? Self.date(from: value)
        case "item", "entry":
            inEntry = false
            guard !title.isEmpty, let url = URL(string: link, relativeTo: baseURL)?.absoluteURL else { return }
            entries.append(WebNoticeEntry(title: title.decodingHTMLEntities(), link: url,
                                          summary: summary.decodingHTMLEntities(), published: date))
        default:
            break
        }
    }

    private static let formatters: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"].map {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = $0
        return formatter
    }

    static func date(from value: String) -> Date? {
        if let iso = ISO8601DateFormatter().date(from: value) { return iso }
        for formatter in formatters {
            if let parsed = formatter.date(from: value) { return parsed }
        }
        return nil
    }
}

/// Pulls notice rows out of a board that publishes no feed.
///
/// Every one of these Korean board systems links a post through a numeric id — as
/// `?bbsidx=57983`, `?md=v&bbsidx=3976`, or a path ending in digits — while the
/// navigation around it does not. That one rule is what separates the notices from
/// the menus without a per-site selector to maintain.
///
/// A second family links through a script call instead of an address:
/// `onclick="global.write('PGM012002141', '/ptfol/pgm/view.do')"` drops the id into
/// the page's search form and submits it. That form is a GET, so the same target is
/// reachable as a plain URL — which is what a briefing line needs, something the
/// reader can click — and the id is rebuilt into one here.
enum HTMLNoticeExtractor {
    private static let anchor = try! NSRegularExpression(pattern: "<a\\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>", options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let identifier = try! NSRegularExpression(pattern: "(?:^|[?&])[a-z_]*(?:idx|no|seq|id|uid|nttid|articleno)=\\d{2,}|/\\d{3,}(?:$|[/?#])", options: [.caseInsensitive])
    private static let scriptCall = try! NSRegularExpression(
        pattern: "<a\\b[^>]*onclick=[\"'][^\"']*global\\.write\\(\\s*'([A-Za-z0-9_-]{4,})'\\s*,\\s*'([^']+)'[^\"']*[\"'][^>]*>(.*?)</a>",
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    static let maximumEntries = 40

    static func entries(in html: String, pageURL: URL) -> [WebNoticeEntry] {
        var results: [WebNoticeEntry] = []
        var seen = Set<String>()
        let range = NSRange(html.startIndex..., in: html)

        /// Both families end here: a post is only an entry if its address is on
        /// this board's own host, has not been linked already on the page, and
        /// carries a label long enough to be a title rather than a button.
        func append(href: String, label: String) {
            let title = label.strippingTags().decodingHTMLEntities()
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count >= 8, title.count <= 150 else { return }
            guard let url = URL(string: href, relativeTo: pageURL)?.absoluteURL,
                  url.host == pageURL.host, seen.insert(url.absoluteString).inserted else { return }
            results.append(WebNoticeEntry(title: title, link: url, summary: "", published: nil))
        }

        for match in anchor.matches(in: html, range: range) {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html) else { continue }
            let href = String(html[hrefRange]).decodingHTMLEntities()
            let identifierRange = NSRange(href.startIndex..., in: href)
            guard identifier.firstMatch(in: href, range: identifierRange) != nil else { continue }
            append(href: href, label: String(html[textRange]))
            if results.count >= maximumEntries { break }
        }
        guard results.count < maximumEntries else { return results }

        for match in scriptCall.matches(in: html, range: range) {
            guard let idRange = Range(match.range(at: 1), in: html),
                  let pathRange = Range(match.range(at: 2), in: html),
                  let textRange = Range(match.range(at: 3), in: html) else { continue }
            let id = String(html[idRange])
            let path = String(html[pathRange]).decodingHTMLEntities()
            // `currentPageNo` is the field the form always carries; the detail page
            // answers with it and the id alone, and refuses without it.
            append(href: "\(path)?currentPageNo=1&dataSeq=\(id)&parentSeq=\(id)", label: String(html[textRange]))
            if results.count >= maximumEntries { break }
        }
        return results
    }
}

extension String {
    func strippingTags() -> String {
        replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    /// Only the entities these boards actually emit. A full decoder would mean
    /// `NSAttributedString`, which parses HTML on the main thread and is far too
    /// heavy to run over every anchor of nineteen pages.
    func decodingHTMLEntities() -> String {
        var value = self
        for (entity, replacement) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                                      ("&apos;", "'"), ("&#39;", "'"), ("&nbsp;", " "), ("&middot;", "·"),
                                      ("&hellip;", "…"), ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}")] {
            value = value.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        // Numeric references such as &#8226; still appear in a few board titles.
        return value.replacingOccurrences(of: "&#(\\d+);", with: "", options: .regularExpression)
    }
}
