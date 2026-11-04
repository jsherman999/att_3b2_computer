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
                writeDMDScreen(to: url.appendingPathComponent("dmd.png"))
                try? "\(DMDTerminal.shared.link)\n".write(to: url.appendingPathComponent("dmd-link.txt"),
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
            case "dmdtype":       // keystrokes on the 5620 keyboard
                for b in rest.replacingOccurrences(of: "\\r", with: "\r").utf8 { DMDTerminal.shared.key(b) }
            case "dmdslow":       // keystrokes at typing speed (~8/s)
                for b in rest.replacingOccurrences(of: "\\r", with: "\r").utf8 {
                    DMDTerminal.shared.key(b); usleep(120_000)
                }
            case "dmdclick":      // dmdclick x y button  (5620 coordinates, y from the bottom)
                let f = rest.split(separator: " ").compactMap { Int($0) }
                if f.count == 3 {
                    DMDTerminal.shared.mouseMove(x: f[0], y: f[1])
                    DMDTerminal.shared.mouseDown(UInt8(f[2]))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { DMDTerminal.shared.mouseUp(UInt8(f[2])) }
                }
            case "dmdpress":      // dmdpress x y button: hold the button (menus), dmdrelease to let go
                let f = rest.split(separator: " ").compactMap { Int($0) }
                if f.count == 3 { DMDTerminal.shared.mouseMove(x: f[0], y: f[1]); DMDTerminal.shared.mouseDown(UInt8(f[2])) }
            case "dmdmove":
                let f = rest.split(separator: " ").compactMap { Int($0) }
                if f.count == 2 { DMDTerminal.shared.mouseMove(x: f[0], y: f[1]) }
            case "dmdrelease":
                if let b = UInt8(rest) { DMDTerminal.shared.mouseUp(b) }
            case "sleep":         // sleep <ms>: the 5620 keeps running on its own thread
                usleep(useconds_t((Int(rest) ?? 0) * 1000))
            case "snap":          // snap <name>: write dmd-<name>.png now
                writeDMDScreen(to: dir.appendingPathComponent("dmd-\(rest).png"))
            default: break
            }
        }
    }

    /// The 5620 screen straight from video RAM (always current, unlike view caching).
    private static func writeDMDScreen(to url: URL) {
        var vram = [UInt8](repeating: 0, count: 100 * 1024)
        let dol = vram.withUnsafeMutableBufferPointer { DMDTerminal.shared.copyScreen(into: $0.baseAddress!) }
        var gray = [UInt8](repeating: 0, count: 800 * 1024)
        for i in 0..<(100 * 1024) {
            let b = vram[i]
            for bit in 0..<8 {
                let on = (b >> (7 - UInt8(bit))) & 1 == 1
                gray[i * 8 + bit] = (on != dol) ? 230 : 20
            }
        }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 1024, bitsPerSample: 8,
                                         samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
                                         colorSpaceName: .deviceWhite, bytesPerRow: 800, bitsPerPixel: 8),
              let dst = rep.bitmapData else { return }
        gray.withUnsafeBytes { dst.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: gray.count) }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
