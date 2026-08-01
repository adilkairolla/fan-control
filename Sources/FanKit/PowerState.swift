import Foundation
import IOKit

/// Questions about the machine's physical state that fan control has to answer
/// before it drives anything.
public enum PowerState {

    /// Whether the laptop lid is shut.
    ///
    /// Returns `nil` on a machine that has no lid: `AppleClamshellState` is
    /// simply absent on a Mac mini or Studio, and absent is not the same as
    /// closed. A caller that collapsed the two would refuse to control the fans
    /// on every desktop Mac.
    public static func lidIsClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault,
                                               IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }

        guard let property = IORegistryEntryCreateCFProperty(
            root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }

        if let flag = property as? Bool { return flag }
        return (property as? NSNumber)?.boolValue
    }
}
