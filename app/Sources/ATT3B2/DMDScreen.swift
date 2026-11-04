import AppKit
import CDMD
import SwiftUI

/// Draws the 5620's 800x1024 bitmap and turns Mac keyboard/mouse input into 5620 codes.
final class DMDScreenView: NSView {
    let terminal: DMDTerminal
    var phosphor: Phosphor = .green { didSet { needsDisplay = true } }

    private var vram = [UInt8](repeating: 0, count: Int(ATT_DMD_VIDEO_BYTES))
    private var darkOnLight = false
    private var timer: Timer?
    private let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
    private let scaler = PixelScaler()

    init(terminal: DMDTerminal) {
        self.terminal = terminal
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 1024))
        wantsLayer = true
        layer?.magnificationFilter = .nearest
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        guard window != nil else { return }
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        var previous = vram
        let dol = vram.withUnsafeMutableBufferPointer { terminal.copyScreen(into: $0.baseAddress!) }
        if dol != darkOnLight || previous != vram {
            darkOnLight = dol
            needsDisplay = true
        }
        previous.removeAll()
    }

    /// The area the 800x1024 screen occupies, scaled to fit and centred.
    private var screenRect: NSRect {
        let scale = min(bounds.width / 800, bounds.height / 1024)
        let w = 800 * scale, h = 1024 * scale
        return backingAlignedRect(NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h),
                                  options: .alignAllEdgesNearest)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let bg = phosphor.background, fg = phosphor.foreground
        bg.setFill()
        bounds.fill()

        // 1-bit indexed image straight from video RAM: bit set = lit (or dark when
        // the terminal is in dark-on-light mode).
        let (c0, c1) = darkOnLight ? (fg, bg) : (bg, fg)
        func rgb(_ c: NSColor) -> [UInt8] {
            let s = c.usingColorSpace(.deviceRGB) ?? c
            return [UInt8(s.redComponent * 255), UInt8(s.greenComponent * 255), UInt8(s.blueComponent * 255)]
        }
        let table = rgb(c0) + rgb(c1)
        guard let space = CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(), last: 1, colorTable: table),
              let provider = CGDataProvider(data: Data(vram) as CFData),
              let image = CGImage(width: 800, height: 1024, bitsPerComponent: 1, bitsPerPixel: 1,
                                  bytesPerRow: 100, space: space, bitmapInfo: [], provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        let scale = window?.backingScaleFactor ?? 2
        scaler.draw(image, in: screenRect, ctx: ctx, backingScale: scale)
        PixelScaler.scanlines(rows: 1024, in: screenRect, ctx: ctx, backingScale: scale)
    }

    // MARK: Mouse (5620 coordinates: x 0..799, y 0..1023 from the bottom)

    private func send(mouse event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let r = screenRect
        terminal.mouseMove(x: Int((p.x - r.minX) / r.width * 800), y: Int((p.y - r.minY) / r.height * 1024))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    // The 5620 draws its own cursor.
    override func cursorUpdate(with event: NSEvent) { blankCursor.set() }
    override func mouseMoved(with event: NSEvent) { send(mouse: event) }
    override func mouseDragged(with event: NSEvent) { send(mouse: event) }
    override func rightMouseDragged(with event: NSEvent) { send(mouse: event) }
    override func otherMouseDragged(with event: NSEvent) { send(mouse: event) }

    /// Button 1 = left. Middle = option-click or a real middle button. Right = right-click
    /// or control-click (the 5620's menus live on buttons 2 and 3).
    private func button(for event: NSEvent) -> UInt8 {
        switch event.type {
        case .rightMouseDown, .rightMouseUp: return 2
        case .otherMouseDown, .otherMouseUp: return 1
        default:
            if event.modifierFlags.contains(.option) { return 1 }
            if event.modifierFlags.contains(.control) { return 2 }
            return 0
        }
    }
    private var heldButton: UInt8 = 0
    override func mouseDown(with event: NSEvent) { send(mouse: event); heldButton = button(for: event); terminal.mouseDown(heldButton) }
    override func mouseUp(with event: NSEvent) { send(mouse: event); terminal.mouseUp(heldButton) }
    override func rightMouseDown(with event: NSEvent) { send(mouse: event); terminal.mouseDown(2) }
    override func rightMouseUp(with event: NSEvent) { send(mouse: event); terminal.mouseUp(2) }
    override func otherMouseDown(with event: NSEvent) { send(mouse: event); terminal.mouseDown(1) }
    override func otherMouseUp(with event: NSEvent) { send(mouse: event); terminal.mouseUp(1) }

    // MARK: Keyboard (codes from dmd_gtk's mapping of the 5620 keyboard)

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        if let code = Self.code(for: event) { terminal.key(code) }
    }

    static func code(for event: NSEvent) -> UInt8? {
        let shift = event.modifierFlags.contains(.shift)
        let ctrl = event.modifierFlags.contains(.control)
        switch Int(event.keyCode) {
        case 122: return 0xe8                     // F1 .. F8: the 5620 function keys
        case 120: return 0xe9
        case 99: return 0xea
        case 118: return 0xeb
        case 96: return 0xec
        case 97: return 0xed
        case 98: return 0xee
        case 100: return 0xef
        case 101: return shift ? 0x8e : 0xae      // F9: SETUP
        case 53: return 0x1b                      // Escape
        case 117: return 0xfe                     // Forward delete
        case 125: return 0x90                     // Down
        case 126: return 0x92                     // Up
        case 124: return 0xc3                     // Right
        case 123: return 0xc4                     // Left
        case 51: return 0x08                      // Backspace sends BS
        case 36, 76: return 0x0d                  // Return, Enter
        case 48: return 0x09                      // Tab
        default: break
        }
        guard let chars = event.charactersIgnoringModifiers, let scalar = chars.unicodeScalars.first,
              scalar.isASCII else { return nil }
        let v = UInt8(scalar.value)
        if ctrl {
            switch v {
            case 0x61...0x7a: return v - 0x60     // ^a .. ^z
            case 0x40...0x5f: return v - 0x40     // ^@ ^[ ^\ ^] ^^ ^_
            default: return nil
            }
        }
        return v
    }
}

