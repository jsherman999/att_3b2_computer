import Darwin
import Foundation

/// Runs the 630's windowing host: Dave Dykstra's pseudo-tty `layers` (built for macOS
/// by scripts/build-630host.sh into Resources/630host), on a pty whose master is the
/// 630's Main EIA line. Each 630 window's program is `$SHELL -c ...` with SHELL =
/// 3b2line, so a new window is a new 3B2 PORTS line; the startup file also opens a
/// local "630 tools" window for dmdld and friends.
enum Layers630 {
    static var bundled: URL { MachinePaths.resources.appendingPathComponent("630host", isDirectory: true) }
    /// $DMD: links into the bundle plus the writable xt directory layers needs.
    static var dmd: URL { MachinePaths.support.appendingPathComponent("630host", isDirectory: true) }

    static var available: Bool {
        FileManager.default.isExecutableFile(atPath: bundled.appendingPathComponent("bin/layers").path)
    }

    /// Lay out $DMD. The links are rewritten every time in case the app moved.
    private static func prepareDMD() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dmd, withIntermediateDirectories: true)
        for name in ["bin", "lib", "include"] {
            let link = dmd.appendingPathComponent(name)
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: bundled.appendingPathComponent(name))
        }
        let xt = dmd.appendingPathComponent("xt")
        try fm.createDirectory(at: xt, withIntermediateDirectories: true)
        chmod(xt.path, 0o777)
    }

    /// Start layers. Returns the pty master (non-blocking) and the process id.
    static func spawn() -> (fd: Int32, pid: pid_t)? {
        guard available, (try? prepareDMD()) != nil else { return nil }
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { return nil }
        guard let name = ttyname(slave).map({ String(cString: $0) }) else {
            close(master); close(slave); return nil
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // A new session opening its tty without O_NOCTTY makes it the controlling tty, so
        // layers and its windows get SIGHUP when the 630 window (the master) goes away.
        posix_spawn_file_actions_addopen(&actions, 0, name, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addclose(&actions, master)
        posix_spawn_file_actions_addclose(&actions, slave)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let d = dmd.path
        var env = [
            "DMD=\(d)", "DMDSYS=\(d)",
            "SHELL=\(d)/bin/3b2line",
            "PATH=\(d)/bin:/usr/bin:/bin",
            "HOME=\(NSHomeDirectory())",
            "TERM=630",
            "USER=\(NSUserName())", "LOGNAME=\(NSUserName())",
        ]
        // 3b2line dials 127.0.0.1:9001 unless told otherwise (tests use spare ports).
        if let ports = ProcessInfo.processInfo.environment["ATT3B2_PORTS"] { env.append("ATT3B2_PORTS=\(ports)") }
        let args = ["layers", "-f", "\(d)/lib/layersrc"]
        let cArgs = args.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup($0) } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "\(d)/bin/layers", &actions, &attr, cArgs, cEnv)
        close(slave)
        guard rc == 0 else { close(master); return nil }
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        return (master, pid)
    }

    /// Hang up layers (and through it, every window's program) and reap it.
    static func stop(fd: Int32, pid: pid_t) {
        if fd >= 0 { close(fd) }
        guard pid > 0 else { return }
        kill(pid, SIGHUP)
        var status: Int32 = 0
        for _ in 0..<20 {
            if waitpid(pid, &status, WNOHANG) != 0 { return }
            usleep(50_000)
        }
        kill(pid, SIGKILL)
        waitpid(pid, &status, 0)
    }
}
