import Foundation
import RealityKit
import simd

/// Drives the authored facial surface, including the inset mouth, without
/// swapping a closed face over an open one. The app's pose spring owns timing.
@MainActor
final class PsiloExpressionRig {
    private var channels: [any PsiloMorphBinding] = []
    let usesInsetMouth: Bool
    private(set) var hasCompleteSmile = false
    private(set) var nativeChannelCount = 0
    private(set) var fallbackChannelCount = 0

    /// `forceMeshFallback` exercises the macOS 14 path on the development Mac.
    init(root: Entity, forceMeshFallback: Bool = false, debugLogging: Bool = false) {
        usesInsetMouth = root.findEntity(named: "MouthInterior") != nil
        let required = [("Cap", "SmileClose"), ("MouthInterior", "SmileClose"),
                        ("EyeDot_L", "Happy"), ("EyeDot_R", "Happy")]
        for (name, shape) in required {
            guard let group = root.findEntity(named: name),
                  let source = Self.firstModel(in: group) else { continue }
            var binding: (any PsiloMorphBinding)?
            if #available(macOS 15, *), !forceMeshFallback {
                binding = PsiloNativeMorphBinding(entity: source, shape: shape, debugLogging: debugLogging)
                if binding != nil { nativeChannelCount += 1 }
            }
            if binding == nil,
               let targetGroup = root.findEntity(named: "MorphTarget_\(name)_\(shape)"),
               let target = Self.firstModel(in: targetGroup) {
                binding = PsiloMeshMorphBinding(source: source, target: target, debugLogging: debugLogging)
                if binding != nil { fallbackChannelCount += 1 }
            }
            if let binding { channels.append(binding) }
        }
        hasCompleteSmile = channels.count == required.count
        // These are data for older systems, never characters or drawn geometry.
        // Remove before the model joins the scene; the fallback caches its data.
        if let targets = root.findEntity(named: "PsiloMorphTargets") {
            targets.isEnabled = false
            targets.removeFromParent()
        }
        if usesInsetMouth && !hasCompleteSmile {
            NSLog("NeaTree: Psilo facial morph data is incomplete; keeping its neutral face.")
        }
        if debugLogging {
            NSLog("Psilo expression rig: native=%ld, mesh fallback=%ld, inset=%d, complete=%d",
                  nativeChannelCount, fallbackChannelCount, usesInsetMouth ? 1 : 0, hasCompleteSmile ? 1 : 0)
        }
    }

    func update(pride: Float, deltaTime: Float) {
        // Do not close only one part of a new face if a malformed asset is loaded.
        let amount = hasCompleteSmile ? Self.clampWeight(pride) : 0
        for channel in channels { channel.setWeight(amount, deltaTime: deltaTime) }
    }

    static func smileVisibility(pride: Float) -> Float {
        let t = min(1, max(0, (pride - 0.82) / (0.995 - 0.82)))
        return t * t * (3 - 2 * t)
    }

    private static func clampWeight(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        if value < 0.0005 { return 0 }
        if value > 0.9995 { return 1 }
        return min(1, max(0, value))
    }

    private static func firstModel(in root: Entity) -> Entity? {
        if root.components[ModelComponent.self] != nil { return root }
        for child in root.children {
            if let model = firstModel(in: child) { return model }
        }
        return nil
    }
}

@MainActor
private protocol PsiloMorphBinding: AnyObject {
    func setWeight(_ weight: Float, deltaTime: Float)
}

/// We change only existing weights. Replacing names or the weight-set shape is
/// ignored by RealityKit, so indices are resolved once from the imported mesh.
@available(macOS 15, *)
@MainActor
private final class PsiloNativeMorphBinding: PsiloMorphBinding {
    private let entity: Entity
    private let slots: [(set: Int, weight: Int)]
    private var previous: Float = -1

    init?(entity: Entity, shape: String, debugLogging: Bool) {
        guard let model = entity.components[ModelComponent.self] else { return nil }
        // Invalid authored deltas can disappear into the GPU instead of
        // throwing an error. Validate the imported surface before enabling it.
        var exposedOffsetCount = 0
        for meshModel in model.mesh.contents.models {
            for part in meshModel.parts {
                for name in part.blendShapeNames where Self.matches(name, shape) {
                    if let offsets = part.blendShapeOffsets(named: name) {
                        guard offsets.elements.allSatisfy(Self.isFinite),
                              part.positions.elements.allSatisfy(Self.isFinite) else {
                            if debugLogging { NSLog("Psilo native channel rejected nonfinite geometry: %@", entity.name) }
                            return nil
                        }
                        exposedOffsetCount += offsets.count
                    }
                }
            }
        }
        // Some live-scene imports retain weight names but omit the deforming
        // buffers. Those weights change numerically without moving the face.
        // Use our validated target meshes unless actual offsets are present.
        guard exposedOffsetCount > 0 else {
            if debugLogging {
                NSLog("Psilo native channel has no deformation offsets; using mesh fallback: %@", entity.name)
            }
            return nil
        }
        let component = entity.components[BlendShapeWeightsComponent.self]
            ?? BlendShapeWeightsComponent(weightsMapping: BlendShapeWeightsMapping(meshResource: model.mesh))
        var found: [(set: Int, weight: Int)] = []
        for setIndex in component.weightSet.indices {
            for (weightIndex, name) in component.weightSet[setIndex].weightNames.enumerated()
                where Self.matches(name, shape) {
                found.append((setIndex, weightIndex))
            }
        }
        if debugLogging {
            NSLog("Psilo native channel %@: offsets=%ld, mapped weights=%ld", entity.name, exposedOffsetCount, found.count)
        }
        guard !found.isEmpty else { return nil }
        self.entity = entity
        slots = found
        entity.components.set(component)
    }