struct DMDScreen: NSViewRepresentable {
    let terminal: DMDTerminal
    var phosphor: Phosphor

    func makeNSView(context: Context) -> DMDScreenView {
        let v = DMDScreenView(terminal: terminal)
        v.phosphor = phosphor
        return v
    }

    func updateNSView(_ view: DMDScreenView, context: Context) { view.phosphor = phosphor }
}

struct DMDWindow: View {
    let terminal: DMDTerminal
    @AppStorage("dmdPhosphor") private var phosphor: Phosphor = .white

    var body: some View {
        VStack(spacing: 0) {
            DMDScreen(terminal: terminal, phosphor: phosphor)
                .aspectRatio(800.0 / 1024.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.80, green: 0.78, blue: 0.72))
            HStack(spacing: 12) {
                Circle().fill(linkColor).frame(width: 9, height: 9)
                Text(linkText).font(.callout.monospaced())
                Spacer()
                Text("F9 Setup · ⌥-click middle · ⌃-click right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(.bar)
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Phosphor", selection: $phosphor) {
                    ForEach(Phosphor.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                Button { terminal.resetTerminal() } label: { Label("Reset Terminal", systemImage: "arrow.counterclockwise") }
                    .help("Reset the 5620 (its own power cycle)")
            }
        }
        .onAppear { terminal.start() }
        .onDisappear { terminal.stop() }
    }

    private var linkText: String {
        switch terminal.link {
        case .connected: return "Connected to 3B2 PORTS line (127.0.0.1:9001)"
        case .connecting: return "Connecting to the 3B2…"
        case .disconnected: return "Waiting for the 3B2 (power it on)"
        }
    }
    private var linkColor: Color {
        switch terminal.link {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .gray
        }
    }
}
