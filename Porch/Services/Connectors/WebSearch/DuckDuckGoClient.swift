import Foundation

actor DuckDuckGoClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    struct SearchResult: Encodable {
        var title: String
        var url: String
        var snippet: String
    }

    func search(query: String, maxResults: Int = 8) async throws -> [SearchResult] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            throw ConnectorError.invalidArguments("Invalid search query.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ConnectorError.apiError("DuckDuckGo returned an error.")
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw ConnectorError.apiError("Could not decode search response.")
        }

        return parseResults(from: html, maxResults: maxResults)
    }

    /// Fetches and extracts readable text content from a URL.
    func fetchPageContent(url urlString: String, maxLength: Int = 15000) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw ConnectorError.invalidArguments("Invalid URL: \(urlString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ConnectorError.apiError("Failed to fetch page (HTTP \(code)).")
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw ConnectorError.apiError("Could not decode page content.")
        }

        let text = extractReadableText(from: html)
        if text.count > maxLength {
            return String(text.prefix(maxLength)) + "\n\n[Content truncated at \(maxLength) characters]"
        }
        return text
    }

    // MARK: - HTML Parsing

    /// Parses DuckDuckGo HTML results into structured search results.
    private func parseResults(from html: String, maxResults: Int) -> [SearchResult] {
        var results: [SearchResult] = []

        // DuckDuckGo HTML results are in <div class="result"> blocks
        // Each contains <a class="result__a"> for title/URL and
        // <a class="result__snippet"> for the snippet
        let resultBlocks = html.components(separatedBy: "class=\"result__body")

        for block in resultBlocks.dropFirst() {
            guard results.count < maxResults else { break }

            let title = extractBetween(block, prefix: "class=\"result__a\"", startDelim: ">", endDelim: "</a>")
                .map(stripHTMLTags) ?? ""
            let url = extractHref(from: block, className: "result__a")
            let snippet = extractBetween(block, prefix: "class=\"result__snippet", startDelim: ">", endDelim: "</a>")
                .map(stripHTMLTags) ?? ""

            guard !title.isEmpty, let url, !url.isEmpty else { continue }

            // Resolve DuckDuckGo redirect URLs
            let resolvedURL = resolveURL(url)

            results.append(SearchResult(
                title: decodeHTMLEntities(title.trimmingCharacters(in: .whitespacesAndNewlines)),
                url: resolvedURL,
                snippet: decodeHTMLEntities(snippet.trimmingCharacters(in: .whitespacesAndNewlines))
            ))
        }

        return results
    }

    /// Extracts readable text from an HTML page by stripping tags, scripts, and styles.
    private func extractReadableText(from html: String) -> String {
        var text = html

        // Remove script and style blocks
        text = removeBlocks(from: text, openTag: "<script", closeTag: "</script>")
        text = removeBlocks(from: text, openTag: "<style", closeTag: "</style>")
        text = removeBlocks(from: text, openTag: "<nav", closeTag: "</nav>")
        text = removeBlocks(from: text, openTag: "<header", closeTag: "</header>")
        text = removeBlocks(from: text, openTag: "<footer", closeTag: "</footer>")

        // Replace common block elements with newlines
        for tag in ["</p>", "</div>", "</li>", "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>", "<br>", "<br/>", "<br />"] {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }

        // Strip remaining HTML tags
        text = stripHTMLTags(text)

        // Decode HTML entities
        text = decodeHTMLEntities(text)

        // Collapse whitespace
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return lines.joined(separator: "\n")
    }

    private func removeBlocks(from text: String, openTag: String, closeTag: String) -> String {
        var result = text
        while let startRange = result.range(of: openTag, options: .caseInsensitive) {
            guard let endRange = result.range(of: closeTag, options: .caseInsensitive, range: startRange.lowerBound..<result.endIndex) else {
                break
            }
            result.removeSubrange(startRange.lowerBound..<endRange.upperBound)
        }
        return result
    }

    private func extractBetween(_ text: String, prefix: String, startDelim: String, endDelim: String) -> String? {
        guard let prefixRange = text.range(of: prefix) else { return nil }
        let afterPrefix = text[prefixRange.upperBound...]
        guard let startRange = afterPrefix.range(of: startDelim) else { return nil }
        let afterStart = afterPrefix[startRange.upperBound...]
        guard let endRange = afterStart.range(of: endDelim) else { return nil }
        return String(afterStart[..<endRange.lowerBound])
    }

    private func extractHref(from text: String, className: String) -> String? {
        guard let classRange = text.range(of: "class=\"\(className)\"") else { return nil }
        // Look backwards for href
        let before = text[..<classRange.lowerBound]
        if let hrefRange = before.range(of: "href=\"", options: .backwards) {
            let afterHref = text[hrefRange.upperBound...]
            if let endQuote = afterHref.firstIndex(of: "\"") {
                return String(afterHref[..<endQuote])
            }
        }
        // Look forwards for href
        let after = text[classRange.upperBound...]
        if let hrefRange = after.range(of: "href=\"") {
            let afterHref = text[hrefRange.upperBound...]
            if let endQuote = afterHref.firstIndex(of: "\"") {
                return String(afterHref[..<endQuote])
            }
        }
        return nil
    }

    private func resolveURL(_ url: String) -> String {
        // DuckDuckGo wraps URLs in redirect: //duckduckgo.com/l/?uddg=<encoded_url>
        if url.contains("duckduckgo.com/l/?uddg=") {
            if let components = URLComponents(string: url),
               let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
                return uddg
            }
        }
        // Sometimes URLs start with //
        if url.hasPrefix("//") {
            return "https:" + url
        }
        return url
    }

    private func stripHTMLTags(_ text: String) -> String {
        var result = ""
        var inTag = false
        for char in text {
            if char == "<" {
                inTag = true
            } else if char == ">" {
                inTag = false
            } else if !inTag {
                result.append(char)
            }
        }
        return result
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#8230;", with: "...")
            .replacingOccurrences(of: "&#8217;", with: "'")
            .replacingOccurrences(of: "&#8220;", with: "\"")
            .replacingOccurrences(of: "&#8221;", with: "\"")
    }
}
