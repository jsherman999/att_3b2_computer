import AppKit

/// Testing aid: `-debugCapture <dir>` writes the console window as PNG and the terminal
/// text buffer every few seconds (screen-recording permission isn't needed this way).
@MainActor
enum DebugCapture {
    private static var timer: Timer?

    static func startIfRequested(console: @escaping () -> ConsoleTerminalView?) {
        guard let dir = UserDefaults.standard.string(forKey: "debugCapture"), timer == nil else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let view = console() else { return }
                try? view.getBufferAsData().write(to: url.appendingPathComponent("console.txt"))
                if let content = view.window?.contentView,
                   let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: url.appendingPathComponent("window.png"))
                }
                try? "\(Machine.shared.state.rawValue)\n".write(to: url.appendingPathComponent("state.txt"),
                                                                 atomically: true, encoding: .utf8)
            }
        }
    }
}
