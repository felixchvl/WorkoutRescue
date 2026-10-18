import Foundation

nonisolated enum JSONExporter {
    enum Style: Sendable { case compact, pretty }

    static func export(_ archive: WorkoutArchive, style: Style = .compact) throws -> Data {
        try makeEncoder(style: style).encode(archive)
    }

    static func decode(_ data: Data) throws -> WorkoutArchive {
        try makeDecoder().decode(WorkoutArchive.self, from: data)
    }

    static func makeEncoder(style: Style = .compact) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ArchiveDateCoding.string(from: date))
        }
        // A NaN/Infinity reading must never make the whole archive fail.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        encoder.outputFormatting = style == .pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = ArchiveDateCoding.date(from: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid archive date: \(raw)")
            }
            return date
        }
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return decoder
    }
}
