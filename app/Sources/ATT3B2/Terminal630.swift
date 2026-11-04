import AppKit
import CDMD
import Foundation
import Observation

/// An AT&T 630 MTG (experimental: mtg630 core). Like the 5620 it takes the next free
/// PORTS line on 127.0.0.1:9001, wired to the 630's Main EIA port.
///
/// Status: the firmware self-tests, draws its desktop, runs menus and windows, and
/// shows host output in its H1 window. Keyboard input does not reach the host yet.
@Observable
final class Terminal630: @unchecked Sendable {
    enum Link: Equatable { case disconnected, connecting, connected, noROMs }

    static let shared = Terminal630()

    @MainActor var link: Link = .disconnected

    private var handle: OpaquePointer?
    private let stateLock = NSLock()
    private var running = false
    private var fd: Int32 = -1
    private var mouseX: UInt16 = 2048
    private var mouseY: UInt16 = 2048
    private var buttons: UInt8 = 0

    private static var romDir: URL { MachinePaths.resources.appendingPathComponent("seed/630", isDirectory: true) }
    private var bramURL: URL { MachinePaths.support.appendingPathComponent("630-bram.bin") }

    private init() {
        let names = ["460621-1.BIN", "460620-1.BIN", "460623-1.BIN", "460622-1.BIN"]
        let roms = names.compactMap { try? Data(contentsOf: Self.romDir.appendingPathComponent($0)) }
        guard roms.count == 4, roms.allSatisfy({ $0.count == 0x10000 }) else { return }
        let bram = try? Data(contentsOf: bramURL)
        let validBram = (bram?.count == Int(ATT630_BRAM_BYTES)) ? bram : nil
        roms[0].withUnsafeBytes { a in roms[1].withUnsafeBytes { b in roms[2].withUnsafeBytes { c in roms[3].withUnsafeBytes { d in
            let p = { (x: UnsafeRawBufferPointer) in x.bindMemory(to: UInt8.self).baseAddress }
            if let validBram {
                validBram.withUnsafeBytes { br in handle = att630_create(p(a), p(b), p(c), p(d), p(br)) }
            } else {
                handle = att630_create(p(a), p(b), p(c), p(d), nil)
            }
        } } } }
    }

    var available: Bool { handle != nil }

    func start() {
        guard handle != nil else { DispatchQueue.main.async { self.link = .noROMs }; return }
        stateLock.lock(); defer { stateLock.unlock() }
        guard !running else { return }
        running = true
        let t = Thread { [weak self] in self?.loop() }
        t.name = "AT&T 630 MTG"
        t.qualityOfService = .userInteractive
        t.start()
    }

    func stop() {
        stateLock.lock(); running = false; stateLock.unlock()
        saveBRAM()
    }

    func resetTerminal() { if let handle { att630_reset(handle) } }

    // MARK: Input

    /// Mouse motion arrives as deltas: the 630 reads free-running counters.
    func mouseMoved(dx: Int, dy: Int) {
        guard let handle else { return }
        mouseX = UInt16((Int(mouseX) + dx) & 0x0fff)
        mouseY = UInt16((Int(mouseY) + dy) & 0x0fff)
        att630_mouse(handle, mouseX, mouseY, buttons)
    }

    func button(_ n: Int, down: Bool) {
        guard let handle else { return }
        if down { buttons |= UInt8(1 << n) } else { buttons &= ~UInt8(1 << n) }
        att630_mouse(handle, mouseX, mouseY, buttons)
    }

