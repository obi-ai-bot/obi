// obi-vm: the box for a teammate's job on this Mac (#797, docs/research/sphere-sharing.md, "Spike
// results"). obid starts it and talks to it over stdin and stdout; it is the only part of Oby with
// the `com.apple.security.virtualization` entitlement.
//
//   obi-vm run --kernel K --initrd I --root R --disk D --cpus 4 --memory-mib 8192 --console LOG \
//              --vsock 7000=/path/control.sock --vsock 7001=/path/model.sock
//     One Linux VM: the root image read-only, the job's disk read-write, no network device, no
//     shared folder. A guest connection to a vsock port is joined to that Unix socket, which obid
//     serves; that is the VM's only link out. stdin takes `pause`, `resume` and `stop`, one per
//     line; stdout says `{"event": "running" | "paused" | "resumed" | "stopped", ...}`.
//   obi-vm signals
//     `{"idleSeconds", "onAC", "lowPower", "thermal"}`: whether the owner is at the Mac.

import Foundation
import IOKit.ps
import Virtualization

setvbuf(stdout, nil, _IOLBF, 0)

func say(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("obi-vm: \(message)\n".utf8))
    exit(2)
}

// MARK: signals

func signals() -> [String: Any] {
    // Any input event: keys, the pointer, the trackpad.
    let anyEvent = CGEventType(rawValue: ~0)!
    let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let source = IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String
    let thermal: String
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: thermal = "nominal"
    case .fair: thermal = "fair"
    case .serious: thermal = "serious"
    case .critical: thermal = "critical"
    @unknown default: thermal = "critical"
    }
    return [
        "idleSeconds": Int(idle), "onAC": source == kIOPMACPowerKey,
        "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled, "thermal": thermal,
    ]
}

// MARK: the VM's own process

/// The pids of Virtualization.framework's VM processes. The guest runs in one of them, not in
/// obi-vm, so its priority is set there.
func vmProcesses() -> Set<pid_t> {
    let count = proc_listallpids(nil, 0)
    var pids = [pid_t](repeating: 0, count: Int(count) * 2)
    let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    var found = Set<pid_t>()
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
        // The path, not the name: a process's name is cut at 32 characters.
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0,
           String(cString: path).hasSuffix("/com.apple.Virtualization.VirtualMachine") { found.insert(pid) }
    }
    return found
}

// MARK: run

struct Options {
    var kernel = "", initrd = "", root = "", disk = "", console = ""
    var cpus = 4, memoryMiB = 8192
    var vsock: [(UInt32, String)] = []
    var cmdline = "console=hvc0 root=/dev/vda ro rootfstype=ext4 init=/sbin/obi-guest quiet"
}

func parse(_ args: ArraySlice<String>) -> Options {
    var o = Options()
    var it = args.makeIterator()
    while let flag = it.next() {
        guard let value = it.next() else { fail("\(flag) needs a value") }
        switch flag {
        case "--kernel": o.kernel = value
        case "--initrd": o.initrd = value
        case "--root": o.root = value
        case "--disk": o.disk = value
        case "--console": o.console = value
        case "--cmdline": o.cmdline = value
        case "--cpus": o.cpus = Int(value) ?? 0
        case "--memory-mib": o.memoryMiB = Int(value) ?? 0
        case "--vsock":
            let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let port = UInt32(parts[0]) else { fail("--vsock is PORT=PATH") }
            o.vsock.append((port, parts[1]))
        default: fail("unknown flag \(flag)")
        }
    }
    for (name, value) in [("--kernel", o.kernel), ("--initrd", o.initrd), ("--root", o.root), ("--disk", o.disk), ("--console", o.console)]
    where value.isEmpty { fail("\(name) is needed") }
    return o
}

/// Copies bytes one way until either side ends, then shuts both down so the other way ends too.
func pump(from: Int32, to: Int32) {
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        let n = read(from, &buffer, buffer.count)
        if n <= 0 { break }
        var off = 0
        while off < n {
            let w = buffer[off..<n].withUnsafeBytes { write(to, $0.baseAddress, n - off) }
            if w <= 0 { shutdown(from, SHUT_RDWR); shutdown(to, SHUT_RDWR); return }
            off += w
        }
    }
    shutdown(from, SHUT_RDWR)
    shutdown(to, SHUT_RDWR)
}

func connectUnix(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = b }
    }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard ok == 0 else { close(fd); return nil }
    return fd
}

