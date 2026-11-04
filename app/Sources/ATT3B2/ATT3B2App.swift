import AppKit
import SwiftUI

@main
struct ATT3B2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let machine = Machine.shared

    var body: some Scene {
        Window("AT&T 3B2/700 — Console", id: "console") {
            ConsoleWindow(machine: machine)
                .onAppear {
                    machine.prepare()
                    appDelegate.machine = machine
                    DebugCapture.startIfRequested { machine.console }
                    // `-autoPowerOn YES` on the command line powers on at launch (used for testing).
                    if UserDefaults.standard.bool(forKey: "autoPowerOn") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { machine.powerOn() }
                    }
                }
        }
        .defaultSize(width: 900, height: 640)
        .commands {
            CommandMenu("Machine") {
                Button(machine.state.isOn ? "Power Switch (Shut Down)" : "Power On") { machine.pressPowerSwitch() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Reset") { machine.reset() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!machine.state.isOn)
                Divider()
                Button("Pull the Plug") { machine.forceOff() }
                    .disabled(!machine.state.isOn)
            }
        }

        Window("AT&T DMD 5620 Terminal", id: "dmd5620") {
            DMDWindow(terminal: DMDTerminal.shared)
        }
        .defaultSize(width: 660, height: 860)

        Window("AT&T 630 MTG (experimental)", id: "mtg630") {
            Window630(terminal: Terminal630.shared)
        }
        .defaultSize(width: 860, height: 900)

        Settings {
            SettingsView()
        }
    }
}

/// Ask before quitting with the machine running: quitting pulls the plug.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var machine: Machine?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let machine, machine.state.isOn else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "The 3B2 is still running."
        alert.informativeText = "Press the power switch first so UNIX can sync its disks. Quitting now is like pulling the plug."
        alert.addButton(withTitle: "Shut Down, Then Quit")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            machine.pressPowerSwitch()
            Task { @MainActor in
                for _ in 0..<600 where machine.state.isOn { try? await Task.sleep(for: .milliseconds(100)) }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertThirdButtonReturn:
            machine.forceOff()
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

struct ConsoleWindow: View {
    let machine: Machine
    @Environment(\.openWindow) private var openWindow
    @AppStorage("phosphor") private var phosphor: Phosphor = .green
    @AppStorage("fontSize") private var fontSize: Double = 14
    @AppStorage("scanlines") private var scanlines = true
    private var showSnapshotsStore = State<Bool>(initialValue: false)  // @State macro needs Xcode's plugin
    private var showSnapshots: Bool { get { showSnapshotsStore.wrappedValue } nonmutating set { showSnapshotsStore.wrappedValue = newValue } }
    private var showSnapshotsBinding: Binding<Bool> { showSnapshotsStore.projectedValue }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ConsoleView(machine: machine, phosphor: phosphor, fontSize: CGFloat(fontSize))
                    .padding(14)
                    .background(Color(nsColor: phosphor.background))
                if scanlines { Scanlines() }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.black.opacity(0.7), lineWidth: 3))
            .padding(18)
            .background(Color(red: 0.80, green: 0.78, blue: 0.72))   // 3B2 beige bezel

            StatusBar(machine: machine)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    machine.pressPowerSwitch()
                } label: {
                    Label(machine.state.isOn ? "Power Switch" : "Power On", systemImage: "power")
                }
                .help(machine.state.isOn ? "Press the front-panel switch: UNIX syncs and powers off" : "Power on and boot from the hard disk")
                .tint(machine.state.isOn ? .green : .secondary)

                Button { machine.reset() } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                    .disabled(!machine.state.isOn)
                    .help("Reset the CPU and reboot (unsynced data may be lost)")

                Button { showSnapshots = true } label: { Label("Snapshots", systemImage: "externaldrive.badge.timemachine") }
                    .help("Save or restore the hard disk")

                OpenDMDButton()
            }
        }
        .sheet(isPresented: showSnapshotsBinding) { SnapshotSheet(machine: machine) }
        .onAppear {
            // `-openDMD YES` opens the 5620 at launch (used for testing).
            if UserDefaults.standard.bool(forKey: "openDMD") { openWindow(id: "dmd5620") }
            if UserDefaults.standard.bool(forKey: "open630") { openWindow(id: "mtg630") }
        }
        .alert("3B2", isPresented: Binding(get: { machine.lastError != nil }, set: { if !$0 { machine.lastError = nil } })) {
            Button("OK") { machine.lastError = nil }
        } message: {
            Text(machine.lastError ?? "")
        }
    }
}