    static let shiftCode: UInt8 = 0x1d
    static let ctrlCode: UInt8 = 0x1e
    /// Printable characters -> (scan code, needs Shift), from the firmware's table for
    /// keyboard type 0x11 (the 630's 98-key keyboard).
    static let keymap: [Character: (UInt8, Bool)] = [
        " ": (0x3e, false),
        "!": (0x0a, true),
        "\"": (0x25, true),
        "#": (0x41, true),
        "$": (0x01, true),
        "%": (0x6f, true),
        "&": (0x45, true),
        "'": (0x25, false),
        "(": (0x21, true),
        ")": (0x70, true),
        "*": (0x33, true),
        "+": (0x52, true),
        ",": (0x24, false),
        "-": (0x58, false),
        ".": (0x2a, false),
        "/": (0x30, false),
        "0": (0x70, false),
        "1": (0x27, false),
        "2": (0x76, false),
        "3": (0x41, false),
        "4": (0x01, false),
        "5": (0x6f, false),
        "6": (0x51, false),
        "7": (0x45, false),
        "8": (0x33, false),
        "9": (0x21, false),
        ":": (0x1f, true),
        ";": (0x1f, false),
        "<": (0x68, false),
        "=": (0x52, false),
        ">": (0x68, true),
        "?": (0x30, true),
        "@": (0x76, true),
        "A": (0x4a, true),
        "B": (0x74, true),
        "C": (0x15, true),
        "D": (0x1c, true),
        "E": (0x4c, true),
        "F": (0x0f, true),
        "G": (0x5d, true),
        "H": (0x57, true),
        "I": (0x14, true),
        "J": (0x7a, true),
        "K": (0x1a, true),
        "L": (0x0c, true),
        "M": (0x08, true),
        "N": (0x02, true),
        "O": (0x37, true),
        "P": (0x19, true),
        "Q": (0x44, true),
        "R": (0x09, true),
        "T": (0x69, true),
        "U": (0x3f, true),
        "V": (0x63, true),
        "W": (0x5c, true),
        "X": (0x22, true),
        "Y": (0x4b, true),
        "Z": (0x6e, true),
        "[": (0x0a, false),
        "\\": (0x16, false),
        "]": (0x27, true),
        "^": (0x51, true),
        "_": (0x58, true),
        "`": (0x5f, false),
        "a": (0x4a, false),
        "b": (0x74, false),
        "c": (0x15, false),
        "d": (0x1c, false),
        "e": (0x4c, false),
        "f": (0x0f, false),
        "g": (0x5d, false),
        "h": (0x57, false),
        "i": (0x14, false),
        "j": (0x7a, false),
        "k": (0x1a, false),
        "l": (0x0c, false),
        "m": (0x08, false),
        "n": (0x02, false),
        "o": (0x37, false),
        "p": (0x19, false),
        "q": (0x44, false),
        "r": (0x09, false),
        "t": (0x69, false),
        "u": (0x3f, false),
        "v": (0x63, false),
        "w": (0x5c, false),
        "x": (0x22, false),
        "y": (0x4b, false),
        "z": (0x6e, false),
        "{": (0x10, false),
        "|": (0x16, true),
        "}": (0x10, true),
        "~": (0x5f, true),
    ]
    static let specialKeys: [UInt16: UInt8] = [
        36: 0x55, 76: 0x55,   // Return
        48: 0x39,             // Tab
        51: 0x2e,             // Backspace
        53: 0x53,             // Escape
        117: 0x2d,            // Delete
    ]

    func type(_ event: NSEvent) {
        guard let handle else { return }
        let ctrl = event.modifierFlags.contains(.control)
        var code: UInt8?
        var shift = false
        if let s = Self.specialKeys[event.keyCode] {
            code = s
        } else if let ch = event.charactersIgnoringModifiers?.first, let m = Self.keymap[ch] {
            (code, shift) = m
        }
        guard let code else { return }
        if ctrl { att630_key(handle, Self.ctrlCode, true) }
        if shift { att630_key(handle, Self.shiftCode, true) }
        att630_key(handle, code, true)
        att630_key(handle, code, false)
        if shift { att630_key(handle, Self.shiftCode, false) }
        if ctrl { att630_key(handle, Self.ctrlCode, false) }
    }

    func copyScreen(into buffer: UnsafeMutablePointer<UInt8>) {
        if let handle { att630_copy_video(handle, buffer, Int(ATT630_VIDEO_BYTES)) }
    }

    // MARK: Engine thread: run the 68000 in real time, shuttle bytes to the 3B2.

    private var isRunning: Bool { stateLock.lock(); defer { stateLock.unlock() }; return running }

    private func loop() {
        guard let handle else { return }
        var last = Date()
        var lastConnect = Date.distantPast
        var rx = [UInt8](repeating: 0, count: 4096)
        var tx = [UInt8](repeating: 0, count: 512)
        while isRunning {
            let now = Date()
            let micros = UInt32(min(50_000, max(1, now.timeIntervalSince(last) * 1_000_000)))
            last = now
            att630_run(handle, micros)
            if fd < 0, now.timeIntervalSince(lastConnect) > 1 { lastConnect = now; connect() }
            if fd >= 0 {
                let n = read(fd, &rx, rx.count)
                if n > 0 {
                    rx.withUnsafeBufferPointer { att630_host_rx(handle, $0.baseAddress, n) }
                } else if n == 0 || (n < 0 && errno != EAGAIN) {
                    close(fd); fd = -1; DispatchQueue.main.async { self.link = .disconnected }
                }
            }
            let m = tx.withUnsafeMutableBufferPointer { att630_host_tx(handle, $0.baseAddress, $0.count) }
            if m > 0, fd >= 0 { _ = tx.withUnsafeBufferPointer { write(fd, $0.baseAddress, m) } }
            usleep(2_000)
        }
        if fd >= 0 { close(fd); fd = -1 }
    }

    private func connect() {
        DispatchQueue.main.async { self.link = .connecting }
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(9001).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { close(s); DispatchQueue.main.async { self.link = .disconnected }; return }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        fd = s
        DispatchQueue.main.async { self.link = .connected }
        var cr: UInt8 = 0x0d
        _ = write(fd, &cr, 1)
    }

    func saveBRAM() {
        guard let handle else { return }
        var buf = [UInt8](repeating: 0, count: Int(ATT630_BRAM_BYTES))
        buf.withUnsafeMutableBufferPointer { att630_get_bram(handle, $0.baseAddress) }
        try? FileManager.default.createDirectory(at: MachinePaths.support, withIntermediateDirectories: true)
        try? Data(buf).write(to: bramURL)
    }
}
