import Foundation

public enum Memory {
    /// (physical footprint, resident size) in MB. The footprint leaves out Neural Engine weights; resident size is closer to what Activity Monitor shows.
    public static func megabytes() -> (footprint: Double, resident: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (-1, -1) }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.resident_size) / 1_048_576)
    }
}
