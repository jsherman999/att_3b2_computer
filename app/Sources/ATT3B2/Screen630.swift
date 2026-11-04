import AppKit
import CDMD
import SwiftUI

/// The 630's 1024x1024 screen; mouse motion goes to the terminal as deltas.
final class Screen630View: NSView {
    let terminal: Terminal630
    var phosphor: Phosphor = .amber { didSet { needsDisplay = true } }
    private var vram = [UInt8](repeating: 0, count: Int(ATT630_VIDEO_BYTES))
    private var timer: Timer?
    private let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
    private let scaler = PixelScaler()

    init(terminal: Terminal630) {
        self.terminal = terminal
        super.init(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        guard window != nil else { return }
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let before = self.vram
                self.vram.withUnsafeMutableBufferPointer { self.terminal.copyScreen(into: $0.baseAddress!) }
                if before != self.vram { self.needsDisplay = true }
            }
        }
    }

    private var screenRect: NSRect {
        let side = min(bounds.width, bounds.height)
        return backingAlignedRect(NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side),
                                  options: .alignAllEdgesNearest)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.black.setFill()
        bounds.fill()
        func rgb(_ c: NSColor) -> [UInt8] {
            let s = c.usingColorSpace(.deviceRGB) ?? c
            return [UInt8(s.redComponent * 255), UInt8(s.greenComponent * 255), UInt8(s.blueComponent * 255)]
        }
        // A set bit is ink; clear bits glow.
        let table = rgb(phosphor.foreground) + rgb(phosphor.background)
        guard let space = CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(), last: 1, colorTable: table),
              let provider = CGDataProvider(data: Data(vram) as CFData),
              let image = CGImage(width: 1024, height: 1024, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: 128,
                                  space: space, bitmapInfo: [], provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        scaler.draw(image, in: screenRect, ctx: ctx, backingScale: window?.backingScaleFactor ?? 2)
    }

    // Mouse: deltas in 630 pixels.
    private func moved(_ e: NSEvent) {
        let scale = 1024 / screenRect.width
        terminal.mouseMoved(dx: Int((e.deltaX * scale).rounded()), dy: Int((-e.deltaY * scale).rounded()))
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }
    override func cursorUpdate(with event: NSEvent) { blankCursor.set() }
    override func mouseMoved(with e: NSEvent) { moved(e) }
    override func mouseDragged(with e: NSEvent) { moved(e) }
    override func rightMouseDragged(with e: NSEvent) { moved(e) }
    override func otherMouseDragged(with e: NSEvent) { moved(e) }
    private var held = 0
    override func mouseDown(with e: NSEvent) {
        held = e.modifierFlags.contains(.option) ? 1 : e.modifierFlags.contains(.control) ? 2 : 0
        terminal.button(held, down: true)
    }
    override func mouseUp(with e: NSEvent) { terminal.button(held, down: false) }
    override func rightMouseDown(with e: NSEvent) { terminal.button(2, down: true) }
    override func rightMouseUp(with e: NSEvent) { terminal.button(2, down: false) }
    override func otherMouseDown(with e: NSEvent) { terminal.button(1, down: true) }
    override func otherMouseUp(with e: NSEvent) { terminal.button(1, down: false) }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        terminal.type(event)
    }
}

struct Screen630: NSViewRepresentable {
    let terminal: Terminal630
    var phosphor: Phosphor
    func makeNSView(context: Context) -> Screen630View {
        let v = Screen630View(terminal: terminal)
        v.phosphor = phosphor
        return v
    }
    func updateNSView(_ view: Screen630View, context: Context) { view.phosphor = phosphor }
}

struct Window630: View {
    let terminal: Terminal630
    @AppStorage("phosphor630") private var phosphor: Phosphor = .amber

    var body: some View {
        VStack(spacing: 0) {
            Screen630(terminal: terminal, phosphor: phosphor)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.80, green: 0.78, blue: 0.72))
            HStack(spacing: 12) {
                Circle().fill(terminal.link == .connected ? Color.green : Color.gray).frame(width: 9, height: 9)
                Text(status).font(.callout.monospaced())
                Spacer()
                Text("Experimental: host output works, keyboard input does not yet")
                    .font(.caption).foregroundStyle(.orange)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(.bar)
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Phosphor", selection: $phosphor) { ForEach(Phosphor.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.menu)
                Button { terminal.resetTerminal() } label: { Label("Reset Terminal", systemImage: "arrow.counterclockwise") }
            }
        }
        .onAppear { terminal.start() }
        .onDisappear { terminal.stop() }
    }

    private var status: String {
        switch terminal.link {
        case .connected: return "630 Main EIA connected to a 3B2 PORTS line"
        case .connecting: return "Connecting to the 3B2…"
        case .disconnected: return "Waiting for the 3B2"
        case .noROMs: return "630 firmware ROMs not found in the app bundle"
        }
    }
}
