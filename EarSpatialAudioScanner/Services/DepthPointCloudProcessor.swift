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
        stage: ScanStage,
        step: Int = 3,
        maxHeadRadius: Float = 0.28,
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
        
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        
        let imageWidth = CVPixelBufferGetWidth(imageBuffer)
        let imageHeight = CVPixelBufferGetHeight(imageBuffer)
        
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics[0, 0]
        let fy = intrinsics[1, 1]
        let cx = intrinsics[2, 0]
        let cy = intrinsics[2, 1]
        
        let scaleX = Float(imageWidth) / Float(depthWidth)
        let scaleY = Float(imageHeight) / Float(depthHeight)
        
        let worldToHead = faceAnchor.transform.inverse
        let cameraToWorld = frame.camera.transform
        let cameraToHead = simd_mul(worldToHead, cameraToWorld)
        
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
            let rowStart = depthAddress.advanced(by: y * depthBytesPerRow)
            let rowFloats = rowStart.assumingMemoryBound(to: Float32.self)
            var gridX = 0
            
            for x in stride(from: 0, to: depthWidth, by: step) {
                defer { gridX += 1 }
                var depth = rowFloats[x]
                
                guard !depth.isNaN, !depth.isInfinite, depth >= 0.15, depth <= 0.75 else {
                    continue
                }
                
                if liquidGlassSmoothing && x > 0 && x < depthWidth - 1 && y > 0 && y < depthHeight - 1 {
                    let prevRow = depthAddress.advanced(by: (y - 1) * depthBytesPerRow).assumingMemoryBound(to: Float32.self)
                    let nextRow = depthAddress.advanced(by: (y + 1) * depthBytesPerRow).assumingMemoryBound(to: Float32.self)
                    let dL = rowFloats[x - 1]
                    let dR = rowFloats[x + 1]
                    let dU = prevRow[x]
                    let dD = nextRow[x]
                    if !dL.isNaN && !dR.isNaN && !dU.isNaN && !dD.isNaN &&
                        abs(dL - depth) < 0.03 && abs(dR - depth) < 0.03 {
                        depth = depth * 0.5 + (dL + dR + dU + dD) * 0.125
                    }
                }
                
                let u = (Float(x) + 0.5) * scaleX
                let v = (Float(y) + 0.5) * scaleY
                
                let xCam = (u - cx) * depth / fx
                let yCam = -(v - cy) * depth / fy
                let zCam = -depth
                
                let camPoint = simd_float4(xCam, yCam, zCam, 1.0)
                let headPoint = simd_mul(cameraToHead, camPoint)
                let headPos = simd_float3(headPoint.x, headPoint.y, headPoint.z)
                
                let distToHeadCenter = simd_length(headPos)
                guard distToHeadCenter <= maxHeadRadius else {
                    continue
                }
                
                switch stage {
                case .centerFace:
                    guard headPos.z >= -0.12 && abs(headPos.x) <= 0.14 else { continue }
                case .turnHeadLeftPartial, .turnHeadLeftFull:
                    guard headPos.x <= -0.015 else { continue }
                case .turnHeadRightPartial, .turnHeadRightFull:
                    guard headPos.x >= 0.015 else { continue }
                default:
                    break
                }
                
                let imgX = min(max(Int(u), 0), imageWidth - 1)
                let imgY = min(max(Int(v), 0), imageHeight - 1)
                
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
        
        return ScannedMesh(vertices: vertices, triangles: triangles)
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