    func setWeight(_ weight: Float, deltaTime: Float) {
        guard abs(weight - previous) > 0.00005,
              var component = entity.components[BlendShapeWeightsComponent.self] else { return }
        for slot in slots {
            var data = component.weightSet[slot.set]
            data.weights[slot.weight] = weight
            component.weightSet[slot.set] = data
        }
        entity.components.set(component)
        previous = weight
    }

    private static func matches(_ name: String, _ shape: String) -> Bool {
        name == shape || name.hasSuffix("/" + shape) || name.hasSuffix("." + shape)
    }

    private static func isFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }
}

/// macOS 14 cannot set imported blend-shape weights. Its fallback interpolates
/// identical-topology meshes only while a facial expression changes, at most
/// 30 updates/second. Stable/hidden states perform no mesh replacement work.
@MainActor
private final class PsiloMeshMorphBinding: PsiloMorphBinding {
    private struct Part {
        let modelID: String
        let part: MeshResource.Part
        let neutral: [SIMD3<Float>]
        let delta: [SIMD3<Float>]
        let neutralNormals: [SIMD3<Float>]?
        let targetNormals: [SIMD3<Float>]?
    }

    private let mesh: MeshResource
    private let neutralContents: MeshResource.Contents
    private let parts: [Part]
    private let debugLogging: Bool
    private var previous: Float = 0
    private var elapsed: Float = 0
    private var failed = false

    init?(source: Entity, target: Entity, debugLogging: Bool) {
        guard var sourceModel = source.components[ModelComponent.self],
              let targetModel = target.components[ModelComponent.self] else { return nil }
        let contents = sourceModel.mesh.contents
        let sourceModels = Array(contents.models)
        let targetModels = Array(targetModel.mesh.contents.models)
        guard sourceModels.count == targetModels.count, !sourceModels.isEmpty else { return nil }
        var records: [Part] = []
        for (a, b) in zip(sourceModels, targetModels) {
            let sourceParts = Array(a.parts), targetParts = Array(b.parts)
            guard sourceParts.count == targetParts.count else { return nil }
            for (part, other) in zip(sourceParts, targetParts) {
                let positions = part.positions.elements, targets = other.positions.elements
                guard positions.count == targets.count, !positions.isEmpty,
                      part.triangleIndices?.elements == other.triangleIndices?.elements,
                      part.materialIndex == other.materialIndex,
                      part.textureCoordinates?.elements == other.textureCoordinates?.elements,
                      positions.allSatisfy(Self.isFinite), targets.allSatisfy(Self.isFinite) else {
                    if debugLogging { NSLog("Psilo mesh morph rejected: invalid geometry or topology/UV mismatch in %@", source.name) }
                    return nil
                }
                let normals = part.normals?.elements, targetNormals = other.normals?.elements
                guard normals?.count == targetNormals?.count,
                      normals?.allSatisfy(Self.isFinite) ?? true,
                      targetNormals?.allSatisfy(Self.isFinite) ?? true else { return nil }
                records.append(Part(modelID: a.id, part: part, neutral: positions,
                                    delta: zip(positions, targets).map { $1 - $0 },
                                    neutralNormals: normals, targetNormals: targetNormals))
            }
        }
        do {
            // Own the mesh so updating this expression cannot mutate a shared
            // imported resource or the other eye through an USD instance.
            mesh = try MeshResource.generate(from: contents)
        } catch {
            NSLog("NeaTree: Psilo expression mesh could not be prepared: %@", error.localizedDescription)
            return nil
        }
        neutralContents = contents
        parts = records
        self.debugLogging = debugLogging
        sourceModel.mesh = mesh
        source.components.set(sourceModel)
        if #available(macOS 15, *) {
            source.components.remove(BlendShapeWeightsComponent.self)
        }
    }

    func setWeight(_ weight: Float, deltaTime: Float) {
        guard !failed else { return }
        elapsed += deltaTime
        guard abs(weight - previous) > 0.00005 else { return }
        guard elapsed >= 1 / 30 || weight == 0 || weight == 1 else { return }
        elapsed = 0
        var contents = neutralContents
        for record in parts {
            guard var model = contents.models[record.modelID] else { continue }
            var part = record.part
            part.positions = MeshBuffers.Positions(zip(record.neutral, record.delta).map { $0 + $1 * weight })
                .usingRate(record.part.positions.rate)
            if let neutral = record.neutralNormals, let target = record.targetNormals,
               let normalBuffer = record.part.normals {
                let normals = zip(neutral, target).map { a, b -> SIMD3<Float> in
                    let n = a + (b - a) * weight
                    return simd_length_squared(n) > 1e-10 ? simd_normalize(n) : a
                }
                part.normals = MeshBuffers.Normals(normals).usingRate(normalBuffer.rate)
            }
            model.parts.update(part)
            contents.models.update(model)
        }
        do {
            try mesh.replace(with: contents)
            previous = weight
        } catch {
            failed = true
            if debugLogging { NSLog("Psilo expression mesh update stopped: %@", error.localizedDescription) }
        }
    }

    private static func isFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }
}
