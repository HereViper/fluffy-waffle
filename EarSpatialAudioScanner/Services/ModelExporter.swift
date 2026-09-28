import Foundation
import UIKit
import CoreImage
import CoreVideo
import simd

public struct CaptureSnapshot {
    public let name: String
    public let jpegData: Data?
    public let vertices: [ScannedVertex]
    public let yawDegrees: Float
    public let pitchDegrees: Float
}

public enum PureSwiftCRC32 {
    private static let table: [UInt32] = {
        (0...255).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()
    
    public static func checksum(data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { buffer in
            guard let bytes = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<data.count {
                let index = Int((crc ^ UInt32(bytes[i])) & 0xFF)
                crc = table[index] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
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
            let crc = PureSwiftCRC32.checksum(data: entry.data)
            
            // Local file header
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
            
            // Central directory entry
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
        
        // End of central directory
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
        let fileManager = FileManager.default
        let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        let resultsDir = documentsDir.appendingPathComponent("EarScan_Results", isDirectory: true)
        try? fileManager.removeItem(at: resultsDir)
        try fileManager.createDirectory(at: resultsDir, withIntermediateDirectories: true)
        
        var allVertices: [ScannedVertex] = []
        var snapshotMetadata: [[String: Any]] = []
        var zipEntries: [(name: String, data: Data)] = []
        
        for snap in snapshots {
            allVertices.append(contentsOf: snap.vertices)
            
            if let photoData = snap.jpegData {
                let photoURL = resultsDir.appendingPathComponent("\(snap.name).jpg")
                try? photoData.write(to: photoURL)
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
        let objURL = resultsDir.appendingPathComponent("ear_head_scan.obj")
        try? objData.write(to: objURL)
        zipEntries.append((name: "ear_head_scan.obj", data: objData))
        
        let plyData = generatePLYData(vertices: allVertices)
        let plyURL = resultsDir.appendingPathComponent("ear_head_scan.ply")
        try? plyData.write(to: plyURL)
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
        let metaURL = resultsDir.appendingPathComponent("scan_metadata.json")
        try? jsonData.write(to: metaURL)
        zipEntries.append((name: "scan_metadata.json", data: jsonData))
        
        let finalZipURL = documentsDir.appendingPathComponent("SpatialAudio_EarScan.zip")
        try? fileManager.removeItem(at: finalZipURL)
        
        try SimpleZipWriter.createZip(entries: zipEntries, to: finalZipURL)
        
        return finalZipURL
    }
    
    private func generateOBJData(vertices: [ScannedVertex]) -> Data {
        var str = "# iOS Face ID TrueDepth Ear & Head Scan\n# Vertices count: \(vertices.count)\n"
        str.reserveCapacity(vertices.count * 48)
        
        for v in vertices {
            str.append("v \(round5(v.position.x)) \(round5(v.position.y)) \(round5(v.position.z)) \(round3(v.color.x)) \(round3(v.color.y)) \(round3(v.color.z))\n")
        }
        
        return str.data(using: .utf8) ?? Data()
    }
    
    private func generatePLYData(vertices: [ScannedVertex]) -> Data {
        var str = """
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
        str.reserveCapacity(vertices.count * 40)
        
        for v in vertices {
            let r = UInt8(min(max(v.color.x * 255.0, 0.0), 255.0))
            let g = UInt8(min(max(v.color.y * 255.0, 0.0), 255.0))
            let b = UInt8(min(max(v.color.z * 255.0, 0.0), 255.0))
            str.append("\(round5(v.position.x)) \(round5(v.position.y)) \(round5(v.position.z)) \(r) \(g) \(b)\n")
        }
        
        return str.data(using: .utf8) ?? Data()
    }
    
    @inline(__always)
    private func round5(_ val: Float) -> String {
        return String(format: "%.5f", val)
    }
    
    @inline(__always)
    private func round3(_ val: Float) -> String {
        return String(format: "%.3f", val)
    }
}
