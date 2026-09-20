// Used by probe-video-editor.sh. All editor, timeline, compositor, export,
// source-ownership and progress code is compiled directly from macshot/.
// Only unrelated app services, colors and localization are stubbed here.
import Cocoa
enum ProbeInput {
    static var directory: URL { Bundle.main.bundleURL.deletingLastPathComponent() }
    static var url: URL { directory.appendingPathComponent("input.mp4") }
}
func L(_ value: String) -> String { value }
enum ToolbarLayout {
    static var bgColor: NSColor { NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1) }
    static var iconColor: NSColor { .white }
    static var accentColor: NSColor { .systemBlue }
    static var appearance: NSAppearance { NSAppearance(named: .darkAqua)! }
}
enum SaveDirectoryAccess {
    static func resolveRecordingDirectoryIfAccessible() -> URL? { ProbeInput.directory }
    static func recordingDirectoryHint() -> URL? { resolveRecordingDirectoryIfAccessible() }
    static func stopAccessing(url: URL) {}
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let termination = ApplicationTerminationCoordinator()
    func returnFocusIfNeeded() {}
    func showFailureToast(_ text: String) { print("ERROR: " + text) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        VideoEditorWindowController.open(url: ProbeInput.url, deleteOnClose: false)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        termination.request(hasActiveWork: MediaExportCoordinator.shared.hasActiveJobs,
            drain: { await MediaExportCoordinator.shared.waitUntilIdle() }, terminate: { sender.terminate(nil) })
    }
}
@main struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
