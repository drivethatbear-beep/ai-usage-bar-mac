import Darwin
import Foundation
import IOKit

/// 이 Mac의 현재 상태(CPU · GPU · 메모리 · 열). 모두 관리자 권한 없이 읽는 공개 API 값이다.
struct SystemStats {
    var chip: String
    var cpu: Double?             // 전체 코어 평균 사용률 0–100 (첫 샘플은 기준점이라 nil)
    var gpu: Double?             // GPU 사용률 0–100
    var gpuMemory: UInt64?       // GPU가 쓰는 통합 메모리(바이트)
    var memUsed: UInt64          // 활성 상태 보기의 '사용된 메모리'(앱 + 와이어드 + 압축)
    var memTotal: UInt64
    var swapUsed: UInt64
    var pressure: Int32          // 1 정상 · 2 경고 · 4 위험
    var thermal: ProcessInfo.ThermalState

    var memPercent: Double { memTotal > 0 ? min(100, Double(memUsed) / Double(memTotal) * 100) : 0 }

    /// macOS는 메모리를 70~80%까지 채워 두는 게 정상이라, 색은 사용률이 아니라 메모리 압박으로 정한다.
    /// loadColor에 넘기는 값: 위험 → 100(빨강), 경고 → 80(주황), 정상 → 0
    var memAlertLevel: Double { pressure >= 4 ? 100 : pressure >= 2 ? 80 : 0 }

    var pressureLabel: String {
        switch pressure {
        case 4: return "위험"
        case 2: return "경고"
        default: return "정상"
        }
    }

    var thermalLabel: String {
        switch thermal {
        case .nominal: return "정상"
        case .fair: return "약간 높음"
        case .serious: return "높음"
        case .critical: return "매우 높음"
        @unknown default: return "알 수 없음"
        }
    }

    static func gb(_ bytes: UInt64) -> String {
        (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(1)))
    }
}

/// 몇 초마다 호출해 SystemStats를 만든다. CPU 사용률은 직전 호출과의 차이로 계산한다.
final class SystemMonitor {
    private let host = mach_host_self()
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private let chip: String = SystemMonitor.sysctlString("machdep.cpu.brand_string") ?? "Mac"

    func sample() -> SystemStats {
        let mem = memory(), g = gpu()
        return SystemStats(chip: chip, cpu: cpuPercent(), gpu: g.util, gpuMemory: g.memory,
                           memUsed: mem, memTotal: ProcessInfo.processInfo.physicalMemory,
                           swapUsed: swapUsed(), pressure: Self.sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1,
                           thermal: ProcessInfo.processInfo.thermalState)
    }

    // MARK: CPU

    private func cpuPercent() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks   // (user, system, idle, nice)
        let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
        let total = busy + UInt64(t.2)
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total, busy >= last.busy else { return nil }
        return min(100, Double(busy - last.busy) / Double(total - last.total) * 100)
    }

    // MARK: 메모리

    private func memory() -> UInt64 {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let anon = UInt64(vm.internal_page_count), purgeable = UInt64(vm.purgeable_count)
        let app = anon > purgeable ? anon - purgeable : 0
        return (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
    }

    private func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    // MARK: GPU (IOAccelerator의 PerformanceStatistics)

    private func gpu() -> (util: Double?, memory: UInt64?) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else {
            return (nil, nil)
        }
        defer { IOObjectRelease(iter) }
        var util: Double?, memory: UInt64?
        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            if let u = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? NSNumber {
                util = max(util ?? 0, u.doubleValue)
            }
            if let m = stats["In use system memory"] as? NSNumber { memory = (memory ?? 0) + m.uint64Value }
        }
        return (util.map { min(100, $0) }, memory)
    }

    // MARK: sysctl

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : nil
    }
}
