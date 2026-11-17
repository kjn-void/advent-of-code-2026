import AoCKit
import Foundation
import Metal

extension GPU {
    /// Compute pipeline for a kernel defined in `Sources/Solutions/Shaders/*.metal`.
    func kernel(_ name: String) throws -> any MTLComputePipelineState {
        try pipeline(name, in: library(named: "Solutions", in: .module))
    }
}
