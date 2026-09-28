import Foundation
import UIKit
import CoreImage
import CoreVideo
import simd

public struct CaptureSnapshot {
    public let name: String
    public let imageBuffer: CVPixelBuffer
    public let vertices: [ScannedVertex]
    public let yawDegrees: Float
    public let pitchDegrees: Float
}

public final class ModelExporter {
    public static let shared = ModelExporter()
    private let ciContext = CIContext(options: nil)
    
    private init() {}
    
    public func exportScanPackage(
        snapshots: [CaptureSnapshot]
    ) throws -> URL {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("ScanPackage_\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        
        var allVertices: [ScannedVertex] = []
        var snapshotMetadata: [[String: Any]] = []
        
        for snap in snapshots {
            allVertices.append(contentsOf: snap.vertices)
            
            let photoURL = tempDir.appendingPathComponent("\(snap.name).jpg")
            if let jpegData = convertPixelBufferToJPEG(pixelBuffer: snap.imageBuffer) {
                try? jpegData.write(to: photoURL)
            }
            
            snapshotMetadata.append([
                "name": snap.name,
                "vertex_count": snap.vertices.count,
                "yaw_degrees": snap.yawDegrees,
                "pitch_degrees": snap.pitchDegrees
            ])
        }
        
        let objURL = tempDir.appendingPathComponent("ear_head_scan.obj")
        try writeOBJ(vertices: allVertices, to: objURL)
        
        let plyURL = tempDir.appendingPathComponent("ear_head_scan.ply")
        try writePLY(vertices: allVertices, to: plyURL)
        
        var minBound = simd_float3(repeating: Float.greatestFiniteMagnitude)
        var maxBound = simd_float3(repeating: -Float.greatestFiniteMagnitude)
        for v in allVertices {
            minBound = simd_min(minBound, v.position)
            maxBound = simd_max(maxBound, v.position)
        }
        let dimensions = maxBound - minBound
        
        let metadata: [String: Any] = [
            "generator": "iOS TrueDepth Ear & Head Spatial Audio Scanner",
            "ios_version": UIDevice.current.systemVersion,
            "device_model": UIDevice.current.model,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "total_vertices": allVertices.count,
            "bounding_box_meters": [
                "width": dimensions.x,
                "height": dimensions.y,
                "depth": dimensions.z
            ],
            "snapshots": snapshotMetadata
        ]
        
        let metaURL = tempDir.appendingPathComponent("scan_metadata.json")
        let jsonData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted])
        try jsonData.write(to: metaURL)
        
        let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let timestamp = Int(Date().timeIntervalSince1970)
        let finalZipURL = documentsDir.appendingPathComponent("SpatialAudio_EarScan_\(timestamp).zip")
        
        var zipError: NSError?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        
        coordinator.coordinate(readingItemAt: tempDir, options: .forUploading, error: &coordinationError) { zippedTempURL in
            do {
                if fileManager.fileExists(atPath: finalZipURL.path) {
                    try fileManager.removeItem(at: finalZipURL)
                }
                try fileManager.copyItem(at: zippedTempURL, to: finalZipURL)
            } catch let err as NSError {
                zipError = err
            }
        }
        
        try? fileManager.removeItem(at: tempDir)
        
        if let err = coordinationError ?? zipError {
            throw err
        }
        
        return finalZipURL
    }
    
    private func convertPixelBufferToJPEG(pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.jpegRepresentation(of: ciImage, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:])
    }
    
    private func writeOBJ(vertices: [ScannedVertex], to url: URL) throws {
        var content = "# iOS Face ID TrueDepth Spatial Audio Scan\n# Vertices count: \(vertices.count)\n"
        content.reserveCapacity(vertices.count * 60)
        
        for v in vertices {
            let line = String(
                format: "v %.5f %.5f %.5f %.3f %.3f %.3f\n",
                v.position.x, v.position.y, v.position.z,
                v.color.x, v.color.y, v.color.z
            )
            content.append(line)
        }
        
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
    
    private func writePLY(vertices: [ScannedVertex], to url: URL) throws {
        var content = """
        ply
        format ascii 1.0
        comment Created by iOS TrueDepth FaceID Ear Scanner
        element vertex \(vertices.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header\n
        """
        content.reserveCapacity(vertices.count * 50)
        
        for v in vertices {
            let r = UInt8(min(max(v.color.x * 255.0, 0.0), 255.0))
            let g = UInt8(min(max(v.color.y * 255.0, 0.0), 255.0))
            let b = UInt8(min(max(v.color.z * 255.0, 0.0), 255.0))
            let line = String(
                format: "%.5f %.5f %.5f %d %d %d\n",
                v.position.x, v.position.y, v.position.z,
                r, g, b
            )
            content.append(line)
        }
        
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
