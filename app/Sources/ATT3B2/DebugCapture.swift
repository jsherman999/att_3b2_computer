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
                runCommands(in: url)
            }
        }
    }

    /// Test commands: each line of cmd.txt is run once, then the file is removed.
    /// power | reset | plug | snapshot <label> | type <text>   (\r in text = Return)
    private static func runCommands(in dir: URL) {
        let file = dir.appendingPathComponent("cmd.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: file)
        let m = Machine.shared
        for line in text.split(separator: "\n").map(String.init) {
            let (verb, rest) = line.firstIndex(of: " ").map { (String(line[..<$0]), String(line[line.index(after: $0)...])) } ?? (line, "")
            switch verb {
            case "power": m.pressPowerSwitch()
            case "reset": m.reset()
            case "plug": m.forceOff()
            case "snapshot": m.takeSnapshot(named: rest)
            case "type": m.console?.sendBytes(Array(rest.replacingOccurrences(of: "\\r", with: "\r").utf8))
            default: break
            }
        }
    }
}
