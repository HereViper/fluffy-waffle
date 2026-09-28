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
        liquidGlassSmoothing: Bool = true,
        tuningRadius: Int = 5,
        tuningSpatialSigma: Float = 4.0,
        tuningRangeSigma: Float = 0.015,
        tuningTaubinIters: Int = 20
    ) -> ScannedMesh {
        if stage == .centerFace {
            return generateFaceGeometryMesh(faceAnchor: faceAnchor, frame: frame)
        }
        
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
        
        var rawDepthBuffer = [Float](repeating: 0, count: depthWidth * depthHeight)
        if let avg = averagedDepth, useAveraged {
            rawDepthBuffer = avg
        } else {
            for y in 0..<depthHeight {
                let row = depthAddress.advanced(by: y * depthBytesPerRow).assumingMemoryBound(to: Float32.self)
                let offset = y * depthWidth
                for x in 0..<depthWidth {
                    rawDepthBuffer[offset + x] = row[x]
                }
            }
        }
        
        let filteredDepthBuffer = bilateralFilterDepth(
            input: rawDepthBuffer,
            width: depthWidth,
            height: depthHeight,
            radius: tuningRadius,
            spatialSigma: tuningSpatialSigma,
            rangeSigma: tuningRangeSigma,
            maxDiff: tuningRangeSigma * 1.5
        )
        
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
        
        let isRightEar: Bool
        switch stage {
        case .turnHeadLeftPartial, .turnHeadLeftFull:
            isRightEar = true
        case .turnHeadRightPartial, .turnHeadRightFull:
            isRightEar = false
        default:
            isRightEar = true
        }
        
        let earCenter = simd_float3(isRightEar ? 0.072 : -0.072, 0.0, -0.025)
        
        let gridCols = (depthWidth + step - 1) / step
        let gridRows = (depthHeight + step - 1) / step
        var gridIndices = [Int32](repeating: -1, count: gridCols * gridRows)
        
        struct TempVertex {
            let headPos: simd_float3
            let camPos: simd_float3
            let color: simd_float3
        }
        
        var tempVertices: [TempVertex] = []
        tempVertices.reserveCapacity(gridCols * gridRows / 2)
        
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
            let rowOffset = y * depthWidth
            var gridX = 0
            
            for x in stride(from: 0, to: depthWidth, by: step) {
                defer { gridX += 1 }
                let depth = filteredDepthBuffer[rowOffset + x]
                
                guard !depth.isNaN, !depth.isInfinite, depth >= 0.16, depth <= 0.55 else {
                    continue
                }
                
                let u = Float(x) + 0.5
                let v = Float(y) + 0.5
                let xCam = (u - cx) * depth / fx
                let yCam = -(v - cy) * depth / fy
                let zCam = -depth
                
                let camPoint = simd_float4(xCam, yCam, zCam, 1.0)
                let headPoint = simd_mul(cameraToHead, camPoint)
                let headPos = simd_float3(headPoint.x, headPoint.y, headPoint.z)
                
                guard headPos.y >= -0.07 && headPos.y <= 0.07 else {
                    continue
                }
                guard headPos.z >= -0.09 && headPos.z <= 0.03 else {
                    continue
                }
                
                if isRightEar {
                    guard headPos.x >= 0.035 && headPos.x <= 0.115 else { continue }
                } else {
                    guard headPos.x <= -0.035 && headPos.x >= -0.115 else { continue }
                }
                
                guard simd_distance(headPos, earCenter) <= 0.08 else {
                    continue
                }
                
                let imgX = min(max(Int(u * imgScaleX), 0), imageWidth - 1)
                let imgY = min(max(Int(v * imgScaleY), 0), imageHeight - 1)
                
                var r: Float = 0.82
                var g: Float = 0.74
                var b: Float = 0.70
                
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
                
                let vertexIndex = Int32(tempVertices.count)
                tempVertices.append(TempVertex(
                    headPos: headPos,
                    camPos: simd_float3(xCam, yCam, zCam),
                    color: simd_float3(r, g, b)
                ))
                gridIndices[gridY * gridCols + gridX] = vertexIndex
            }
            gridY += 1
        }
        
        let maxEdgeDistHead: Float = 0.014
        let maxDepthJumpCam: Float = 0.010
        
        var rawTriangles: [simd_int3] = []
        rawTriangles.reserveCapacity(tempVertices.count * 2)
        
        func validateTriangle(iA: Int32, iB: Int32, iC: Int32) -> Bool {
            let vA = tempVertices[Int(iA)]
            let vB = tempVertices[Int(iB)]
            let vC = tempVertices[Int(iC)]
            
            let dCamAB = abs(vA.camPos.z - vB.camPos.z)
            let dCamBC = abs(vB.camPos.z - vC.camPos.z)
            let dCamCA = abs(vC.camPos.z - vA.camPos.z)
            guard dCamAB <= maxDepthJumpCam && dCamBC <= maxDepthJumpCam && dCamCA <= maxDepthJumpCam else {
                return false
            }
            
            guard simd_distance(vA.headPos, vB.headPos) <= maxEdgeDistHead &&
                  simd_distance(vB.headPos, vC.headPos) <= maxEdgeDistHead &&
                  simd_distance(vC.headPos, vA.headPos) <= maxEdgeDistHead else {
                return false
            }
            
            let edge1 = vB.camPos - vA.camPos
            let edge2 = vC.camPos - vA.camPos
            let normalCam = simd_cross(edge1, edge2)
            let normalLen = simd_length(normalCam)
            guard normalLen > 1e-6 else { return false }
            let nCam = normalCam / normalLen
            
            let triCenter = (vA.camPos + vB.camPos + vC.camPos) / 3.0
            let viewDir = simd_normalize(triCenter)
            let cosAngle = abs(simd_dot(nCam, viewDir))
            return cosAngle >= 0.12
        }
        
        for gy in 0..<(gridRows - 1) {
            for gx in 0..<(gridCols - 1) {
                let iTL = gridIndices[gy * gridCols + gx]
                let iTR = gridIndices[gy * gridCols + (gx + 1)]
                let iBL = gridIndices[(gy + 1) * gridCols + gx]
                let iBR = gridIndices[(gy + 1) * gridCols + (gx + 1)]
                
                if iTL >= 0 && iTR >= 0 && iBL >= 0 && validateTriangle(iA: iTL, iB: iTR, iC: iBL) {
                    rawTriangles.append(simd_int3(iTL, iTR, iBL))
                }
                
                if iTR >= 0 && iBR >= 0 && iBL >= 0 && validateTriangle(iA: iTR, iB: iBR, iC: iBL) {
                    rawTriangles.append(simd_int3(iTR, iBR, iBL))
                }
            }
        }
        
        var used = [Bool](repeating: false, count: tempVertices.count)
        for tri in rawTriangles {
            used[Int(tri.x)] = true
            used[Int(tri.y)] = true
            used[Int(tri.z)] = true
        }
        
        var remap = [Int32](repeating: -1, count: tempVertices.count)
        var cleanVertices: [ScannedVertex] = []
        cleanVertices.reserveCapacity(tempVertices.count)
        
        for i in 0..<tempVertices.count {
            if used[i] {
                remap[i] = Int32(cleanVertices.count)
                let tv = tempVertices[i]
                cleanVertices.append(ScannedVertex(position: tv.headPos, color: tv.color))
            }
        }
        
        var triangles: [simd_int3] = []
        triangles.reserveCapacity(rawTriangles.count)
        for tri in rawTriangles {
            let n0 = remap[Int(tri.x)]
            let n1 = remap[Int(tri.y)]
            let n2 = remap[Int(tri.z)]
            if n0 >= 0 && n1 >= 0 && n2 >= 0 {
                triangles.append(simd_int3(n0, n1, n2))
            }
        }
        
        if cleanVertices.count > 20 {
            var adjacency = [[Int]](repeating: [], count: cleanVertices.count)
            for tri in triangles {
                let a = Int(tri.x), b = Int(tri.y), c = Int(tri.z)
                adjacency[a].append(b); adjacency[a].append(c)
                adjacency[b].append(a); adjacency[b].append(c)
                adjacency[c].append(a); adjacency[c].append(b)
            }
            
            var componentId = [Int](repeating: -1, count: cleanVertices.count)
            var componentSizes: [Int] = []
            var currentId = 0
            
            for start in 0..<cleanVertices.count {
                guard componentId[start] == -1 else { continue }
                var stack = [start]
                var size = 0
                while !stack.isEmpty {
                    let v = stack.removeLast()
                    guard componentId[v] == -1 else { continue }
                    componentId[v] = currentId
                    size += 1
                    for nb in adjacency[v] where componentId[nb] == -1 {
                        stack.append(nb)
                    }
                }
                componentSizes.append(size)
                currentId += 1
            }
            
            let minComponentSize = max(20, cleanVertices.count / 8)
            var keepVertex = [Bool](repeating: false, count: cleanVertices.count)
            for i in 0..<cleanVertices.count {
                let cid = componentId[i]
                if cid >= 0 && componentSizes[cid] >= minComponentSize {
                    keepVertex[i] = true
                }
            }
            
            var remap2 = [Int32](repeating: -1, count: cleanVertices.count)
            var filteredVertices: [ScannedVertex] = []
            filteredVertices.reserveCapacity(cleanVertices.count)
            for i in 0..<cleanVertices.count {
                if keepVertex[i] {
                    remap2[i] = Int32(filteredVertices.count)
                    filteredVertices.append(cleanVertices[i])
                }
            }
            
            var filteredTriangles: [simd_int3] = []
            filteredTriangles.reserveCapacity(triangles.count)
            for tri in triangles {
                let a = remap2[Int(tri.x)]
                let b = remap2[Int(tri.y)]
                let c = remap2[Int(tri.z)]
                if a >= 0 && b >= 0 && c >= 0 {
                    filteredTriangles.append(simd_int3(a, b, c))
                }
            }
            
            cleanVertices = filteredVertices
            triangles = filteredTriangles
        }
        
        if cleanVertices.isEmpty {
            return fallbackFaceGeometry(faceAnchor: faceAnchor)
        }
        
        if liquidGlassSmoothing && cleanVertices.count > 4 {
            var neighbors = [[Int]](repeating: [], count: cleanVertices.count)
            for tri in triangles {
                let a = Int(tri.x), b = Int(tri.y), c = Int(tri.z)
                neighbors[a].append(b); neighbors[a].append(c)
                neighbors[b].append(a); neighbors[b].append(c)
                neighbors[c].append(a); neighbors[c].append(b)
            }
            
            for i in 0..<cleanVertices.count {
                neighbors[i] = Array(Set(neighbors[i]))
            }
            
            var positions = cleanVertices.map { $0.position }
            let lambda: Float = 0.50
            let mu: Float = -0.53
            let iterations = tuningTaubinIters
            
            for _ in 0..<iterations {
                var shrinkPos = positions
                for i in 0..<cleanVertices.count {
                    let nbrs = neighbors[i]
                    guard !nbrs.isEmpty else { continue }
                    var sum = simd_float3(0, 0, 0)
                    for n in nbrs { sum += positions[n] }
                    let avg = sum / Float(nbrs.count)
                    shrinkPos[i] = positions[i] + lambda * (avg - positions[i])
                }
                positions = shrinkPos
                
                var expandPos = positions
                for i in 0..<cleanVertices.count {
                    let nbrs = neighbors[i]
                    guard !nbrs.isEmpty else { continue }
                    var sum = simd_float3(0, 0, 0)
                    for n in nbrs { sum += positions[n] }
                    let avg = sum / Float(nbrs.count)
                    expandPos[i] = positions[i] + mu * (avg - positions[i])
                }
                positions = expandPos
            }
            
            for i in 0..<cleanVertices.count {
                cleanVertices[i] = ScannedVertex(position: positions[i], color: cleanVertices[i].color)
            }
        }
        
        return ScannedMesh(vertices: cleanVertices, triangles: triangles)
    }
    private func bilateralFilterDepth(
        input: [Float],
        width: Int,
        height: Int,
        radius: Int = 5,
        spatialSigma: Float = 4.0,
        rangeSigma: Float = 0.015,
        maxDiff: Float = 0.025
    ) -> [Float] {
        var output = input
        let spatialWeights: [[Float]] = {
            let size = radius * 2 + 1
            var w = [[Float]](repeating: [Float](repeating: 0, count: size), count: size)
            let twoSigmaSq = 2.0 * spatialSigma * spatialSigma
            for dy in -radius...radius {
                for dx in -radius...radius {
                    let r2 = Float(dx * dx + dy * dy)
                    w[dy + radius][dx + radius] = exp(-r2 / twoSigmaSq)
                }
            }
            return w
        }()
        let twoRangeSq = 2.0 * rangeSigma * rangeSigma
        
        for y in 0..<height {
            let yOffset = y * width
            for x in 0..<width {
                let centerD = input[yOffset + x]
                guard !centerD.isNaN, centerD >= 0.15, centerD <= 0.65 else {
                    continue
                }
                
                var sumVal: Float = centerD
                var sumW: Float = 1.0
                
                for dy in -radius...radius {
                    let ny = y + dy
                    guard ny >= 0 && ny < height else { continue }
                    let nOffset = ny * width
                    let swRow = spatialWeights[dy + radius]
                    
                    for dx in -radius...radius {
                        if dx == 0 && dy == 0 { continue }
                        let nx = x + dx
                        guard nx >= 0 && nx < width else { continue }
                        
                        let nD = input[nOffset + nx]
                        guard !nD.isNaN else { continue }
                        let diff = abs(nD - centerD)
                        if diff <= maxDiff {
                            let rw = exp(-(diff * diff) / twoRangeSq)
                            let weight = swRow[dx + radius] * rw
                            sumVal += nD * weight
                            sumW += weight
                        }
                    }
                }
                output[yOffset + x] = sumVal / sumW
            }
        }
        return output
    }
    
    private func generateFaceGeometryMesh(faceAnchor: ARFaceAnchor, frame: ARFrame) -> ScannedMesh {
        let geom = faceAnchor.geometry
        let faceVertices = geom.vertices
        let triangleIndices = geom.triangleIndices
        
        let imageBuffer = frame.capturedImage
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        
        let imgW = CVPixelBufferGetWidth(imageBuffer)
        let imgH = CVPixelBufferGetHeight(imageBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        let isYUV = (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                     pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        
        var yBase: UnsafeMutableRawPointer?
        var cbcrBase: UnsafeMutableRawPointer?
        var yBpr = 0
        var cbcrBpr = 0
        var bgraBase: UnsafeMutableRawPointer?
        var bgraBpr = 0
        
        if isYUV {
            yBase = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0)
            cbcrBase = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 1)
            yBpr = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0)
            cbcrBpr = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 1)
        } else {
            bgraBase = CVPixelBufferGetBaseAddress(imageBuffer)
            bgraBpr = CVPixelBufferGetBytesPerRow(imageBuffer)
        }
        
        let headToWorld = faceAnchor.transform
        let worldToCamera = frame.camera.transform.inverse
        let headToCamera = simd_mul(worldToCamera, headToWorld)
        
        let fx = frame.camera.intrinsics[0, 0]
        let fy = frame.camera.intrinsics[1, 1]
        let cx = frame.camera.intrinsics[2, 0]
        let cy = frame.camera.intrinsics[2, 1]
        
        var vertices: [ScannedVertex] = []
        vertices.reserveCapacity(faceVertices.count)
        
        for v in faceVertices {
            let pHead = simd_float4(v.x, v.y, v.z, 1.0)
            let pCam = simd_mul(headToCamera, pHead)
            
            var r: Float = 0.82
            var g: Float = 0.74
            var b: Float = 0.70
            
            if pCam.z < -0.05 {
                let depth = -pCam.z
                let u = (pCam.x * fx / depth) + cx
                let v_img = (-pCam.y * fy / depth) + cy
                let px = Int(round(u))
                let py = Int(round(v_img))
                
                if px >= 0 && px < imgW && py >= 0 && py < imgH {
                    if isYUV, let yP = yBase, let cP = cbcrBase {
                        let yRow = yP.advanced(by: py * yBpr).assumingMemoryBound(to: UInt8.self)
                        let yVal = Float(yRow[px])
                        let cRow = cP.advanced(by: (py / 2) * cbcrBpr).assumingMemoryBound(to: UInt8.self)
                        let cbVal = Float(cRow[(px / 2) * 2]) - 128.0
                        let crVal = Float(cRow[(px / 2) * 2 + 1]) - 128.0
                        r = min(max((yVal + 1.402 * crVal) / 255.0, 0.0), 1.0)
                        g = min(max((yVal - 0.344136 * cbVal - 0.714136 * crVal) / 255.0, 0.0), 1.0)
                        b = min(max((yVal + 1.772 * cbVal) / 255.0, 0.0), 1.0)
                    } else if let bP = bgraBase {
                        let row = bP.advanced(by: py * bgraBpr).assumingMemoryBound(to: UInt8.self)
                        b = Float(row[px * 4]) / 255.0
                        g = Float(row[px * 4 + 1]) / 255.0
                        r = Float(row[px * 4 + 2]) / 255.0
                    }
                }
            }
            
            vertices.append(ScannedVertex(position: v, color: simd_float3(r, g, b)))
        }
        
        var triangles: [simd_int3] = []
        triangles.reserveCapacity(triangleIndices.count / 3)
        for i in stride(from: 0, to: triangleIndices.count - 2, by: 3) {
            triangles.append(simd_int3(
                Int32(triangleIndices[i]),
                Int32(triangleIndices[i + 1]),
                Int32(triangleIndices[i + 2])
            ))
        }
        
        return ScannedMesh(vertices: vertices, triangles: triangles)
    }
    
    private func fallbackFaceGeometry(faceAnchor: ARFaceAnchor) -> ScannedMesh {
        let verts = faceAnchor.geometry.vertices.map { pt in
            ScannedVertex(position: pt, color: simd_float3(0.82, 0.74, 0.70))
        }
        var tris: [simd_int3] = []
        let rawIndices = faceAnchor.geometry.triangleIndices
        for i in stride(from: 0, to: rawIndices.count - 2, by: 3) {
            tris.append(simd_int3(Int32(rawIndices[i]), Int32(rawIndices[i + 1]), Int32(rawIndices[i + 2])))
        }
        return ScannedMesh(vertices: verts, triangles: tris)
    }
}
