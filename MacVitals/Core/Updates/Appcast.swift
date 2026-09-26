import Foundation

/// Compares version strings the way Sparkle does: "1.10" > "1.9", "2.0" > "2.0b3",
/// "1.2" == "1.2.0". Numbers compare numerically, letters mark pre-releases.
enum VersionComparator {
    private enum Part: Equatable {
        case number(Int)
        case text(String)
    }

    private static func parts(_ version: String) -> [Part] {
        var parts: [Part] = []
        var current = ""
        var isDigit: Bool?
        func flush() {
            guard !current.isEmpty else { return }
            parts.append(isDigit == true ? .number(Int(current.prefix(18)) ?? 0) : .text(current.lowercased()))
            current = ""
        }
        for character in version.trimmingCharacters(in: .whitespaces) {
            if character == "." || character == "-" || character == "_" || character == " " || character == "+" {
                flush(); isDigit = nil
                continue
            }
            let digit = character.isNumber
            if isDigit != nil && digit != isDigit { flush() }
            isDigit = digit
            current.append(character)
        }
        flush()
        return parts
    }

    /// -1: a < b, 0: equal, 1: a > b.
    static func compare(_ a: String, _ b: String) -> Int {
        let left = parts(a), right = parts(b)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : nil
            let r = index < right.count ? right[index] : nil
            switch (l, r) {
            case let (.number(x)?, .number(y)?):
                if x != y { return x < y ? -1 : 1 }
            case let (.text(x)?, .text(y)?):
                if x != y { return x < y ? -1 : 1 }
            case (.number?, .text?): return 1   // 1.0.1 > 1.0b
            case (.text?, .number?): return -1
            case (.number(let x)?, nil): if x != 0 { return 1 }   // 1.2.1 > 1.2, but 1.2.0 == 1.2
            case (nil, .number(let y)?): if y != 0 { return -1 }
            case (.text?, nil): return -1       // 2.0b1 < 2.0
            case (nil, .text?): return 1
            case (nil, nil): return 0
            }
        }
        return 0
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool { compare(candidate, installed) > 0 }
}

/// One release in a Sparkle appcast.
struct AppcastItem: Equatable, Sendable {
    var title: String?
    /// Build number (compared against CFBundleVersion, like Sparkle does).
    var version: String?
    /// Version people see (CFBundleShortVersionString).
    var shortVersion: String?
    var downloadURL: URL?
    var length: Int64?
    var minimumSystemVersion: String?
    var maximumSystemVersion: String?
    var releaseNotesURL: URL?
    var notesHTML: String?
    var channel: String?
    var isCritical = false
    var pubDate: Date?
    var isDelta = false

    var displayVersion: String? { shortVersion ?? version }
}

/// Parses Sparkle appcast feeds (the RSS files apps publish their updates in).
final class AppcastParser: NSObject, XMLParserDelegate {
    private var items: [AppcastItem] = []
    private var current: AppcastItem?
    private var text = ""
    private var inDeltas = false

    static func parse(_ data: Data) -> [AppcastItem] {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        return delegate.items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "item": current = AppcastItem()
        case "sparkle:deltas": inDeltas = true
        case "sparkle:criticalUpdate": current?.isCritical = true
        case "enclosure" where !inDeltas:
            guard current != nil else { return }
            if let url = attributes["url"].flatMap(URL.init(string:)) { current?.downloadURL = url }
            if let length = attributes["length"].flatMap(Int64.init) { current?.length = length }
            if let version = attributes["sparkle:version"], current?.version == nil { current?.version = version }
            if let short = attributes["sparkle:shortVersionString"], current?.shortVersion == nil { current?.shortVersion = short }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }
        guard current != nil else { return }
        switch name {
        case "item":
            if let item = current { items.append(item) }
            current = nil
        case "sparkle:deltas": inDeltas = false
        case "title": current?.title = value
        case "sparkle:version": current?.version = value
        case "sparkle:shortVersionString": current?.shortVersion = value
        case "sparkle:minimumSystemVersion": current?.minimumSystemVersion = value
        case "sparkle:maximumSystemVersion": current?.maximumSystemVersion = value
        case "sparkle:releaseNotesLink", "sparkle:fullReleaseNotesLink":
            if current?.releaseNotesURL == nil { current?.releaseNotesURL = URL(string: value) }
        case "description": current?.notesHTML = value
        case "sparkle:channel": current?.channel = value
        case "pubDate": current?.pubDate = Self.rfc822.date(from: value)
        default: break
        }
    }

    private static let rfc822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()
}

enum Appcast {
    /// The newest release this Mac can run, from the default channel. Also reports whether a
    /// newer one exists that needs a newer macOS.
    static func best(_ items: [AppcastItem], osVersion: String = currentOSVersion) -> (item: AppcastItem?, needsNewerMacOS: String?) {
        let eligible = items.filter { $0.channel == nil && $0.downloadURL != nil && ($0.version ?? $0.shortVersion) != nil }
        func key(_ item: AppcastItem) -> String { item.version ?? item.shortVersion ?? "0" }
        let sorted = eligible.sorted { VersionComparator.compare(key($0), key($1)) > 0 }
        let runnable = sorted.first { item in
            (item.minimumSystemVersion.map { VersionComparator.compare(osVersion, $0) >= 0 } ?? true)
                && (item.maximumSystemVersion.map { VersionComparator.compare(osVersion, $0) <= 0 } ?? true)
        }
        var needsNewer: String?
        if let newest = sorted.first, let minimum = newest.minimumSystemVersion,
           VersionComparator.compare(osVersion, minimum) < 0 {
            needsNewer = minimum
        }
        return (runnable, needsNewer)
    }

    static var currentOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Release notes are usually HTML; show the first few lines as plain text.
    static func plainText(fromHTML html: String, limit: Int = 600) -> String {
        var text = html
        for (pattern, replacement) in [("<br\\s*/?>", "\n"), ("</(p|li|h[1-6]|div)>", "\n"), ("<li[^>]*>", "• "), ("<[^>]+>", "")] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let joined = lines.joined(separator: "\n")
        return joined.count > limit ? String(joined.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…" : joined
    }
}
