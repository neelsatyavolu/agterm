import Foundation

/// This process's physical footprint, as Activity Monitor shows it (resident memory on Linux).
func processFootprint() -> Int {
    #if os(Linux)
    guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8),
          let line = status.split(separator: "\n").first(where: { $0.hasPrefix("VmRSS:") }),
          let kilobytes = line.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { return 0 }
    return kilobytes * 1024
    #else
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    #endif
}

/// `SOCK_STREAM` as `socketpair` takes it (an enum on Linux).
#if os(Linux)
let streamSocket = Int32(SOCK_STREAM.rawValue)
#else
let streamSocket = SOCK_STREAM
#endif
