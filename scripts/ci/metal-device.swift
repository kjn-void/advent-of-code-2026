// Prints the Metal device the tests will use, as Metal itself sees it. CI runners are VMs whose
// paravirtual GPU does not show up in `system_profiler`, but does work for compute.
// Usage: swift scripts/ci/metal-device.swift
import Metal

if let device = MTLCreateSystemDefaultDevice() {
    let threads = device.maxThreadsPerThreadgroup.width
    let memory = device.recommendedMaxWorkingSetSize / 1_048_576
    print("\(device.name) (unified memory: \(device.hasUnifiedMemory), max threads/threadgroup: \(threads), working set: \(memory) MB)")
} else {
    print("no Metal device")
}
