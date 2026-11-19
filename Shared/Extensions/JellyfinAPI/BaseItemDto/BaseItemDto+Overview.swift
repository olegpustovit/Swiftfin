//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

extension BaseItemDto {

    /// The overview with any HTML parsed, keeping only bold and italic emphasis.
    ///
    /// Parsing is lightweight (no WebKit) and cached, so it is safe to call from view bodies.
    var attributedOverview: AttributedString? {
        overview.map(OverviewParser.parse)
    }

    /// The overview as plain text, with any HTML tags removed and entities decoded.
    var cleanedOverview: String? {
        attributedOverview.map { String($0.characters) }
    }

    /// A fast plain text overview suitable for scrolling lists and system metadata.
    var plainOverview: String? {
        overview.map(OverviewParser.strip)
    }
}

extension String {

    /// Removes HTML tags and decodes common entities.
    var strippingHTML: String {
        OverviewParser.strip(self)
    }
}

enum OverviewParser {

    private static let entities: [(String, String)] = [
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&apos;", "'"),
        ("&nbsp;", " "),
        ("&mdash;", "—"),
        ("&ndash;", "–"),
        ("&hellip;", "…"),
        ("&rsquo;", "’"),
        ("&lsquo;", "‘"),
        ("&rdquo;", "”"),
        ("&ldquo;", "“"),
    ]

    private final class Box {

        let value: AttributedString

        init(_ value: AttributedString) {
            self.value = value
        }
    }

    private nonisolated(unsafe) static let cache = NSCache<NSString, Box>()

    private static let markupPattern = "<[a-zA-Z/!]|&[a-zA-Z#0-9]+;"

    // MARK: - Plain text

    static func strip(_ text: String) -> String {
        guard text.range(of: markupPattern, options: .regularExpression) != nil else {
            return text
        }

        let result = breakLines(text)
            .replacingOccurrences(of: "<[a-zA-Z/!][^>]*>", with: "", options: .regularExpression)

        return decodeEntities(result).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decodes named and numeric character references. `&amp;` is decoded last so text is never decoded twice.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }

        var result = text

        if let numeric = try? NSRegularExpression(pattern: "&#([xX]?)([0-9a-fA-F]+);") {
            let matches = numeric.matches(in: result, range: NSRange(result.startIndex..., in: result))

            for match in matches.reversed() {
                guard let range = Range(match.range, in: result),
                      let hexRange = Range(match.range(at: 1), in: result),
                      let valueRange = Range(match.range(at: 2), in: result),
                      let value = UInt32(result[valueRange], radix: result[hexRange].isEmpty ? 10 : 16),
                      let scalar = Unicode.Scalar(value) else { continue }

                result.replaceSubrange(range, with: String(Character(scalar)))
            }
        }

        for (entity, value) in entities {
            result = result.replacing(entity, with: value)
        }

        return result.replacing("&amp;", with: "&")
    }

    private static func breakLines(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</p>\\s*", with: "\n", options: [.regularExpression, .caseInsensitive])
    }

    // MARK: - Attributed

    static func parse(_ overview: String) -> AttributedString {
        // Only text containing something tag- or entity-shaped is treated as HTML,
        // so plain text like "5 < 6" keeps its own whitespace.
        guard overview.range(of: markupPattern, options: .regularExpression) != nil else {
            return AttributedString(overview)
        }

        if let cached = cache.object(forKey: overview as NSString) {
            return cached.value
        }

        let parsed = parseHTML(overview)
        cache.setObject(Box(parsed), forKey: overview as NSString)
        return parsed
    }

    /// Converts simple HTML to an `AttributedString`, keeping bold and italic emphasis.
    ///
    /// This deliberately avoids the WebKit HTML importer, which spins the run loop,
    /// can re-enter SwiftUI updates, and may load remote resources synchronously.
    private static func parseHTML(_ html: String) -> AttributedString {
        let normalized = breakLines(html)

        guard let tagPattern = try? NSRegularExpression(pattern: "<(/?)([a-zA-Z0-9]+)[^>]*>|<![^>]*>") else {
            return AttributedString(strip(html))
        }

        var result = AttributedString()
        var bold = 0
        var italic = 0
        var cursor = normalized.startIndex

        func append(_ text: Substring) {
            guard !text.isEmpty else { return }

            var run = AttributedString(decodeEntities(String(text)))
            var intent: InlinePresentationIntent = []

            if bold > 0 {
                intent.insert(.stronglyEmphasized)
            }

            if italic > 0 {
                intent.insert(.emphasized)
            }

            if !intent.isEmpty {
                run.inlinePresentationIntent = intent
            }

            result += run
        }

        for match in tagPattern.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) {
            guard let range = Range(match.range, in: normalized) else { continue }

            append(normalized[cursor ..< range.lowerBound])
            cursor = range.upperBound

            guard let nameRange = Range(match.range(at: 2), in: normalized) else { continue }

            let isClosing = Range(match.range(at: 1), in: normalized).map { !normalized[$0].isEmpty } ?? false
            let delta = isClosing ? -1 : 1

            switch normalized[nameRange].lowercased() {
            case "b", "strong":
                bold = max(0, bold + delta)
            case "i", "em":
                italic = max(0, italic + delta)
            default:
                break
            }
        }

        append(normalized[cursor...])

        while let first = result.characters.first, first.isWhitespace {
            result.characters.removeFirst()
        }

        while let last = result.characters.last, last.isWhitespace {
            result.characters.removeLast()
        }

        return result
    }
}