struct StatusBar: View {
    let machine: Machine

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(machine.state.isOn ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 9, height: 9)
                .shadow(color: machine.state.isOn ? .green : .clear, radius: 3)
            Text(machine.state.rawValue).font(.callout.monospaced())
            Spacer()
            if machine.state == .running {
                Text("telnet 127.0.0.1 2323").font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let since = machine.poweredOnAt {
                Text(since, style: .timer).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct SnapshotSheet: View {
    let machine: Machine
    @Environment(\.dismiss) private var dismiss
    private var labelStore = State<String>(initialValue: "")  // @State macro needs Xcode's plugin
    private var label: String { get { labelStore.wrappedValue } nonmutating set { labelStore.wrappedValue = newValue } }
    private var labelBinding: Binding<String> { labelStore.projectedValue }
    private var confirmRestoreStore = State<Snapshot?>(initialValue: nil)  // @State macro needs Xcode's plugin
    private var confirmRestore: Snapshot? { get { confirmRestoreStore.wrappedValue } nonmutating set { confirmRestoreStore.wrappedValue = newValue } }
    private var confirmRestoreBinding: Binding<Snapshot?> { confirmRestoreStore.projectedValue }
    private var confirmFactoryStore = State<Bool>(initialValue: false)  // @State macro needs Xcode's plugin
    private var confirmFactory: Bool { get { confirmFactoryStore.wrappedValue } nonmutating set { confirmFactoryStore.wrappedValue = newValue } }
    private var confirmFactoryBinding: Binding<Bool> { confirmFactoryStore.projectedValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hard Disk Snapshots").font(.title2.bold())
            if machine.state.isOn {
                Label("Power off the 3B2 to take or restore snapshots.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            HStack {
                TextField("Label (optional)", text: labelBinding)
                Button("Take Snapshot") { machine.takeSnapshot(named: label); label = "" }
                    .disabled(machine.state.isOn)
            }
            List {
                ForEach(machine.snapshots) { snap in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(snap.name).font(.body.monospaced())
                            Text(snap.date, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") { confirmRestore = snap }.disabled(machine.state.isOn)
                        Button(role: .destructive) { machine.deleteSnapshot(snap) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 220)
            HStack {
                Button("Restore Factory Image…") { confirmFactory = true }.disabled(machine.state.isOn)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([MachinePaths.disk]) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 440)
        .confirmationDialog("Replace the hard disk with “\(confirmRestore?.name ?? "")”?",
                            isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } })) {
            Button("Restore", role: .destructive) { if let s = confirmRestore { machine.restore(s) } }
        } message: { Text("Changes since that snapshot are lost unless you snapshot first.") }
        .confirmationDialog("Restore the factory disk image?", isPresented: confirmFactoryBinding) {
            Button("Restore Factory Image", role: .destructive) { machine.restoreFactory() }
        } message: { Text("This replaces the hard disk with the freshly installed SVR3.2.3 system.") }
    }
}

struct SettingsView: View {
    @AppStorage("phosphor") private var phosphor: Phosphor = .green
    @AppStorage("fontSize") private var fontSize: Double = 14
    @AppStorage("scanlines") private var scanlines = true

    var body: some View {
        Form {
            Picker("Phosphor", selection: $phosphor) {
                ForEach(Phosphor.allCases) { Text($0.rawValue).tag($0) }
            }
            Slider(value: $fontSize, in: 10...24, step: 1) { Text("Font size: \(Int(fontSize)) pt") }
            Toggle("Scanlines", isOn: $scanlines)
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Opens the DMD 5620 window (a separate scene, so it needs the openWindow action).
struct OpenDMDButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button { openWindow(id: "dmd5620") } label: { Label("DMD 5620", systemImage: "rectangle.portrait.on.rectangle.portrait") }
            .help("Open the AT&T DMD 5620 bitmapped terminal on a PORTS line")
        Button { openWindow(id: "mtg630") } label: { Label("630 MTG", systemImage: "square.on.square") }
            .help("Open the AT&T 630 MTG terminal (experimental)")
    }
}
