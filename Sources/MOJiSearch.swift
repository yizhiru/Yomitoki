import AppKit

@MainActor struct MOJiSearch {
    var clientApplication: (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    var openClient: (URL, URL) async throws -> Void = { url, application in
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: application,
                                              configuration: NSWorkspace.OpenConfiguration())
    }
    var openWebsite: (URL) -> Bool = { NSWorkspace.shared.open($0) }

    struct Destinations: Equatable {
        let client: URL
        let website: URL
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func destinations(for word: String) throws -> Destinations {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { throw Failure(message: "请先选择需要查询的单词。") }
        // Encode one complete search term for both the query and the website path segment.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = word.addingPercentEncoding(withAllowedCharacters: allowed),
              let client = URL(string: "mojisho://?search=\(encoded)"),
              let website = URL(string: "https://www.mojidict.com/searchText/\(encoded)") else {
            throw Failure(message: "无法生成 MOJi 查询地址。")
        }
        return Destinations(client: client, website: website)
    }

    func open(word: String) async throws {
        let destinations = try Self.destinations(for: word)
        if let application = clientApplication(destinations.client) {
            do {
                try await openClient(destinations.client, application)
                return
            } catch {
                // A registered client can still fail to launch or receive the URL.
            }
        }
        guard openWebsite(destinations.website) else {
            throw Failure(message: "无法打开 MOJi 或网页搜索，请检查系统的默认浏览器设置。")
        }
    }
}
