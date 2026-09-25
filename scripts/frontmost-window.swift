// Prints the owner of the frontmost on-screen app window (used by perf.sh to verify visibility).
import CoreGraphics
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let front = windows.first { ($0[kCGWindowLayer as String] as? Int) == 0 }
print(front?[kCGWindowOwnerName as String] as? String ?? "none")
