import AppKit
import IOKit
import IOKit.ps

// MARK: - CPU

final class CPUMonitor {
    private var previous: [UInt32] = []   // flattened user/system/idle/nice per core

    /// Returns (user, system, total) usage in 0...1
    func sample() -> (user: Double, system: Double, total: Double) {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return (0, 0, 0) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let current = (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
        defer { previous = current }
        guard previous.count == current.count else { return (0, 0, 0) }

        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        for core in 0..<Int(cpuCount) {
            let base = core * Int(CPU_STATE_MAX)
            func d(_ s: Int32) -> UInt64 { UInt64(current[base + Int(s)] &- previous[base + Int(s)]) }
            user += d(CPU_STATE_USER); system += d(CPU_STATE_SYSTEM)
            idle += d(CPU_STATE_IDLE); nice += d(CPU_STATE_NICE)
        }
        let total = Double(user + system + idle + nice)
        guard total > 0 else { return (0, 0, 0) }
        return (Double(user + nice) / total, Double(system) / total, Double(user + system + nice) / total)
    }
}

// MARK: - Memory

struct MemoryInfo { var used: UInt64; var total: UInt64; var compressed: UInt64; var wired: UInt64; var swapUsed: UInt64 }

func sampleMemory() -> MemoryInfo {
    let total = ProcessInfo.processInfo.physicalMemory
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let ok = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
    guard ok == KERN_SUCCESS else { return MemoryInfo(used: 0, total: total, compressed: 0, wired: 0, swapUsed: swap.xsu_used) }

    let page = UInt64(vm_kernel_page_size)
    // Same formula as Activity Monitor's "Memory Used": app + wired + compressed
    let app = UInt64(stats.internal_page_count) - min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))
    let wired = UInt64(stats.wire_count)
    let compressed = UInt64(stats.compressor_page_count)
    return MemoryInfo(used: (app + wired + compressed) * page, total: total,
                      compressed: compressed * page, wired: wired * page, swapUsed: swap.xsu_used)
}

// MARK: - GPU (Apple Silicon / most Macs expose this via IOAccelerator)

func sampleGPU() -> Double? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    var result: Double?
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any],
           let util = stats["Device Utilization %"] as? Int {
            result = max(result ?? 0, Double(util) / 100)
        }
    }
    return result
}

// MARK: - Network

final class NetworkMonitor {
    private var lastIn: UInt64 = 0, lastOut: UInt64 = 0, lastTime: Date?

    /// Bytes per second (down, up)
    func sample() -> (down: Double, up: Double) {
        var totalIn: UInt64 = 0, totalOut: UInt64 = 0
        // NET_RT_IFLIST2 gives 64-bit counters (getifaddrs' if_data wraps at 4 GB)
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.load(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(hdr.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                    let msg = raw.load(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if_indextoname(UInt32(msg.ifm_index), &name)
                    let ifname = String(cString: name)
                    // Skip loopback and virtual tunnels so traffic isn't double counted
                    if !ifname.hasPrefix("lo") && !ifname.hasPrefix("utun") && !ifname.hasPrefix("awdl")
                        && !ifname.hasPrefix("llw") && !ifname.hasPrefix("bridge") {
                        totalIn += msg.ifm_data.ifi_ibytes
                        totalOut += msg.ifm_data.ifi_obytes
                    }
                }
                offset += Int(hdr.ifm_msglen)
                if hdr.ifm_msglen == 0 { break }
            }
        }
        let now = Date()
        defer { lastIn = totalIn; lastOut = totalOut; lastTime = now }
        guard let lastTime, totalIn >= lastIn, totalOut >= lastOut else { return (0, 0) }
        let dt = now.timeIntervalSince(lastTime)
        guard dt > 0 else { return (0, 0) }
        return (Double(totalIn - lastIn) / dt, Double(totalOut - lastOut) / dt)
    }
}

// MARK: - Disk / Battery / System

func sampleDisk() -> (used: Int64, total: Int64)? {
    let url = URL(fileURLWithPath: "/")
    guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
          let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage else { return nil }
    return (Int64(total) - free, Int64(total))
}

struct BatteryInfo { var percent: Int; var charging: Bool; var pluggedIn: Bool; var minutesLeft: Int? }

func sampleBattery() -> BatteryInfo? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for ps in list {
        guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
              d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
        let charging = d[kIOPSIsChargingKey] as? Bool ?? false
        let plugged = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let ttl = (charging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int
        return BatteryInfo(percent: cur * 100 / max, charging: charging, pluggedIn: plugged,
                           minutesLeft: (ttl ?? -1) > 0 ? ttl : nil)
    }
    return nil
}

func loadAverage() -> [Double] {
    var loads = [Double](repeating: 0, count: 3)
    getloadavg(&loads, 3)
    return loads
}

// MARK: - Formatting

func fmtBytes(_ b: Double) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = b, i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? String(format: "%.0f %@", v, units[i]) : String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, units[i])
}
func fmtRate(_ b: Double) -> String { fmtBytes(b) + "/s" }
func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
func fmtUptime(_ t: TimeInterval) -> String {
    let m = Int(t) / 60, h = m / 60, d = h / 24
    return d > 0 ? "\(d) 天 \(h % 24) 小時" : "\(h) 小時 \(m % 60) 分"
}