/// Joins each guest connection on a port to a new connection to obid's Unix socket for it.
final class Bridge: NSObject, VZVirtioSocketListenerDelegate {
    let path: String
    init(path: String) { self.path = path }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        guard let host = connectUnix(path) else { return false }
        let guest = connection.fileDescriptor
        Thread.detachNewThread {
            let other = Thread { pump(from: host, to: guest) }
            other.start()
            pump(from: guest, to: host)
            // `connection` is kept alive by this closure until both ways are done.
            while !other.isFinished { usleep(10_000) }
            close(host)
            connection.close()
        }
        return true
    }
}

final class Runner: NSObject, VZVirtualMachineDelegate {
    let vm: VZVirtualMachine
    var bridges: [Bridge] = []
    /// The VM process this VM runs in: the one that appeared when it started (obid starts one VM at
    /// a time). nil when that wasn't one process.
    var process: pid_t?

    init(_ o: Options) throws {
        let config = VZVirtualMachineConfiguration()
        let boot = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: o.kernel))
        boot.initialRamdiskURL = URL(fileURLWithPath: o.initrd)
        boot.commandLine = o.cmdline
        config.bootLoader = boot
        config.cpuCount = o.cpus
        config.memorySize = UInt64(o.memoryMiB) * 1024 * 1024
        config.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(
                url: URL(fileURLWithPath: o.root), readOnly: true)),
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(
                url: URL(fileURLWithPath: o.disk), readOnly: false)),
        ]
        // The guest's console goes to a file obid keeps with the job; it is the guest's text, data.
        FileManager.default.createFile(atPath: o.console, contents: nil)
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: ProcessInfo.processInfo.environment["OBI_VM_DEBUG_CONSOLE_IN"].flatMap { FileHandle(forReadingAtPath: $0) },
            fileHandleForWriting: FileHandle(forWritingAtPath: o.console))
        config.serialPorts = [console]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        // No network device and no shared folder: deliberately left empty.
        config.networkDevices = []
        config.directorySharingDevices = []
        try config.validate()
        vm = VZVirtualMachine(configuration: config)
        super.init()
        vm.delegate = self
        let device = vm.socketDevices[0] as! VZVirtioSocketDevice
        for (port, path) in o.vsock {
            let bridge = Bridge(path: path)
            let listener = VZVirtioSocketListener()
            listener.delegate = bridge
            device.setSocketListener(listener, forPort: port)
            bridges.append(bridge)
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        say(["event": "stopped", "reason": "guest"])
        exit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        say(["event": "stopped", "reason": "error", "error": error.localizedDescription])
        exit(1)
    }

    func command(_ line: String) {
        switch line {
        case "pause" where vm.canPause:
            vm.pause { r in say(["event": (try? r.get()) != nil ? "paused" : "error", "command": "pause"]) }
        case "resume" where vm.canResume:
            vm.resume { r in say(["event": (try? r.get()) != nil ? "resumed" : "error", "command": "resume"]) }
        case "background", "foreground":
            // Background: the efficiency cores only, throttled I/O, yielding to everything the owner runs.
            guard let pid = process,
                  setpriority(PRIO_DARWIN_PROCESS, id_t(pid), line == "background" ? PRIO_DARWIN_BG : 0) == 0
            else { say(["event": "error", "command": line]); return }
            say(["event": line])
        case "stop":
            vm.stop { _ in say(["event": "stopped", "reason": "stop"]); exit(0) }
        default:
            say(["event": "error", "command": line])
        }
    }
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "signals":
    say(signals())
case "run":
    // The owner always comes first: lowest CPU priority, throttled I/O.
    setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)
    // The VM process starts with the VZVirtualMachine, so the ones before it are looked at first.
    let before = vmProcesses()
    let runner: Runner
    do { runner = try Runner(parse(args.dropFirst(2))) } catch { fail("\(error)") }
    runner.vm.start { result in
        switch result {
        case .success:
            let new = vmProcesses().subtracting(before)
            runner.process = new.count == 1 ? new.first : nil
            say(["event": "running"])
        case .failure(let error): say(["event": "stopped", "reason": "error", "error": error.localizedDescription]); exit(1)
        }
    }
    Thread.detachNewThread {
        while let line = readLine() {
            let command = line.trimmingCharacters(in: .whitespaces)
            DispatchQueue.main.async { runner.command(command) }
        }
        // obid went away: nothing may run without it.
        DispatchQueue.main.async { runner.command("stop") }
    }
    dispatchMain()
default:
    fail("usage: obi-vm run … | obi-vm signals")
}
