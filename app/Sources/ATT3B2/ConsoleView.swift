import AppKit
import SwiftTerm
import SwiftUI

/// Phosphor colours for the CRT look.
enum Phosphor: String, CaseIterable, Identifiable {
    case green = "P1 Green"
    case amber = "P3 Amber"
    case white = "P4 White"
    var id: String { rawValue }

    var foreground: NSColor {
        switch self {
        case .green: return NSColor(calibratedRed: 0.35, green: 1.0, blue: 0.45, alpha: 1)
        case .amber: return NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.20, alpha: 1)
        case .white: return NSColor(calibratedRed: 0.86, green: 0.90, blue: 0.95, alpha: 1)
        }
    }
    var background: NSColor {
        switch self {
        case .green: return NSColor(calibratedRed: 0.02, green: 0.06, blue: 0.03, alpha: 1)
        case .amber: return NSColor(calibratedRed: 0.07, green: 0.04, blue: 0.01, alpha: 1)
        case .white: return NSColor(calibratedRed: 0.04, green: 0.045, blue: 0.06, alpha: 1)
        }
    }
}

/// A terminal attached to the simulator's console. SIMH runs on a pseudo-terminal we
/// own (so its console sees a real tty); its output feeds this view and the Machine,
/// which watches it to track power state.
final class ConsoleTerminalView: TerminalView, TerminalViewDelegate, LocalProcessDelegate {
    weak var machine: Machine?
    private var process: LocalProcess?

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func startSimulator(executable: String, args: [String], directory: String) {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "vt100"
        let p = LocalProcess(delegate: self, dispatchQueue: .main)
        process = p
        p.startProcess(executable: executable, args: args,
                       environment: env.map { "\($0.key)=\($0.value)" },
                       currentDirectory: directory)
    }

    func terminateSimulator() { process?.terminate() }

    var isRunning: Bool { process?.running ?? false }

    func sendBytes(_ bytes: [UInt8]) {
        guard let process, process.running else { return }
        process.send(data: bytes[...])
    }

    // MARK: LocalProcessDelegate (delivered on the main queue)

    func dataReceived(slice: ArraySlice<UInt8>) {
        feed(byteArray: slice)
        let copy = Array(slice)
        MainActor.assumeIsolated { machine?.consoleOutput(copy[...]) }
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        MainActor.assumeIsolated {
            feed(text: "\r\n\u{1b}[2m[ power off ]\u{1b}[0m\r\n")
            machine?.simulatorExited(code: exitCode)
        }
    }

    func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        MainActor.assumeIsolated {
            feed(text: "\r\nSimulator failed to start: \(error)\r\n")
            machine?.simulatorExited(code: -1)
        }
    }

    func getWindowSize() -> winsize {
        let d = terminalDimensions
        return winsize(ws_row: UInt16(d.rows), ws_col: UInt16(d.cols), ws_xpixel: 0, ws_ypixel: 0)
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let process, process.running else { return }
        process.send(data: data)
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func apply(phosphor: Phosphor, fontSize: CGFloat) {
        nativeForegroundColor = phosphor.foreground
        nativeBackgroundColor = phosphor.background
        caretColor = phosphor.foreground.withAlphaComponent(0.8)
        font = NSFont(name: "Menlo", size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // A soft bloom around the glyphs reads as phosphor glow.
        wantsLayer = true
        layer?.shadowColor = phosphor.foreground.cgColor
        layer?.shadowRadius = 3.5
        layer?.shadowOpacity = 0.55
        layer?.shadowOffset = .zero
    }
}

struct ConsoleView: NSViewRepresentable {
    let machine: Machine
    var phosphor: Phosphor
    var fontSize: CGFloat

    func makeNSView(context: Context) -> ConsoleTerminalView {
        let view = ConsoleTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.machine = machine
        machine.console = view
        view.apply(phosphor: phosphor, fontSize: fontSize)
        return view
    }

    func updateNSView(_ view: ConsoleTerminalView, context: Context) {
        view.apply(phosphor: phosphor, fontSize: fontSize)
    }
}

/// Faint horizontal scanlines over the screen.
struct Scanlines: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.22)))
                y += 3
            }
        }
        .allowsHitTesting(false)
    }
}
