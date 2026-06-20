import AppKit
import Foundation

func runHeadlessCommandIfNeeded() -> Int32? {
    nil
}

#if !COMPANION_TESTING
@main
private enum CompanionApplication {
    static func main() {
        if let exitCode = runHeadlessCommandIfNeeded() {
            exit(exitCode)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
#endif
