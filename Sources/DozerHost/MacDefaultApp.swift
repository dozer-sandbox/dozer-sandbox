import CoreServices
import Foundation

// 599b: the notice says WHICH app opened a workspace file ("hello-dozer opened report.html in Safari").
// LaunchServices is asked, read-only, which app is the default for that file — nothing is opened here
// (`WorkspaceFiles.open` does that with /usr/bin/open). The audit confines CoreServices to this file and
// `doz ui`'s UICommand.swift.

enum MacDefaultApp {
    /// The default app's name for the file at `path` (nil: none, or LaunchServices could not say).
    static func name(forFile path: String) -> String? {
        guard let app = LSCopyDefaultApplicationURLForURL(URL(fileURLWithPath: path) as CFURL, .all, nil)?.takeRetainedValue() else {
            return nil
        }
        let name = ((app as URL).lastPathComponent as NSString).deletingPathExtension
        return name.isEmpty ? nil : name
    }
}
