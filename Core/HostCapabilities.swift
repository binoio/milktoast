import Foundation

public enum HostCapabilities {
    /// Capabilities of the machine this process is running on.
    ///
    /// VideoToolbox encoders are assumed present on Apple silicon and on any
    /// Intel Mac new enough to run macOS 14; the planner only ever treats them as
    /// a preference, and ffmpeg falls back on its own if an encoder is missing.
    public static func current(
        processInfo: ProcessInfo = .processInfo
    ) -> PlaybackCapabilities {
        #if os(macOS)
        let version = processInfo.operatingSystemVersion
        return .forMacOS(majorVersion: version.majorVersion, hasVideoToolbox: true)
        #else
        return .conservative
        #endif
    }
}
