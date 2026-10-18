import Foundation

/// ISO 8601 UTC timestamps with microsecond precision, e.g. `2026-09-14T06:12:03.123456Z`.
///
/// `JSONEncoder.DateEncodingStrategy.iso8601` drops fractional seconds, which would merge GPS
/// points recorded within the same second. A `Date` is a Double; microseconds keep every
/// distinguishable instant of a CLLocation timestamp in the 1970–2100 range.
nonisolated enum ArchiveDateCoding {
    static func string(from date: Date) -> String {
        let interval = date.timeIntervalSince1970
        var seconds = interval.rounded(.down)
        var micros = Int(((interval - seconds) * 1_000_000).rounded())
        if micros >= 1_000_000 { seconds += 1; micros -= 1_000_000 }
        var time = time_t(seconds)
        var parts = tm()
        gmtime_r(&time, &parts)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%06dZ",
                      Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1, Int(parts.tm_mday),
                      Int(parts.tm_hour), Int(parts.tm_min), Int(parts.tm_sec), micros)
    }

    /// Accepts `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)`.
    static func date(from string: String) -> Date? {
        let chars = Array(string.utf8)
        func int(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= chars.count else { return nil }
            var value = 0
            for i in range { let c = chars[i]; guard c >= 48, c <= 57 else { return nil }; value = value * 10 + Int(c - 48) }
            return value
        }
        guard chars.count >= 20, chars[4] == 45, chars[7] == 45, chars[10] == 84, chars[13] == 58, chars[16] == 58,
              let year = int(0..<4), let month = int(5..<7), let day = int(8..<10),
              let hour = int(11..<13), let minute = int(14..<16), let second = int(17..<19) else { return nil }
        var index = 19
        var fraction = 0.0
        if chars[index] == 46 {
            index += 1
            var scale = 0.1
            let start = index
            while index < chars.count, chars[index] >= 48, chars[index] <= 57 {
                fraction += Double(chars[index] - 48) * scale; scale /= 10; index += 1
            }
            guard index > start else { return nil }
        }
        guard index < chars.count else { return nil }
        var offsetSeconds = 0
        if chars[index] == 90, index == chars.count - 1 {
            offsetSeconds = 0
        } else if chars[index] == 43 || chars[index] == 45, chars.count == index + 6, chars[index + 3] == 58,
                  let oh = int(index + 1..<index + 3), let om = int(index + 4..<index + 6) {
            offsetSeconds = (oh * 3600 + om * 60) * (chars[index] == 45 ? -1 : 1)
        } else { return nil }
        var parts = tm()
        parts.tm_year = Int32(year - 1900); parts.tm_mon = Int32(month - 1); parts.tm_mday = Int32(day)
        parts.tm_hour = Int32(hour); parts.tm_min = Int32(minute); parts.tm_sec = Int32(second)
        let epoch = timegm(&parts)
        return Date(timeIntervalSince1970: Double(epoch - offsetSeconds) + fraction)
    }
}
