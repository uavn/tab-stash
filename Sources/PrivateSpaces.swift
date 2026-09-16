import Foundation
import CoreGraphics

/// Thin wrapper over undocumented SkyLight (CGS*) functions used to find out
/// which Space a window lives on.
/// Everything is resolved with dlsym at runtime, so if Apple removes a symbol
/// the app silently falls back to the public API.
enum PrivateSpaces {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias ManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private struct Fns {
        let mainConnection: MainConnectionFn
        let managedDisplaySpaces: ManagedDisplaySpacesFn
        let spacesForWindows: SpacesForWindowsFn
    }

    private static let fns: Fns? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let a = dlsym(handle, "CGSMainConnectionID"),
              let b = dlsym(handle, "CGSCopyManagedDisplaySpaces"),
              let c = dlsym(handle, "CGSCopySpacesForWindows") else { return nil }
        return Fns(mainConnection: unsafeBitCast(a, to: MainConnectionFn.self),
                   managedDisplaySpaces: unsafeBitCast(b, to: ManagedDisplaySpacesFn.self),
                   spacesForWindows: unsafeBitCast(c, to: SpacesForWindowsFn.self))
    }()

    static var isAvailable: Bool { fns != nil }

    struct DisplaySpaces {
        let displayID: String        // UUID string, or "Main" when displays share Spaces
        let current: UInt64
        let spaces: [UInt64]         // in Mission Control order, fullscreen Spaces included
    }

    static func displaySpaces() -> [DisplaySpaces] {
        guard let f = fns,
              let displays = f.managedDisplaySpaces(f.mainConnection())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return displays.compactMap { d in
            guard let id = d["Display Identifier"] as? String,
                  let current = d["Current Space"] as? [String: Any],
                  let cur = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? (current["id64"] as? NSNumber)?.uint64Value,
                  let spaces = d["Spaces"] as? [[String: Any]] else { return nil }
            let ids = spaces.compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? ($0["id64"] as? NSNumber)?.uint64Value }
            return DisplaySpaces(displayID: id, current: cur, spaces: ids)
        }
    }

    /// IDs of the Space currently shown on every display.
    static func activeSpaceIDs() -> Set<UInt64> {
        Set(displaySpaces().map { $0.current })
    }

    /// Spaces a given window belongs to (mask 7 = all spaces).
    static func spaceIDs(forWindow wid: CGWindowID) -> Set<UInt64> {
        guard let f = fns else { return [] }
        let arr = [NSNumber(value: wid)] as CFArray
        guard let spaces = f.spacesForWindows(f.mainConnection(), 7, arr)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return Set(spaces.map { $0.uint64Value })
    }
}
