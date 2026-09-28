import Foundation
import UIKit
import CoreImage
import CoreVideo
import simd
import zlib

public struct CaptureSnapshot {
    public let name: String
    public let jpegData: Data?
    public let vertices: [ScannedVertex]
    public let yawDegrees: Float
    public let pitchDegrees: Float
}

public enum SimpleZipWriter {
    public static func createZip(entries: [(name: String, data: Data)], to outputURL: URL) throws {
        var zipData = Data()
        var centralDirectory = Data()
        
        for entry in entries {
            let offset = UInt32(zipData.count)
            let filenameData = entry.name.data(using: .utf8) ?? Data()
            let filenameLength = UInt16(filenameData.count)
            let uncompressedSize = UInt32(entry.data.count)
            
            var crc: UInt32 = 0
            entry.data.withUnsafeBytes { rawBuffer in
                if let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: Bytef.self) {
                    crc = UInt32(crc32(0, ptr, uInt(entry.data.count)))
                }
            }
            
            zipData.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
            zipData.append(contentsOf: [0x14, 0x00])
            zipData.append(contentsOf: [0x00, 0x00])
            zipData.append(contentsOf: [0x00, 0x00])
            zipData.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
            zipData.append(contentsOf: withUnsafeBytes(of: crc.littleEndian, Array.init))
            zipData.append(contentsOf: withUnsafeBytes(of: uncompressedSize.littleEndian, Array.init))
            zipData.append(contentsOf: withUnsafeBytes(of: uncompressedSize.littleEndian, Array.init))
            zipData.append(contentsOf: withUnsafeBytes(of: filenameLength.littleEndian, Array.init))
            zipData.append(contentsOf: [0x00, 0x00])
            zipData.append(filenameData)
            zipData.append(entry.data)
            
            centralDirectory.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])
            centralDirectory.append(contentsOf: [0x14, 0x00])
            centralDirectory.append(contentsOf: [0x14, 0x00])
            centralDirectory.append(contentsOf: [0x00, 0x00])
            centralDirectory.append(contentsOf: [0x00, 0x00])
            centralDirectory.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
            centralDirectory.append(contentsOf: withUnsafeBytes(of: crc.littleEndian, Array.init))
            centralDirectory.append(contentsOf: withUnsafeBytes(of: uncompressedSize.littleEndian, Array.init))
            centralDirectory.append(contentsOf: withUnsafeBytes(of: uncompressedSize.littleEndian, Array.init))
            centralDirectory.append(contentsOf: withUnsafeBytes(of: filenameLength.littleEndian, Array.init))
            centralDirectory.append(contentsOf: [0x00, 0x00])
            centralDirectory.append(contentsOf: [0x00, 0x00])
            centralDirectory.append(contentsOf: [0x00, 0x00])
            centralDirectory.append(contentsOf: [0x00, 0x00])
            centralDirectory.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
            centralDirectory.append(contentsOf: withUnsafeBytes(of: offset.littleEndian, Array.init))
            centralDirectory.append(filenameData)
        }
        
        let cdOffset = UInt32(zipData.count)
        let cdSize = UInt32(centralDirectory.count)
        let totalEntries = UInt16(entries.count)
        
        zipData.append(centralDirectory)
        
        zipData.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
        zipData.append(contentsOf: [0x00, 0x00])
        zipData.append(contentsOf: [0x00, 0x00])
        zipData.append(contentsOf: withUnsafeBytes(of: totalEntries.littleEndian, Array.init))
        zipData.append(contentsOf: withUnsafeBytes(of: totalEntries.littleEndian, Array.init))
        zipData.append(contentsOf: withUnsafeBytes(of: cdSize.littleEndian, Array.init))
        zipData.append(contentsOf: withUnsafeBytes(of: cdOffset.littleEndian, Array.init))
        zipData.append(contentsOf: [0x00, 0x00])
        
        try zipData.write(to: outputURL, options: .atomic)
    }
}

public final class ModelExporter {
    public static let shared = ModelExporter()
    
    private init() {}
    
    public func exportScanPackage(
        snapshots: [CaptureSnapshot]
    ) throws -> URL {
        var allVertices: [ScannedVertex] = []
        var snapshotMetadata: [[String: Any]] = []
        var zipEntries: [(name: String, data: Data)] = []
        
        for snap in snapshots {
            allVertices.append(contentsOf: snap.vertices)
            
            if let photoData = snap.jpegData {
                zipEntries.append((name: "\(snap.name).jpg", data: photoData))
            }
            
            snapshotMetadata.append([
                "name": snap.name,
                "vertex_count": snap.vertices.count,
                "yaw_degrees": snap.yawDegrees,
                "pitch_degrees": snap.pitchDegrees
            ])
        }
        
        let objData = generateOBJData(vertices: allVertices)
        zipEntries.append((name: "ear_head_scan.obj", data: objData))
        
        let plyData = generatePLYData(vertices: allVertices)
        zipEntries.append((name: "ear_head_scan.ply", data: plyData))
        
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
        
        let jsonData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted])
        zipEntries.append((name: "scan_metadata.json", data: jsonData))
        
        let fileManager = FileManager.default
        let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let timestamp = Int(Date().timeIntervalSince1970)
        let finalZipURL = documentsDir.appendingPathComponent("SpatialAudio_EarScan_\(timestamp).zip")
        
        try SimpleZipWriter.createZip(entries: zipEntries, to: finalZipURL)
        
        return finalZipURL
    }
    
    private func generateOBJData(vertices: [ScannedVertex]) -> Data {
        var content = "# iOS Face ID TrueDepth Spatial Audio Scan\n# Vertices count: \(vertices.count)\n"
        content.reserveCapacity(vertices.count * 50)
        
        for v in vertices {
            let line = String(
                format: "v %.5f %.5f %.5f %.3f %.3f %.3f\n",
                v.position.x, v.position.y, v.position.z,
                v.color.x, v.color.y, v.color.z
            )
            content.append(line)
        }
        
        return content.data(using: .utf8) ?? Data()
    }
    
    private func generatePLYData(vertices: [ScannedVertex]) -> Data {
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
        content.reserveCapacity(vertices.count * 45)
        
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
        
        return content.data(using: .utf8) ?? Data()
    }
}
