import Foundation
import ARKit
import AVFoundation
import CoreVideo
import simd

public struct ScannedVertex {
    public let position: simd_float3
    public let color: simd_float3
}

public final class DepthPointCloudProcessor {
    public static let shared = DepthPointCloudProcessor()
    
    private init() {}
    
    public func processFrame(
        frame: ARFrame,
        faceAnchor: ARFaceAnchor,
        step: Int = 2,
        maxHeadRadius: Float = 0.25
    ) -> [ScannedVertex] {
        guard let rawDepthData = frame.capturedDepthData else {
            return []
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
            return []
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
        
        var vertices: [ScannedVertex] = []
        vertices.reserveCapacity((depthWidth / step) * (depthHeight / step))
        
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
        
        let depthFloatPointer = depthAddress.assumingMemoryBound(to: UInt8.self)
        
        for y in stride(from: 0, to: depthHeight, by: step) {
            let rowStart = depthFloatPointer.advanced(by: y * depthBytesPerRow)
            let rowFloats = rowStart.assumingMemoryBound(to: Float32.self)
            
            for x in stride(from: 0, to: depthWidth, by: step) {
                let depth = rowFloats[x]
                
                guard !depth.isNaN, !depth.isInfinite, depth >= 0.15, depth <= 0.75 else {
                    continue
                }
                
                let u = (Float(x) + 0.5) * scaleX
                let v = (Float(y) + 0.5) * scaleY
                
                let xCam = (u - cx) * depth / fx
                let yCam = (v - cy) * depth / fy
                let zCam = depth
                
                let camPoint = simd_float4(xCam, yCam, zCam, 1.0)
                let headPoint = simd_mul(cameraToHead, camPoint)
                
                let headPos = simd_float3(headPoint.x, headPoint.y, headPoint.z)
                let distToHeadCenter = simd_length(headPos)
                guard distToHeadCenter <= maxHeadRadius else {
                    continue
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
                
                vertices.append(ScannedVertex(position: headPos, color: simd_float3(r, g, b)))
            }
        }
        
        return vertices
    }
}
