import Foundation
import Darwin
import UIKit
import os

/// Public process-memory APIs, not total device RAM: extension budgets are
/// substantially smaller than those of the containing app.
@MainActor
enum ProcessingMemory {
    static var isExtension: Bool { Bundle.main.bundleURL.pathExtension == "appex" }
    private static var lastWarning: Date?

    struct Snapshot {
        let footprint: UInt64?
        let available: UInt64
    }

    static func snapshot() -> Snapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return Snapshot(footprint: status == KERN_SUCCESS ? info.phys_footprint : nil,
                        available: UInt64(os_proc_available_memory()))
    }

    static var isConstrained: Bool {
        ocrPolicy.constrained
    }

    static var ocrPolicy: OCRResourcePolicy {
        let memory = snapshot()
        return OCRResourcePolicy(memoryLimited: isExtension,
            recentWarning: lastWarning.map { Date().timeIntervalSince($0) < 120 } ?? false,
            availableBytes: memory.available, footprintBytes: memory.footprint ?? 0)
    }

    static func receivedWarning() { lastWarning = Date() }
}
