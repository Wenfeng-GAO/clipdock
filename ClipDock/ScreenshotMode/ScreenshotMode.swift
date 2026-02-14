import Foundation

enum ScreenshotMode {
    static var isEnabled: Bool {
        #if DEBUG
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SCREENSHOT_MODE"] == "1"
        #else
        return false
        #endif
        #else
        return false
        #endif
    }
}

