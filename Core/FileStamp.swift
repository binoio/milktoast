import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Marks a file as Milktoast's work, and records which source and settings built
/// it.
///
/// This is what lets a sidecar sitting next to a movie be reused on the next
/// open, rebuilt when the source changes, and — crucially — distinguished from a
/// file the user put there themselves, which must never be touched.
public enum FileStamp {
    public static let attributeName = "io.bino.milktoast.source"

    /// The stamp on `path`, or nil if there is none (including on platforms with
    /// no extended-attribute support, where every file reads as not ours).
    public static func read(at path: String) -> String? {
        #if canImport(Darwin)
        let size = getxattr(path, attributeName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(path, attributeName, &buffer, size, 0, 0) == size else { return nil }
        return String(bytes: buffer, encoding: .utf8)
        #else
        return nil
        #endif
    }

    @discardableResult
    public static func write(_ stamp: String, at path: String) -> Bool {
        #if canImport(Darwin)
        let bytes = Array(stamp.utf8)
        return setxattr(path, attributeName, bytes, bytes.count, 0, 0) == 0
        #else
        return false
        #endif
    }

    /// Extended attributes are the mechanism, so a filesystem that does not carry
    /// them (some network mounts) simply never reports a file as ours.
    public static var isSupported: Bool {
        #if canImport(Darwin)
        return true
        #else
        return false
        #endif
    }
}
