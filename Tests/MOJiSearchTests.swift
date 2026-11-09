import Foundation

private struct TestFailure: Error {
    let message: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(message: message) }
}

@main struct MOJiSearchTests {
    @MainActor static func main() async throws {
        let cases = ["喫茶店", "アルバイト", "pão", "C++ & C# / A?x=1%2F", "英語／日本語", " 雨 \n"]
        for word in cases {
            let links = try MOJiSearch.destinations(for: word)
            let client = URLComponents(url: links.client, resolvingAgainstBaseURL: false)!
            let website = URLComponents(url: links.website, resolvingAgainstBaseURL: false)!
            let expected = word.trimmingCharacters(in: .whitespacesAndNewlines)
            try require(client.scheme == "mojisho" && client.queryItems?.count == 1, "Client URL has one search parameter")
            try require(client.queryItems?.first == URLQueryItem(name: "search", value: expected), "Client query preserves the word")
            try require(website.scheme == "https" && website.host == "www.mojidict.com", "Website remains on the MOJi host")
            try require(website.query == nil && website.fragment == nil, "Search text cannot add query or fragment parameters")
            let segment = String(website.percentEncodedPath.dropFirst("/searchText/".count))
            try require(website.percentEncodedPath.hasPrefix("/searchText/") && !segment.contains("/"), "Search word occupies one path segment")
            try require(segment.removingPercentEncoding == expected, "Website path preserves Unicode and reserved characters")
        }

        var attempts: [URL] = []
        let links = try MOJiSearch.destinations(for: "喫茶店")
        let application = URL(fileURLWithPath: "/Applications/MOJi.app")
        var receivedApplication: URL?
        let successfulClient = MOJiSearch(
            clientApplication: { url in
                attempts.append(url)
                return application
            },
            openClient: { url, app in
                attempts.append(url)
                receivedApplication = app
            },
            openWebsite: { url in attempts.append(url); return true }
        )
        try await successfulClient.open(word: "喫茶店")
        try require(attempts == [links.client, links.client] && receivedApplication == application,
                    "Registered client opens first and successful launch skips the browser")

        attempts = []
        let missingClient = MOJiSearch(
            clientApplication: { url in attempts.append(url); return nil },
            openClient: { url, _ in attempts.append(url) },
            openWebsite: { url in attempts.append(url); return true }
        )
        try await missingClient.open(word: "喫茶店")
        try require(attempts == [links.client, links.website], "Missing client falls back directly to website search")

        attempts = []
        let failedClient = MOJiSearch(
            clientApplication: { _ in application },
            openClient: { url, _ in
                attempts.append(url)
                throw CocoaError(.fileReadNoSuchFile)
            },
            openWebsite: { url in attempts.append(url); return true }
        )
        try await failedClient.open(word: "喫茶店")
        try require(attempts == [links.client, links.website], "Client launch failure falls back to the browser")

        var browserAttempts = 0
        let failedBrowser = MOJiSearch(
            clientApplication: { _ in nil },
            openClient: { _, _ in throw TestFailure(message: "Missing client must not be launched") },
            openWebsite: { _ in browserAttempts += 1; return false }
        )
        do {
            try await failedBrowser.open(word: "喫茶店")
            throw TestFailure(message: "Browser failure should be reported")
        } catch let error as MOJiSearch.Failure {
            try require(error.message.contains("默认浏览器"), "Browser failure gives an actionable message")
        }
        try require(browserAttempts == 1, "Browser is attempted once")

        for word in ["", " \n\t "] {
            do {
                try await failedBrowser.open(word: word)
                throw TestFailure(message: "Empty query should be rejected")
            } catch let error as MOJiSearch.Failure {
                try require(error.message.contains("选择"), "Empty query gives a useful message")
            }
        }
        try require(browserAttempts == 1, "Empty words never launch applications")
        print("Passed MOJi URL encoding, client-first launch, missing-client fallback, failed-client fallback, and error checks.")
    }
}
