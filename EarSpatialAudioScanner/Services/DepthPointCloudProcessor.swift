import Foundation
import ARKit
import AVFoundation
import CoreVideo
import simd

public struct ScannedVertex {
    public let position: simd_float3
    public let color: simd_float3
}

public struct ScannedMesh {
    public var vertices: [ScannedVertex]
    public var triangles: [simd_int3]
    
    public init(vertices: [ScannedVertex] = [], triangles: [simd_int3] = []) {
        self.vertices = vertices
        self.triangles = triangles
    }
}

public final class DepthPointCloudProcessor {
    public static let shared = DepthPointCloudProcessor()
    
    private init() {}
    
    public func processFrame(
        frame: ARFrame,
        faceAnchor: ARFaceAnchor,
        customDepthData: AVDepthData? = nil,
        averagedDepth: [Float]? = nil,
        avgWidth: Int = 0,
        avgHeight: Int = 0,
        stage: ScanStage,
        step: Int = 2,
        liquidGlassSmoothing: Bool = false
    ) -> ScannedMesh {
        guard let rawDepthData = customDepthData ?? frame.capturedDepthData else {
            return fallbackFaceGeometry(faceAnchor: faceAnchor)
        }
        
        let depthData = rawDepthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap = depthData.depthDataMap
        let imageBuffer = frame.capturedImage
        
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)
        }
        
        guard let depthAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return fallbackFaceGeometry(faceAnchor: faceAnchor)
        }
        
        let useAveraged = (averagedDepth != nil && avgWidth > 0 && avgHeight > 0)
        let depthWidth = useAveraged ? avgWidth : CVPixelBufferGetWidth(depthMap)
        let depthHeight = useAveraged ? avgHeight : CVPixelBufferGetHeight(depthMap)
        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        
        let imageWidth = CVPixelBufferGetWidth(imageBuffer)
        let imageHeight = CVPixelBufferGetHeight(imageBuffer)
        
        let intrinsics: simd_float3x3
        let refW: Float
        let refH: Float
        
        if let calib = depthData.cameraCalibrationData {
            intrinsics = calib.intrinsicMatrix
            refW = Float(calib.intrinsicMatrixReferenceDimensions.width)
            refH = Float(calib.intrinsicMatrixReferenceDimensions.height)
        } else {
            intrinsics = frame.camera.intrinsics
            refW = Float(imageWidth)
            refH = Float(imageHeight)
        }
        
        let scaleX = Float(depthWidth) / refW
        let scaleY = Float(depthHeight) / refH
        let fx = intrinsics[0, 0] * scaleX
        let fy = intrinsics[1, 1] * scaleY
        let cx = intrinsics[2, 0] * scaleX
        let cy = intrinsics[2, 1] * scaleY
        
        let imgScaleX = Float(imageWidth) / Float(depthWidth)
        let imgScaleY = Float(imageHeight) / Float(depthHeight)
        
        let worldToHead = faceAnchor.transform.inverse
        let cameraToWorld = frame.camera.transform
        let cameraToHead = simd_mul(worldToHead, cameraToWorld)
        
        let camPosInHead4 = simd_mul(cameraToHead, simd_float4(0, 0, 0, 1))
        let camPosInHead = simd_float3(camPosInHead4.x, camPosInHead4.y, camPosInHead4.z)
        
        let gridCols = (depthWidth + step - 1) / step
        let gridRows = (depthHeight + step - 1) / step
        var gridIndices = [Int32](repeating: -1, count: gridCols * gridRows)
        
        var vertices: [ScannedVertex] = []
        vertices.reserveCapacity(gridCols * gridRows / 2)
        
        let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        let isYUV = (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                     pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        
        var yBase: UnsafeMutableRawPointer?
        var cbcrBase: UnsafeMutableRawPointer?
        var yBytesPerRow = 0
        var cbcrBytesPerRow = 0
        var bgraBase: UnsafeMutableRawPointer?
        var bgraBytesPerRow = 0
        
        if isYUV {
            yBase = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0)
            cbcrBase = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 1)
            yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0)
            cbcrBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 1)
        } else {
            bgraBase = CVPixelBufferGetBaseAddress(imageBuffer)
            bgraBytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        }
        
        var gridY = 0
        for y in stride(from: 0, to: depthHeight, by: step) {
            let rowFloats = depthAddress.advanced(by: y * depthBytesPerRow).assumingMemoryBound(to: Float32.self)
            var gridX = 0
            
            for x in stride(from: 0, to: depthWidth, by: step) {
                defer { gridX += 1 }
                var depth: Float
                if let avg = averagedDepth, useAveraged {
                    depth = avg[y * depthWidth + x]
                } else {
                    depth = rowFloats[x]
                }
                
                guard !depth.isNaN, !depth.isInfinite, depth >= 0.15, depth <= 0.70 else {
                    continue
                }
                
                var filteredDepth = depth
                var filterWeight: Float = 1.0
                let radius = 2
                let depthTolerance: Float = liquidGlassSmoothing ? 0.010 : 0.006
                
                for dy in -radius...radius {
                    let ny = y + dy
                    guard ny >= 0 && ny < depthHeight else { continue }
                    for dx in -radius...radius {
                        if dx == 0 && dy == 0 { continue }
                        let nx = x + dx
                        guard nx >= 0 && nx < depthWidth else { continue }
                        let nd: Float
                        if let avg = averagedDepth, useAveraged {
                            nd = avg[ny * depthWidth + nx]
                        } else {
                            let nRow = depthAddress.advanced(by: ny * depthBytesPerRow).assumingMemoryBound(to: Float32.self)
                            nd = nRow[nx]
                        }
                        if !nd.isNaN && !nd.isInfinite && abs(nd - depth) < depthTolerance {
                            let spatialDistSq = Float(dx * dx + dy * dy)
                            let w = 1.0 / (1.0 + spatialDistSq * 0.5)
                            filteredDepth += nd * w
                            filterWeight += w
                        }
                    }
                }
                depth = filteredDepth / filterWeight
                
                let u = Float(x) + 0.5
                let v = Float(y) + 0.5
                let xCam = (u - cx) * depth / fx
                let yCam = -(v - cy) * depth / fy
                let zCam = -depth
                
                let camPoint = simd_float4(xCam, yCam, zCam, 1.0)
                let headPoint = simd_mul(cameraToHead, camPoint)
                let headPos = simd_float3(headPoint.x, headPoint.y, headPoint.z)
                
                guard headPos.y >= -0.105 && headPos.y <= 0.135 else {
                    continue
                }
                guard headPos.z >= -0.130 && headPos.z <= 0.120 else {
                    continue
                }
                let radialDistXZ = hypot(headPos.x, headPos.z)
                guard radialDistXZ <= 0.135 else {
                    continue
                }
                
                switch stage {
                case .centerFace:
                    guard abs(headPos.x) <= 0.055 && headPos.z >= -0.010 else { continue }
                case .turnHeadLeftPartial, .turnHeadLeftFull:
                    if camPosInHead.x > 0 {
                        guard headPos.x >= 0.020 else { continue }
                    } else {
                        guard headPos.x <= -0.020 else { continue }
                    }
                case .turnHeadRightPartial, .turnHeadRightFull:
                    if camPosInHead.x > 0 {
                        guard headPos.x >= 0.020 else { continue }
                    } else {
                        guard headPos.x <= -0.020 else { continue }
                    }
                default:
                    break
                }
                
                let imgX = min(max(Int(u * imgScaleX), 0), imageWidth - 1)
                let imgY = min(max(Int(v * imgScaleY), 0), imageHeight - 1)
                
                var r: Float = 0.8
                var g: Float = 0.8
                var b: Float = 0.8
                
                if isYUV, let yPtr = yBase, let cbcrPtr = cbcrBase {
                    let yRow = yPtr.advanced(by: imgY * yBytesPerRow).assumingMemoryBound(to: UInt8.self)
                    let yVal = Float(yRow[imgX])
                    
                    let cbcrRow = cbcrPtr.advanced(by: (imgY / 2) * cbcrBytesPerRow).assumingMemoryBound(to: UInt8.self)
                    let cbVal = Float(cbcrRow[(imgX / 2) * 2]) - 128.0
                    let crVal = Float(cbcrRow[(imgX / 2) * 2 + 1]) - 128.0
                    
                    r = min(max((yVal + 1.402 * crVal) / 255.0, 0.0), 1.0)
                    g = min(max((yVal - 0.344136 * cbVal - 0.714136 * crVal) / 255.0, 0.0), 1.0)
                    b = min(max((yVal + 1.772 * cbVal) / 255.0, 0.0), 1.0)
                } else if let bgraPtr = bgraBase {
                    let row = bgraPtr.advanced(by: imgY * bgraBytesPerRow).assumingMemoryBound(to: UInt8.self)
                    let bVal = Float(row[imgX * 4]) / 255.0
                    let gVal = Float(row[imgX * 4 + 1]) / 255.0
                    let rVal = Float(row[imgX * 4 + 2]) / 255.0
                    r = rVal
                    g = gVal
                    b = bVal
                }
                
                let vertexIndex = Int32(vertices.count)
                vertices.append(ScannedVertex(position: headPos, color: simd_float3(r, g, b)))
                gridIndices[gridY * gridCols + gridX] = vertexIndex
            }
            gridY += 1
        }
        
        var triangles: [simd_int3] = []
        triangles.reserveCapacity(vertices.count * 2)
        let maxEdgeDistance: Float = 0.016
        
        for gy in 0..<(gridRows - 1) {
            for gx in 0..<(gridCols - 1) {
                let iTL = gridIndices[gy * gridCols + gx]
                let iTR = gridIndices[gy * gridCols + (gx + 1)]
                let iBL = gridIndices[(gy + 1) * gridCols + gx]
                let iBR = gridIndices[(gy + 1) * gridCols + (gx + 1)]
                
                if iTL >= 0 && iTR >= 0 && iBL >= 0 {
                    let pTL = vertices[Int(iTL)].position
                    let pTR = vertices[Int(iTR)].position
                    let pBL = vertices[Int(iBL)].position
                    
                    if simd_distance(pTL, pTR) <= maxEdgeDistance &&
                        simd_distance(pTL, pBL) <= maxEdgeDistance &&
                        simd_distance(pTR, pBL) <= maxEdgeDistance {
                        triangles.append(simd_int3(iTL, iTR, iBL))
                    }
                }
                
                if iTR >= 0 && iBR >= 0 && iBL >= 0 {
                    let pTR = vertices[Int(iTR)].position
                    let pBR = vertices[Int(iBR)].position
                    let pBL = vertices[Int(iBL)].position
                    
                    if simd_distance(pTR, pBR) <= maxEdgeDistance &&
                        simd_distance(pBL, pBR) <= maxEdgeDistance &&
                        simd_distance(pTR, pBL) <= maxEdgeDistance {
                        triangles.append(simd_int3(iTR, iBR, iBL))
                    }
                }
            }
        }
        
        if vertices.isEmpty {
            return fallbackFaceGeometry(faceAnchor: faceAnchor)
        }
        
        var smoothedVertices = vertices
        applyTaubinSmoothing(
            vertices: &smoothedVertices,
            triangles: triangles,
            iterations: liquidGlassSmoothing ? 6 : 4
        )
        
        return ScannedMesh(vertices: smoothedVertices, triangles: triangles)
    }
    
    private func applyTaubinSmoothing(
        vertices: inout [ScannedVertex],
        triangles: [simd_int3],
        iterations: Int = 4,
        lambda: Float = 0.5,
        mu: Float = -0.53
    ) {
        guard !vertices.isEmpty && !triangles.isEmpty else { return }
        
        var neighbors: [[Int32]] = Array(repeating: [], count: vertices.count)
        for tri in triangles {
            let i0 = tri.x
            let i1 = tri.y
            let i2 = tri.z
            guard i0 >= 0 && i1 >= 0 && i2 >= 0 &&
                  i0 < vertices.count && i1 < vertices.count && i2 < vertices.count else { continue }
            neighbors[Int(i0)].append(i1)
            neighbors[Int(i0)].append(i2)
            neighbors[Int(i1)].append(i0)
            neighbors[Int(i1)].append(i2)
            neighbors[Int(i2)].append(i0)
            neighbors[Int(i2)].append(i1)
        }
        
        var positions = vertices.map { $0.position }
        var temp = positions
        
        for _ in 0..<iterations {
            for i in 0..<positions.count {
                let nbrs = neighbors[i]
                guard !nbrs.isEmpty else { continue }
                var sum = simd_float3(0, 0, 0)
                for n in nbrs {
                    sum += positions[Int(n)]
                }
                let avg = sum / Float(nbrs.count)
                temp[i] = positions[i] + lambda * (avg - positions[i])
            }
            positions = temp
            
            for i in 0..<positions.count {
                let nbrs = neighbors[i]
                guard !nbrs.isEmpty else { continue }
                var sum = simd_float3(0, 0, 0)
                for n in nbrs {
                    sum += positions[Int(n)]
                }
                let avg = sum / Float(nbrs.count)
                temp[i] = positions[i] + mu * (avg - positions[i])
            }
            positions = temp
        }
        
        for i in 0..<vertices.count {
            vertices[i] = ScannedVertex(position: positions[i], color: vertices[i].color)
        }
    }
    
    private func fallbackFaceGeometry(faceAnchor: ARFaceAnchor) -> ScannedMesh {
        let verts = faceAnchor.geometry.vertices.map { pt in
            ScannedVertex(position: pt, color: simd_float3(0.8, 0.8, 0.8))
        }
        var tris: [simd_int3] = []
        let rawIndices = faceAnchor.geometry.triangleIndices
        for i in stride(from: 0, to: rawIndices.count - 2, by: 3) {
            tris.append(simd_int3(Int32(rawIndices[i]), Int32(rawIndices[i + 1]), Int32(rawIndices[i + 2])))
        }
        return ScannedMesh(vertices: verts, triangles: tris)
    }
}
