import AppKit
import CDMD
import Foundation
import Observation

/// An AT&T / Teletype DMD 5620 (dmd_core, firmware 8;7;5) wired to one of the 3B2's
/// PORTS serial lines. The simulator exposes the lines as raw TCP on 127.0.0.1:9001
/// (`attach ports 127.0.0.1:9001;notelnet`); each connection takes the next free line.
///
/// A background thread runs the 5620's CPU at a fixed rate and shuttles serial bytes
/// to and from the socket. The UI reads the screen with `copyScreen` and feeds the
/// keyboard and mouse through the methods below; every core call is locked inside
/// the Rust wrapper, so this is safe from both threads.
@Observable
final class DMDTerminal: @unchecked Sendable {
    enum Link: Equatable { case disconnected, connecting, connected }

    static let shared = DMDTerminal()

    @MainActor var link: Link = .disconnected
    @MainActor var bell = 0                     // incremented when the terminal rings

    /// Instructions per second. A real WE32100 at 10 MHz manages a few million; the
    /// DUART's character timing is counted in instructions, so this also sets the
    /// effective serial speed.
    var stepsPerSecond: Double = 4_000_000

    private let handle: OpaquePointer
    private var thread: Thread?
    private let stateLock = NSLock()
    private var running = false
    private var fd: Int32 = -1
    private let host = "127.0.0.1"
    private let port: UInt16 = 9001

    private init() {
        guard let h = att_dmd_create() else { fatalError("dmd_core failed to initialise") }
        handle = h
        loadNVRAM()
    }

    // MARK: Lifecycle

    func start() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !running else { return }
        running = true
        let t = Thread { [weak self] in self?.loop() }
        t.name = "DMD 5620"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        stateLock.lock(); running = false; stateLock.unlock()
        saveNVRAM()
    }

    /// Power-cycle the terminal (the 5620's own reset, not the 3B2's).
    func resetTerminal() { att_dmd_reset(handle) }

    // MARK: Input (any thread)

    func key(_ code: UInt8) { att_dmd_rx_keyboard(handle, code) }
    func mouseMove(x: Int, y: Int) {
        att_dmd_mouse_move(handle, UInt16(clamping: max(0, min(799, x))), UInt16(clamping: max(0, min(1023, y))))
    }
    func mouseDown(_ button: UInt8) { att_dmd_mouse_down(handle, button) }
    func mouseUp(_ button: UInt8) { att_dmd_mouse_up(handle, button) }

    /// Copy the 800x1024 1-bit screen; returns true if the display is dark-on-light.
    func copyScreen(into buffer: UnsafeMutablePointer<UInt8>) -> Bool {
        let oport = att_dmd_copy_video(handle, buffer, Int(ATT_DMD_VIDEO_BYTES))
        return oport & 0x02 != 0
    }

    // MARK: Emulation thread

    private func loop() {
        let slice: UInt32 = 5_000
        var budgetStart = Date()
        var stepsThisSecond: Double = 0
        var lastConnectAttempt = Date.distantPast
        var rx = [UInt8](repeating: 0, count: 4096)
        var tx = [UInt8](repeating: 0, count: 512)

        while isRunning {
            // Keep (re)connecting to the 3B2 while it is off or rebooting.
            if fd < 0, Date().timeIntervalSince(lastConnectAttempt) > 1 {
                lastConnectAttempt = Date()
                connect()
            }

            att_dmd_run(handle, slice)
            stepsThisSecond += Double(slice)

            if fd >= 0 {
                let n = read(fd, &rx, rx.count)
                if n > 0 {
                    for i in 0..<n { att_dmd_rx_char(handle, rx[i]) }
                } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                    disconnect()
                }
                let m = tx.withUnsafeMutableBufferPointer { att_dmd_rs232_tx(handle, $0.baseAddress, $0.count) }
                if m > 0, fd >= 0 {
                    var off = 0
                    while off < m {
                        let w = tx[off..<m].withUnsafeBufferPointer { write(fd, $0.baseAddress, m - off) }
                        if w > 0 { off += w } else if errno == EAGAIN { usleep(200) } else { disconnect(); break }
                    }
                }
            } else {
                // Not connected: discard what the terminal transmits.
                _ = tx.withUnsafeMutableBufferPointer { att_dmd_rs232_tx(handle, $0.baseAddress, $0.count) }
            }

            let kb = att_dmd_kb_tx(handle)
            if kb >= 0, kb & 0x08 != 0 {
                DispatchQueue.main.async { self.bell += 1; NSSound.beep() }
            }

            // Pace to stepsPerSecond.
            let elapsed = Date().timeIntervalSince(budgetStart)
            let due = stepsThisSecond / stepsPerSecond
            if due > elapsed { usleep(useconds_t((due - elapsed) * 1_000_000)) }
            if elapsed > 1 { budgetStart = Date(); stepsThisSecond = 0 }
        }
        disconnect()
    }

    private var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    private func setLink(_ l: Link) {
        DispatchQueue.main.async { self.link = l }
    }

    private func connect() {
        setLink(.connecting)
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { close(s); setLink(.disconnected); return }
        var one: Int32 = 1
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        fd = s
        setLink(.connected)
        // Wake the getty so a login prompt appears.
        var cr: UInt8 = 0x0d
        _ = write(fd, &cr, 1)
    }

    private func disconnect() {
        if fd >= 0 { close(fd); fd = -1 }
        setLink(.disconnected)
    }

    // MARK: NVRAM (the 5620's setup options persist across launches)

    private var nvramURL: URL { MachinePaths.support.appendingPathComponent("dmd5620-nvram.bin") }

    private func loadNVRAM() {
        guard let data = try? Data(contentsOf: nvramURL), data.count == Int(ATT_DMD_NVRAM_BYTES) else { return }
        data.withUnsafeBytes { att_dmd_set_nvram(handle, $0.bindMemory(to: UInt8.self).baseAddress) }
    }

    func saveNVRAM() {
        var buf = [UInt8](repeating: 0, count: Int(ATT_DMD_NVRAM_BYTES))
        buf.withUnsafeMutableBufferPointer { att_dmd_get_nvram(handle, $0.baseAddress) }
        try? FileManager.default.createDirectory(at: MachinePaths.support, withIntermediateDirectories: true)
        try? Data(buf).write(to: nvramURL)
    }
}
