import Foundation

/// A time-zone answer for the Command Bar: "4pm utc" → your local time.
public struct TimeConversion: Equatable, Sendable {
    /// The moment being converted.
    public let instant: Date
    public let source: TimeZone
    public let target: TimeZone
    /// "time in tokyo": the current time somewhere, not a conversion.
    public let isNow: Bool
}

/// Parses natural time-zone queries:
///   4pm utc · 16:00 UTC · 4:30pm new york · noon gmt+2 · 3pm in london (→ local)
///   9am pst to cet · 10am to tokyo (local → tokyo) · time in tokyo · tokyo time
/// US/EU abbreviations map to their region (PST in July means Pacific time, as people use it).
public enum TimeZoneQuery {
    public static func parse(_ input: String, now: Date = .now, local: TimeZone = .current) -> TimeConversion? {
        var text = input.lowercased()
            .replacingOccurrences(of: "→", with: " to ")
            .replacingOccurrences(of: "->", with: " to ")
            .replacingOccurrences(of: "?", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty, text.count <= 60 else { return nil }

        // "time in tokyo", "what time is it in tokyo", "tokyo time"
        for prefix in ["what time is it in ", "what's the time in ", "whats the time in ", "current time in ",
                       "time in ", "now in "] where text.hasPrefix(prefix) {
            guard let zone = zone(String(text.dropFirst(prefix.count)), local: local) else { return nil }
            return TimeConversion(instant: now, source: zone, target: zone, isNow: true)
        }
        if text.hasSuffix(" time"), let zone = zone(String(text.dropLast(5)), local: local) {
            return TimeConversion(instant: now, source: zone, target: zone, isNow: true)
        }

        // Split off an explicit target: "<time> <zone> to|in|as <zone>"
        var targetText: String?
        var connector: String?
        for word in [" to ", " in ", " as "] {
            if let range = text.range(of: word, options: .backwards) {
                targetText = String(text[range.upperBound...])
                connector = word.trimmingCharacters(in: .whitespaces)
                text = String(text[..<range.lowerBound])
                break
            }
        }

        guard let (hour, minute, rest) = splitTime(text) else { return nil }
        let sourceZone = rest.isEmpty ? nil : zone(rest, local: local)
        if !rest.isEmpty && sourceZone == nil { return nil }
        var targetZone: TimeZone?
        if let targetText {
            guard let z = zone(targetText, local: local) else { return nil }
            targetZone = z
        }

        let source: TimeZone
        let target: TimeZone
        switch (sourceZone, targetZone) {
        case let (s?, t?): source = s; target = t
        case let (s?, nil): source = s; target = local
        case let (nil, t?):
            // "3pm in london" means London time; "10am to tokyo" means my 10am in Tokyo.
            if connector == "in" { source = t; target = local } else { source = local; target = t }
        case (nil, nil): return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = source
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        guard let instant = calendar.date(from: components) else { return nil }
        return TimeConversion(instant: instant, source: source, target: target, isNow: false)
    }

    /// Finds a clock time at the start or end of `text`; returns the remaining zone text.
    private static func splitTime(_ text: String) -> (Int, Int, String)? {
        let time = #"(noon|midnight|(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?)"#
        let patterns = [#"^(?:at\s+)?"# + time + #"(?:\s+(.*))?$"#, #"^(.*?)\s+(?:at\s+)?"# + time + #"$"#]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            func group(_ i: Int) -> String? {
                guard let r = Range(m.range(at: i), in: text) else { return nil }
                return String(text[r])
            }
            // Group layout differs: zone-last puts the zone after the time groups.
            let offset = index == 0 ? 0 : 1
            let whole = group(1 + offset) ?? ""
            let zoneText = (index == 0 ? group(5) : group(1)) ?? ""
            var hour: Int
            var minute = 0
            if whole == "noon" { hour = 12 } else if whole == "midnight" { hour = 0 } else {
                guard let h = group(2 + offset).flatMap(Int.init) else { continue }
                hour = h
                minute = group(3 + offset).flatMap(Int.init) ?? 0
                let meridiem = group(4 + offset)?.replacingOccurrences(of: ".", with: "")
                if let meridiem {
                    guard (1...12).contains(hour) else { continue }
                    if meridiem == "pm", hour != 12 { hour += 12 }
                    if meridiem == "am", hour == 12 { hour = 0 }
                } else {
                    // A bare number only counts as a time when it has minutes ("16:00").
                    guard group(3 + offset) != nil else { continue }
                }
            }
            guard (0...23).contains(hour), (0...59).contains(minute) else { continue }
            return (hour, minute, zoneText.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    // MARK: Zone names

    public static func zone(_ raw: String, local: TimeZone = .current) -> TimeZone? {
        var name = raw.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix(" time") { name = String(name.dropLast(5)) }
        guard !name.isEmpty else { return nil }
        if ["local", "my time", "here", "mine", "me", "my timezone", "my tz"].contains(name) { return local }
        if let id = abbreviations[name] ?? aliases[name] { return TimeZone(identifier: id) }
        if let offset = offsetZone(name) { return offset }
        let key = name.replacingOccurrences(of: " ", with: "_")
        return cityIndex[key].flatMap(TimeZone.init(identifier:))
    }

    private static func offsetZone(_ name: String) -> TimeZone? {
        guard let regex = try? NSRegularExpression(pattern: #"^(?:utc|gmt)?\s*([+-])\s*(\d{1,2})(?::?(\d{2}))?$"#),
              let m = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let signRange = Range(m.range(at: 1), in: name),
              let hourRange = Range(m.range(at: 2), in: name),
              let hours = Int(name[hourRange]), hours <= 14 else { return nil }
        let minutes = Range(m.range(at: 3), in: name).flatMap { Int(name[$0]) } ?? 0
        let sign = name[signRange] == "-" ? -1 : 1
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }

    /// "tokyo" → Asia/Tokyo, "new_york" → America/New_York, from the system zone database.
    private static let cityIndex: [String: String] = {
        var index: [String: String] = [:]
        for id in TimeZone.knownTimeZoneIdentifiers {
            guard let city = id.split(separator: "/").last?.lowercased() else { continue }
            if index[city] == nil { index[city] = id }
        }
        return index
    }()

    private static let abbreviations: [String: String] = [
        "utc": "UTC", "gmt": "GMT", "z": "UTC", "zulu": "UTC", "ut": "UTC",
        "est": "America/New_York", "edt": "America/New_York", "et": "America/New_York", "eastern": "America/New_York",
        "cst": "America/Chicago", "cdt": "America/Chicago", "ct": "America/Chicago", "central": "America/Chicago",
        "mst": "America/Denver", "mdt": "America/Denver", "mt": "America/Denver", "mountain": "America/Denver",
        "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles", "pt": "America/Los_Angeles",
        "pacific": "America/Los_Angeles",
        "akst": "America/Anchorage", "akdt": "America/Anchorage", "hst": "Pacific/Honolulu",
        "ast": "America/Halifax", "adt": "America/Halifax", "nst": "America/St_Johns", "ndt": "America/St_Johns",
        "bst": "Europe/London", "wet": "Europe/Lisbon", "west": "Europe/Lisbon",
        "cet": "Europe/Berlin", "cest": "Europe/Berlin", "met": "Europe/Berlin",
        "eet": "Europe/Helsinki", "eest": "Europe/Helsinki", "msk": "Europe/Moscow", "trt": "Europe/Istanbul",
        "ist": "Asia/Kolkata", "pkt": "Asia/Karachi", "gst": "Asia/Dubai", "ict": "Asia/Bangkok",
        "wib": "Asia/Jakarta", "sgt": "Asia/Singapore", "hkt": "Asia/Hong_Kong", "pht": "Asia/Manila",
        "jst": "Asia/Tokyo", "kst": "Asia/Seoul", "awst": "Australia/Perth", "acst": "Australia/Adelaide",
        "acdt": "Australia/Adelaide", "aest": "Australia/Sydney", "aedt": "Australia/Sydney",
        "nzst": "Pacific/Auckland", "nzdt": "Pacific/Auckland", "nzt": "Pacific/Auckland",
        "brt": "America/Sao_Paulo", "art": "America/Argentina/Buenos_Aires",
        "sast": "Africa/Johannesburg", "wat": "Africa/Lagos", "cat": "Africa/Maputo", "eat": "Africa/Nairobi",
    ]

    private static let aliases: [String: String] = [
        "sf": "America/Los_Angeles", "san francisco": "America/Los_Angeles", "bay area": "America/Los_Angeles",
        "silicon valley": "America/Los_Angeles", "seattle": "America/Los_Angeles", "la": "America/Los_Angeles",
        "california": "America/Los_Angeles", "portland": "America/Los_Angeles",
        "nyc": "America/New_York", "ny": "America/New_York", "new york city": "America/New_York",
        "boston": "America/New_York", "miami": "America/New_York", "washington": "America/New_York",
        "dc": "America/New_York", "atlanta": "America/New_York",
        "texas": "America/Chicago", "dallas": "America/Chicago", "austin": "America/Chicago",
        "houston": "America/Chicago", "arizona": "America/Phoenix", "hawaii": "Pacific/Honolulu",
        "alaska": "America/Anchorage",
        "uk": "Europe/London", "england": "Europe/London", "britain": "Europe/London", "scotland": "Europe/London",
        "ireland": "Europe/Dublin", "germany": "Europe/Berlin", "france": "Europe/Paris", "spain": "Europe/Madrid",
        "italy": "Europe/Rome", "netherlands": "Europe/Amsterdam", "poland": "Europe/Warsaw",
        "lithuania": "Europe/Vilnius", "latvia": "Europe/Riga", "estonia": "Europe/Tallinn",
        "finland": "Europe/Helsinki", "sweden": "Europe/Stockholm", "norway": "Europe/Oslo",
        "denmark": "Europe/Copenhagen", "switzerland": "Europe/Zurich", "portugal": "Europe/Lisbon",
        "ukraine": "Europe/Kyiv", "kyiv": "Europe/Kyiv", "kiev": "Europe/Kyiv", "turkey": "Europe/Istanbul",
        "russia": "Europe/Moscow", "israel": "Asia/Jerusalem", "tel aviv": "Asia/Jerusalem",
        "uae": "Asia/Dubai", "india": "Asia/Kolkata", "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata",
        "mumbai": "Asia/Kolkata", "bangalore": "Asia/Kolkata", "bengaluru": "Asia/Kolkata",
        "china": "Asia/Shanghai", "beijing": "Asia/Shanghai", "japan": "Asia/Tokyo", "korea": "Asia/Seoul",
        "south korea": "Asia/Seoul", "vietnam": "Asia/Ho_Chi_Minh", "thailand": "Asia/Bangkok",
        "indonesia": "Asia/Jakarta", "philippines": "Asia/Manila", "australia": "Australia/Sydney",
        "new zealand": "Pacific/Auckland", "brazil": "America/Sao_Paulo", "argentina": "America/Argentina/Buenos_Aires",
        "mexico": "America/Mexico_City", "canada": "America/Toronto", "south africa": "Africa/Johannesburg",
        "nigeria": "Africa/Lagos", "kenya": "Africa/Nairobi", "egypt": "Africa/Cairo",
    ]
}
