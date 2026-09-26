import Foundation
#if canImport(Darwin)
import Darwin
#else
import CXattr
#endif

/// Marks a file as Milktoast's work, and records which source and settings built
/// it.
///
/// This is what lets a sidecar sitting next to a movie be reused on the next
/// open, rebuilt when the source changes, and — crucially — distinguished from a
/// file the user put there themselves, which must never be touched.
public enum FileStamp {
    /// Linux confines user-settable extended attributes to the `user.`
    /// namespace; Darwin has no such rule.
    #if canImport(Darwin)
    public static let attributeName = "io.bino.milktoast.source"
    #else
    public static let attributeName = "user.io.bino.milktoast.source"
    #endif

    /// The stamp on `path`, or nil if there is none — including on a filesystem
    /// that cannot carry extended attributes, where every file reads as not ours.
    public static func read(at path: String) -> String? {
        #if canImport(Darwin)
        let size = getxattr(path, attributeName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(path, attributeName, &buffer, size, 0, 0) == size else { return nil }
        return String(bytes: buffer, encoding: .utf8)
        #else
        let size = getxattr(path, attributeName, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(path, attributeName, &buffer, size) == size else { return nil }
        return String(bytes: buffer, encoding: .utf8)
        #endif
    }

    /// Whether `directory` can carry a stamp.
    ///
    /// Checked before writing a movie next to its source: on a volume that
    /// silently drops extended attributes, Milktoast could not recognise its own
    /// output on the next run and would add another copy every time.
    public static func canStamp(inDirectory directory: URL) -> Bool {
        let probe = directory.appendingPathComponent(".milktoast-xattr-probe-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data("probe".utf8)) else {
            return false
        }
        defer { try? FileManager.default.removeItem(at: probe) }
        let token = "probe"
        guard write(token, at: probe.path) else { return false }
        return read(at: probe.path) == token
    }

    /// Returns false when the volume cannot store the attribute, which is the
    /// caller's cue that its output will not be recognisable later.
    @discardableResult
    public static func write(_ stamp: String, at path: String) -> Bool {
        let bytes = Array(stamp.utf8)
        #if canImport(Darwin)
        return setxattr(path, attributeName, bytes, bytes.count, 0, 0) == 0
        #else
        return setxattr(path, attributeName, bytes, bytes.count, 0) == 0
        #endif
    }
}
