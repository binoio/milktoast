import Foundation

/// The subset of `ffprobe -print_format json` output that the remux planner needs.
public struct ProbeResult: Codable, Sendable, Equatable {
    public var streams: [ProbeStream]
    public var chapters: [ProbeChapter]
    public var format: ProbeFormat?

    public init(streams: [ProbeStream] = [], chapters: [ProbeChapter] = [], format: ProbeFormat? = nil) {
        self.streams = streams
        self.chapters = chapters
        self.format = format
    }

    public var duration: Double? { format?.durationSeconds }

    public func streams(of kind: MediaKind) -> [ProbeStream] {
        streams.filter { $0.kind == kind }
    }

    /// Decodes ffprobe JSON. ffprobe emits snake_case keys.
    public static func decode(_ data: Data) throws -> ProbeResult {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ProbeResult.self, from: data)
    }

    enum CodingKeys: String, CodingKey { case streams, chapters, format }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        streams = try c.decodeIfPresent([ProbeStream].self, forKey: .streams) ?? []
        chapters = try c.decodeIfPresent([ProbeChapter].self, forKey: .chapters) ?? []
        format = try c.decodeIfPresent(ProbeFormat.self, forKey: .format)
    }
}

public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case video, audio, subtitle, data, attachment, unknown

    init(ffprobeCodecType: String?) {
        switch ffprobeCodecType?.lowercased() {
        case "video": self = .video
        case "audio": self = .audio
        case "subtitle": self = .subtitle
        case "data": self = .data
        case "attachment": self = .attachment
        default: self = .unknown
        }
    }
}

public struct ProbeStream: Codable, Sendable, Equatable {
    public var index: Int
    public var codecName: String?
    public var codecType: String?
    public var codecTagString: String?
    public var profile: String?
    public var pixFmt: String?
    public var width: Int?
    public var height: Int?
    public var channels: Int?
    public var channelLayout: String?
    public var bitsPerRawSample: String?
    public var bitRate: String?
    public var disposition: [String: Int]?
    public var tags: [String: String]?
    public var sideDataList: [ProbeSideData]?

    public init(
        index: Int,
        codecName: String? = nil,
        codecType: String? = nil,
        codecTagString: String? = nil,
        profile: String? = nil,
        pixFmt: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        channels: Int? = nil,
        channelLayout: String? = nil,
        bitsPerRawSample: String? = nil,
        bitRate: String? = nil,
        disposition: [String: Int]? = nil,
        tags: [String: String]? = nil,
        sideDataList: [ProbeSideData]? = nil
    ) {
        self.index = index
        self.codecName = codecName
        self.codecType = codecType
        self.codecTagString = codecTagString
        self.profile = profile
        self.pixFmt = pixFmt
        self.width = width
        self.height = height
        self.channels = channels
        self.channelLayout = channelLayout
        self.bitsPerRawSample = bitsPerRawSample
        self.bitRate = bitRate
        self.disposition = disposition
        self.tags = tags
        self.sideDataList = sideDataList
    }

    public var kind: MediaKind { MediaKind(ffprobeCodecType: codecType) }
    public var codec: String { codecName?.lowercased() ?? "" }
    public var language: String? { tag("language") }
    public var title: String? { tag("title") }
    public var isDefault: Bool { (disposition?["default"] ?? 0) == 1 }
    public var isForced: Bool { (disposition?["forced"] ?? 0) == 1 }
    public var bitsPerSecond: Int? { bitRate.flatMap { Int($0) } }

    /// ffprobe tag keys are case- and locale-inconsistent across muxers (`language`,
    /// `LANGUAGE`, `title`, `TITLE`), so look them up case-insensitively.
    public func tag(_ name: String) -> String? {
        guard let tags else { return nil }
        if let exact = tags[name] { return exact.isEmpty ? nil : exact }
        let lowered = name.lowercased()
        for (key, value) in tags where key.lowercased() == lowered {
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// True when the pixel format or profile indicates more than 8 bits per component.
    public var isHighBitDepth: Bool {
        if let pixFmt, pixFmt.contains("p10") || pixFmt.contains("p12") || pixFmt.contains("p16") { return true }
        if let bits = bitsPerRawSample.flatMap({ Int($0) }), bits > 8 { return true }
        if let profile, profile.lowercased().contains("10") { return true }
        return false
    }

    public var hasDolbyVision: Bool {
        sideDataList?.contains { ($0.sideDataType ?? "").lowercased().contains("dovi") } ?? false
    }
}

public struct ProbeSideData: Codable, Sendable, Equatable {
    public var sideDataType: String?
    public init(sideDataType: String? = nil) { self.sideDataType = sideDataType }
}

public struct ProbeChapter: Codable, Sendable, Equatable {
    public var id: Int?
    public var startTime: String?
    public var endTime: String?
    public var tags: [String: String]?
    public init(id: Int? = nil, startTime: String? = nil, endTime: String? = nil, tags: [String: String]? = nil) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.tags = tags
    }
}

public struct ProbeFormat: Codable, Sendable, Equatable {
    public var formatName: String?
    public var duration: String?
    public var size: String?
    public var bitRate: String?
    public var tags: [String: String]?

    public init(formatName: String? = nil, duration: String? = nil, size: String? = nil, bitRate: String? = nil, tags: [String: String]? = nil) {
        self.formatName = formatName
        self.duration = duration
        self.size = size
        self.bitRate = bitRate
        self.tags = tags
    }

    public var durationSeconds: Double? {
        guard let duration, let value = Double(duration), value.isFinite, value > 0 else { return nil }
        return value
    }

    public var title: String? {
        guard let tags else { return nil }
        for (key, value) in tags where key.lowercased() == "title" {
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
