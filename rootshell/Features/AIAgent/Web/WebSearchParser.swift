#if !CHINA_BUILD
//
//  WebSearchParser.swift
//  rootshell
//
//  Formats web search and fetch results for LLM consumption
//

import Foundation

/// Formats web results for LLM consumption
enum WebSearchParser {

    // MARK: - Search Results Formatting

    /// Format search results for LLM output
    /// - Parameters:
    ///   - results: Search results to format
    ///   - query: The original search query
    ///   - engine: Search engine used
    ///   - maxChars: Maximum characters to return
    /// - Returns: Formatted string for LLM
    static func formatSearchResults(
        _ results: [SearchResult],
        query: String,
        engine: SearchEngine,
        maxChars: Int = 8000
    ) -> String {
        guard !results.isEmpty else {
            return "No search results found for: \"\(query)\""
        }

        var output = "Search results from \(engine.displayName) for: \"\(query)\"\n\n"

        for (index, result) in results.enumerated() {
            let resultEntry = formatSearchResult(result, index: index + 1)

            // Check if adding this result would exceed max chars
            if output.count + resultEntry.count > maxChars {
                output += "\n[Additional results truncated]"
                break
            }

            output += resultEntry
        }

        // Add result count
        output += "\n[\(results.count) result\(results.count == 1 ? "" : "s")]"

        return output
    }

    private static func formatSearchResult(_ result: SearchResult, index: Int) -> String {
        var entry = "\(index). \(result.title)\n"
        entry += "   \(result.url)\n"

        if !result.snippet.isEmpty {
            // Clean and truncate snippet
            let cleanSnippet = result.snippet
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let truncatedSnippet = String(cleanSnippet.prefix(300))
            entry += "   \(truncatedSnippet)\n"
        }

        entry += "\n"
        return entry
    }

    // MARK: - Page Content Formatting

    /// Format extracted page content for LLM output
    /// - Parameters:
    ///   - content: Extracted page content
    ///   - includeLinks: Whether to include extracted links
    ///   - maxChars: Maximum characters to return
    /// - Returns: Formatted string for LLM
    static func formatPageContent(
        _ content: ExtractedContent,
        includeLinks: Bool = true,
        maxChars: Int = 25000
    ) -> String {
        var output = ""

        // Header with title and URL
        output += "# \(content.title)\n"
        output += "URL: \(content.url)\n"

        // Add metadata if available
        if let description = content.metadata.description, !description.isEmpty {
            output += "Description: \(description)\n"
        }
        if let author = content.metadata.author, !author.isEmpty {
            output += "Author: \(author)\n"
        }
        if let siteName = content.metadata.siteName, !siteName.isEmpty {
            output += "Site: \(siteName)\n"
        }

        output += "\n---\n\n"

        // Main content
        let remainingChars = maxChars - output.count - 500 // Reserve space for links
        let mainText: String
        if content.mainText.count > remainingChars {
            mainText = truncateAtSentence(content.mainText, maxChars: remainingChars)
        } else {
            mainText = content.mainText
        }

        output += mainText

        // Add links if requested and available
        if includeLinks && !content.links.isEmpty {
            output += "\n\n---\n\n## Links found on page:\n"

            let linksToShow = min(content.links.count, 15) // Limit to 15 links in output
            for link in content.links.prefix(linksToShow) {
                if link.text.isEmpty || link.text == link.url {
                    output += "- \(link.url)\n"
                } else {
                    output += "- [\(link.text)](\(link.url))\n"
                }
            }

            if content.links.count > linksToShow {
                output += "\n[\(content.links.count - linksToShow) more links not shown]"
            }
        }

        // Final truncation check
        if output.count > maxChars {
            output = String(output.prefix(maxChars - 50))
            output += "\n\n[Content truncated due to length]"
        }

        return output
    }

    // MARK: - Error Formatting

    /// Format an error for LLM output
    static func formatError(_ error: WebBrowserError) -> String {
        switch error {
        case .timeout(let url):
            return "Error: The page at \(url.host ?? url.absoluteString) took too long to load (timeout after 15 seconds). The site may be slow or unresponsive."

        case .loadFailed(let url, let message):
            return "Error: Failed to load \(url.host ?? url.absoluteString). \(message)"

        case .noContent(let url):
            return "Error: No readable content found on \(url.host ?? url.absoluteString). The page may be empty, require JavaScript that didn't execute, or use a format that couldn't be parsed."

        case .invalidURL(let urlString):
            return "Error: Invalid URL provided: \"\(urlString)\". Please provide a complete URL including the protocol (e.g., https://example.com)."

        case .javaScriptError(let message):
            return "Error: Failed to extract content from the page. \(message)"

        case .blocked(let url):
            return "Error: Access to \(url.host ?? url.absoluteString) was blocked. The site may have detected automated access and presented a CAPTCHA or block page."

        case .cancelled:
            return "Error: The web operation was cancelled."

        case .notAvailable:
            return "Error: Web browser functionality is not available."
        }
    }

    // MARK: - Helpers

    /// Truncate text at a sentence boundary
    private static func truncateAtSentence(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }

        let truncated = String(text.prefix(maxChars))

        // Try to find a sentence boundary in the last 30% of the text
        let searchStart = truncated.index(truncated.startIndex, offsetBy: Int(Double(maxChars) * 0.7))
        let searchRange = searchStart..<truncated.endIndex

        // Look for sentence endings
        let sentenceEndings: [Character] = [".", "!", "?"]
        var lastSentenceEnd: String.Index?

        for ending in sentenceEndings {
            if let range = truncated.range(of: String(ending) + " ", range: searchRange, locale: nil) {
                if lastSentenceEnd == nil || range.upperBound > lastSentenceEnd! {
                    lastSentenceEnd = range.lowerBound
                }
            }
        }

        if let endIndex = lastSentenceEnd {
            return String(truncated[..<truncated.index(after: endIndex)]) + "\n\n[Content truncated]"
        }

        return truncated + "...\n\n[Content truncated]"
    }
}
#endif
