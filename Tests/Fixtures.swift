import Foundation
import XCTest
@testable import MilktoastCore

enum Fixtures {
    static func probe(_ name: String) throws -> ProbeResult {
        try ProbeResult.decode(try data(name))
    }

    static func data(_ name: String) throws -> Data {
        if let url = Bundle.module.url(forResource: "Fixtures/" + name, withExtension: "json")
            ?? Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") {
            return try Data(contentsOf: url)
        }
        // Fall back to the source tree, which keeps the suite runnable from a
        // plain `swift test` on Linux where resource bundles land differently.
        let candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: candidate)
    }

    static let macOS14 = PlaybackCapabilities.forMacOS(majorVersion: 14)
    static let macOS13 = PlaybackCapabilities.forMacOS(majorVersion: 13)
    static let noHardware = PlaybackCapabilities.forMacOS(majorVersion: 14, hasVideoToolbox: false)
}
