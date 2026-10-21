import AppKit
import Darwin
import Foundation
import IOKit.ps
import SystemConfiguration

/// Lecture de l'état du Mac. Appelée hors du fil principal.
final class StatusReader {
    private var previousTicks: [UInt32]?

    func read() -> MacStatus {
        let memory = Self.memory()
        let disk = Self.disk()
        let volume = Actions.volume()
        return MacStatus(
            name: Self.computerName(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            model: Self.sysctlString("hw.model"),
            uptime: Self.uptime(),
            cpu: cpuUsage(),
            memoryUsed: memory?.used,
            memoryTotal: memory?.total,
            diskAvailable: disk?.available,
            diskTotal: disk?.total,
            battery: Self.battery(),
            thermal: Self.thermal(),
            frontApp: DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.localizedName },
            volume: volume.level,
            muted: volume.muted,
            permissions: Self.permissions()
        )
    }

    static func permissions() -> Permissions {
        Permissions(input: Input.hasAccess, screen: CGPreflightScreenCaptureAccess())
    }

    static func computerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String? {
            return name
        }
        return ProcessInfo.processInfo.hostName
    }

    /// Charge depuis l'appel précédent (depuis le démarrage au premier appel).
    private func cpuUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        // Ordre : utilisateur, système, inactif, nice.
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        let base = previousTicks ?? [0, 0, 0, 0]
        previousTicks = ticks
        let delta = zip(ticks, base).map { Double($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return nil }
        return (delta[0] + delta[1] + delta[3]) / total
    }

    /// Mémoire utilisée au sens du Moniteur d'activité : mémoire des apps
    /// + mémoire résidente + mémoire compressée.
    private static func memory() -> (used: Int64, total: Int64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        let page = Int64(pageSize)
        let app = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let used = (app + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
        return (used, Int64(ProcessInfo.processInfo.physicalMemory))
    }

    private static func disk() -> (available: Int64, total: Int64)? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return (available, Int64(total))
    }

    /// `nil` sur un Mac sans batterie (Mac mini, iMac, Mac Studio).
    private static func battery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                    .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            let minutes = description[kIOPSTimeToEmptyKey] as? Int
            return Battery(
                level: current * 100 / maximum,
                charging: description[kIOPSIsChargingKey] as? Bool ?? false,
                onAC: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                minutesLeft: (minutes ?? -1) > 0 ? minutes : nil
            )
        }
        return nil
    }

    private static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "nominal"
        }
    }

    /// Temps écoulé depuis le démarrage, veilles comprises.
    private static func uptime() -> Double? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
