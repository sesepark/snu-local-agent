import Foundation

/// The Gmail accounts the inbox digest reads.
///
/// Addresses are personal data, so they are configured on the machine rather
/// than committed. The file holds one entry per account:
///
///     [{"address": "you@example.com", "mailboxIndex": 0}]
///
/// `mailboxIndex` is the position Gmail assigns the account in the browser
/// (`/mail/u/<n>/`); thread links are built from it, so it must match what the
/// signed-in browser uses or the links will open the wrong mailbox.
///
/// With no file present the digest reports no Gmail sources and every other
/// source keeps working. Access stays read-only either way — this type only
/// decides *which* mailboxes `gog --readonly` is asked about.
struct GmailAccount: Codable, Equatable, Sendable {
    var address: String
    var mailboxIndex: Int
}

struct GmailAccountStore: Sendable {
    private let url: URL

    init(directory: URL? = nil) {
        let root = directory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Application Support/SeoulLocalAgent", directoryHint: .isDirectory)
        url = root.appending(path: "gmail-accounts.json")
    }

    /// Where the file lives, so 연결 상태 can offer to reveal it when it is
    /// missing rather than only naming it in prose.
    var debugURL: URL { url }

    func load() -> [GmailAccount] {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode([GmailAccount].self, from: data) else { return [] }
        return value.filter { !$0.address.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func save(_ accounts: [GmailAccount]) throws {
        try LocalFileStorage.write(try JSONEncoder().encode(accounts), to: url)
    }
}
