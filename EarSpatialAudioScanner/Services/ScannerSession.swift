import Foundation
import ARKit
import AVFoundation
import AudioToolbox
import UIKit
import CoreImage
import Combine

public enum ScanStage: Equatable {
    case unsupported
    case idle
    case centerFace
    case turnHeadLeftPartial
    case turnHeadLeftFull
    case turnHeadRightPartial
    case turnHeadRightFull
    case exporting
    case finished(URL)
    case error(String)
    
    public var title: String {
        switch self {
        case .unsupported:
            return "Face ID не поддерживается"
        case .idle:
            return "Нажмите «Начать сканирование»"
        case .centerFace:
            return "Лицо прямо (дистанция 30 см, волосы назад)"
        case .turnHeadLeftPartial:
            return "Левое ухо 3/4: отведите телефон чуть влево"
        case .turnHeadLeftFull:
            return "Левое ухо в профиль: камера прямо в ухо (25 см)"
        case .turnHeadRightPartial:
            return "Правое ухо 3/4: отведите телефон чуть вправо"
        case .turnHeadRightFull:
            return "Правое ухо в профиль: камера прямо в ухо (25 см)"
        case .exporting:
            return "Обработка и сборка 3D анатомической модели..."
        case .finished:
            return "Сканирование успешно завершено"
        case .error(let msg):
            return "Ошибка: \(msg)"
        }
    }
}

final class DepthMedianAccumulator {
    var width: Int = 0
    var height: Int = 0
    var frames: [[Float]] = []
    
    func reset() {
        frames.removeAll(keepingCapacity: true)
    }
    
    func addFrame(depthData: AVDepthData) {
        let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap = converted.depthDataMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return }
        
        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        let bpr = CVPixelBufferGetBytesPerRow(depthMap)
        
        width = w
        height = h
        
        var buffer = [Float](repeating: .nan, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: Float32.self)
            let offset = y * w
            for x in 0..<w {
                let d = row[x]
                if !d.isNaN && !d.isInfinite && d >= 0.15 && d <= 0.65 {
                    buffer[offset + x] = d
                }
            }
        }
        frames.append(buffer)
    }
    
    func buildMedianBuffer() -> (buffer: [Float], width: Int, height: Int)? {
        guard !frames.isEmpty, width > 0, height > 0 else { return nil }
        let total = width * height
        let frameCount = frames.count
        
        if frameCount == 1 {
            return (frames[0], width, height)
        }
        
        var result = [Float](repeating: .nan, count: total)
        for i in 0..<total {
            var valid: [Float] = []
            for f in 0..<frameCount {
                let v = frames[f][i]
                if !v.isNaN {
                    valid.append(v)
                }
            }
            if valid.isEmpty {
                result[i] = .nan
            } else if valid.count == 1 {
                result[i] = valid[0]
            } else if valid.count == 2 {
                result[i] = (valid[0] + valid[1]) * 0.5
            } else {
                valid.sort()
                result[i] = valid[valid.count / 2]
            }
        }
        return (result, width, height)
    }
}

@MainActor
public final class ScannerSession: NSObject, ObservableObject {
    public static let shared = ScannerSession()
    
    @Published public private(set) var currentStage: ScanStage = .idle
    @Published public private(set) var currentYaw: Float = 0.0
    @Published public private(set) var currentPitch: Float = 0.0
    @Published public private(set) var distanceMeters: Float = 0.0
    @Published public private(set) var isFaceDetected: Bool = false
    @Published public private(set) var targetHoldProgress: Float = 0.0
    @Published public private(set) var exportedZipURL: URL?
    @Published public private(set) var totalVerticesCount: Int = 0
    @Published public var isLiquidGlassEnabled: Bool = true
    
    @Published public private(set) var currentBurstCount: Int = 0
    public let targetBurstCount: Int = 3
    
    public let session = ARSession()
    
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let completionHaptic = UIImpactFeedbackGenerator(style: .heavy)
    private let lightTapGenerator = UIImpactFeedbackGenerator(style: .light)
    private let ciContext = CIContext(options: nil)
    private var snapshots: [CaptureSnapshot] = []
    private var latestDepthData: AVDepthData?
    private var lastKnownFaceAnchor: ARFaceAnchor?
    private let depthAccumulator = DepthMedianAccumulator()
    
    private var lastBurstCaptureTime: Date?
    private var isCapturingStage: Bool = false
    
    override private init() {
        super.init()
        session.delegate = self
        configureAudioSession()
        lightTapGenerator.prepare()
        completionHaptic.prepare()
    }
    
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audioSession.setActive(true)
        } catch {}
    }
    
    public func startScanning() {
        guard ARFaceTrackingConfiguration.isSupported else {
            currentStage = .unsupported
            speak("Face ID не поддерживается на данном устройстве")
            return
        }
        
        snapshots.removeAll()
        exportedZipURL = nil
        totalVerticesCount = 0
        latestDepthData = nil
        lastKnownFaceAnchor = nil
        targetHoldProgress = 0.0
        currentBurstCount = 0
        lastBurstCaptureTime = nil
        isCapturingStage = false
        depthAccumulator.reset()
        distanceMeters = 0.0
        
        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = true
        config.providesAudioData = false
        
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        
        currentStage = .centerFace
        speak("Уберите волосы за уши. Держите телефон прямо перед лицом на расстоянии 30 сантиметров.")
    }
    
    public func stopScanning() {
        session.pause()
        currentStage = .idle
        targetHoldProgress = 0.0
        currentBurstCount = 0
        lastBurstCaptureTime = nil
        lastKnownFaceAnchor = nil
        depthAccumulator.reset()
    }
    
    private func speak(_ text: String) {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        speechSynthesizer.speak(utterance)
    }
    
    private func playCompletionCue() {
        AudioServicesPlaySystemSound(1057)
        completionHaptic.prepare()
        completionHaptic.impactOccurred()
    }
    
    private func evaluateStageCondition(yaw: Float, distance: Float, camPosInHead: simd_float3) -> Bool {
        guard distance >= 0.16 && distance <= 0.46 else {
            return false
        }
        
        switch currentStage {
        case .centerFace:
            return abs(yaw) <= 15.0
        case .turnHeadLeftPartial:
            return (yaw <= -10.0 || camPosInHead.x >= 0.030)
        case .turnHeadLeftFull:
            return (yaw <= -22.0 || camPosInHead.x >= 0.045)
        case .turnHeadRightPartial:
            return (yaw >= 10.0 || camPosInHead.x <= -0.030)
        case .turnHeadRightFull:
            return (yaw >= 22.0 || camPosInHead.x <= -0.045)
        default:
            return false
        }
    }
    
    private func handleStageCompletion(frame: ARFrame, faceAnchor: ARFaceAnchor) {
        guard !isCapturingStage else { return }
        isCapturingStage = true
        playCompletionCue()
        
        let stage = currentStage
        let yaw = currentYaw
        let pitch = currentPitch
        
        let medianData = self.depthAccumulator.buildMedianBuffer()
        self.depthAccumulator.reset()
        
        let pixelBuffer = frame.capturedImage
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let jpegData = self.ciContext.jpegRepresentation(
            of: ciImage,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [:]
        )
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        
        let liquidGlass = self.isLiquidGlassEnabled
        let currentScanStage = stage
        let depthToUse = frame.capturedDepthData ?? self.latestDepthData
        
        Task.detached(priority: .userInitiated) {
            let mesh = DepthPointCloudProcessor.shared.processFrame(
                frame: frame,
                faceAnchor: faceAnchor,
                customDepthData: depthToUse,
                averagedDepth: medianData?.buffer,
                avgWidth: medianData?.width ?? 0,
                avgHeight: medianData?.height ?? 0,
                stage: currentScanStage,
                step: 2,
                liquidGlassSmoothing: liquidGlass
            )
            let snapName: String
            switch currentScanStage {
            case .centerFace: snapName = "1_front_face"
            case .turnHeadLeftPartial: snapName = "2_left_ear_angle_3_4"
            case .turnHeadLeftFull: snapName = "3_left_ear_profile"
            case .turnHeadRightPartial: snapName = "4_right_ear_angle_3_4"
            case .turnHeadRightFull: snapName = "5_right_ear_profile"
            default: snapName = "scan"
            }
            
            let snapshot = CaptureSnapshot(
                name: snapName,
                jpegData: jpegData,
                mesh: mesh,
                yawDegrees: yaw,
                pitchDegrees: pitch
            )
            
            await MainActor.run {
                self.snapshots.append(snapshot)
                self.proceedAfterCapture(completedStage: stage)
            }
        }
    }
    
    private func proceedAfterCapture(completedStage: ScanStage) {
        currentBurstCount = 0
        lastBurstCaptureTime = nil
        targetHoldProgress = 0.0
        isCapturingStage = false
        depthAccumulator.reset()
        
        switch completedStage {
        case .centerFace:
            currentStage = .turnHeadLeftPartial
            speak("Отлично. Теперь отведите телефон немного влево к уху")
        case .turnHeadLeftPartial:
            currentStage = .turnHeadLeftFull
            speak("Зафиксировано. Направьте камеру прямо на левое ухо с расстояния 25 сантиметров")
        case .turnHeadLeftFull:
            currentStage = .turnHeadRightPartial
            speak("Отлично. Теперь перейдите к правому уху")
        case .turnHeadRightPartial:
            currentStage = .turnHeadRightFull
            speak("Зафиксировано. Направьте камеру прямо на правое ухо с расстояния 25 сантиметров")
        case .turnHeadRightFull:
            finishAndExport()
        default:
            break
        }
    }
    
    private func finishAndExport() {
        currentStage = .exporting
        speak("Сканирование завершено. Формирую анатомическую трехмерную модель высокой четкости.")
        session.pause()
        
        let snaps = self.snapshots
        let count = snaps.reduce(0) { $0 + $1.mesh.vertices.count }
        self.totalVerticesCount = count
        
        let liquidGlass = self.isLiquidGlassEnabled
        Task.detached(priority: .userInitiated) {
            do {
                let zipURL = try ModelExporter.shared.exportScanPackage(
                    snapshots: snaps,
                    liquidGlassEnabled: liquidGlass
                )
                await MainActor.run {
                    self.exportedZipURL = zipURL
                    self.currentStage = .finished(zipURL)
                    self.playCompletionCue()
                    self.speak("Файл готов к отправке на компьютер.")
                }
            } catch {
                await MainActor.run {
                    let errMsg = error.localizedDescription
                    self.currentStage = .error(errMsg)
                    self.speak("Ошибка: \(errMsg)")
                }
            }
        }
    }
}

extension ScannerSession: ARSessionDelegate {
    public nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        var hardwareDistance: Float?
        if let depth = frame.capturedDepthData {
            Task { @MainActor in
                self.latestDepthData = depth
            }
            let depthMap = depth.depthDataMap
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            let w = CVPixelBufferGetWidth(depthMap)
            let h = CVPixelBufferGetHeight(depthMap)
            let bpr = CVPixelBufferGetBytesPerRow(depthMap)
            if let base = CVPixelBufferGetBaseAddress(depthMap), w > 4 && h > 4 {
                let cx = w / 2
                let cy = h / 2
                var samples: [Float] = []
                samples.reserveCapacity(25)
                for dy in -2...2 {
                    let row = base.advanced(by: (cy + dy) * bpr).assumingMemoryBound(to: Float32.self)
                    for dx in -2...2 {
                        let d = row[cx + dx]
                        if !d.isNaN && !d.isInfinite && d >= 0.12 && d <= 1.20 {
                            samples.append(d)
                        }
                    }
                }
                if !samples.isEmpty {
                    samples.sort()
                    hardwareDistance = samples[samples.count / 2]
                }
            }
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }
        
        let faceAnchor = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first
        
        Task { @MainActor in
            if let anchor = faceAnchor {
                self.lastKnownFaceAnchor = anchor
            }
            
            guard let anchor = faceAnchor ?? self.lastKnownFaceAnchor else {
                self.isFaceDetected = false
                if let hwDist = hardwareDistance {
                    self.distanceMeters = hwDist
                }
                self.currentBurstCount = 0
                self.lastBurstCaptureTime = nil
                self.targetHoldProgress = 0.0
                self.depthAccumulator.reset()
                return
            }
            
            let camTransform = frame.camera.transform
            let camToFace = simd_mul(camTransform.inverse, anchor.transform)
            let facePosInCam = simd_float3(camToFace.columns.3.x, camToFace.columns.3.y, camToFace.columns.3.z)
            let anchorDist = simd_length(facePosInCam)
            
            let currentDist = hardwareDistance ?? anchorDist
            self.distanceMeters = currentDist
            self.isFaceDetected = (faceAnchor != nil)
            
            let r02 = camToFace.columns.2.x
            let r12 = camToFace.columns.2.y
            let yaw = asin(max(min(r02, 1.0), -1.0)) * 180.0 / .pi
            let pitch = asin(max(min(-r12, 1.0), -1.0)) * 180.0 / .pi
            self.currentYaw = yaw
            self.currentPitch = pitch
            
            let worldToHead = anchor.transform.inverse
            let cameraToHead = simd_mul(worldToHead, camTransform)
            let camPosInHead4 = simd_mul(cameraToHead, simd_float4(0, 0, 0, 1))
            let camPosInHead = simd_float3(camPosInHead4.x, camPosInHead4.y, camPosInHead4.z)
            
            guard self.currentStage == .centerFace ||
                    self.currentStage == .turnHeadLeftPartial ||
                    self.currentStage == .turnHeadLeftFull ||
                    self.currentStage == .turnHeadRightPartial ||
                    self.currentStage == .turnHeadRightFull else {
                return
            }
            
            guard !self.isCapturingStage else { return }
            
            let isConditionMet = self.evaluateStageCondition(yaw: yaw, distance: currentDist, camPosInHead: camPosInHead)
            
            if isConditionMet {
                let now = Date()
                let interval: TimeInterval = 0.06
                let shouldCapture: Bool
                if let lastTime = self.lastBurstCaptureTime {
                    shouldCapture = now.timeIntervalSince(lastTime) >= interval
                } else {
                    shouldCapture = true
                }
                
                if shouldCapture && self.currentBurstCount < self.targetBurstCount {
                    if let depth = frame.capturedDepthData ?? self.latestDepthData {
                        self.depthAccumulator.addFrame(depthData: depth)
                    }
                    self.currentBurstCount += 1
                    self.lastBurstCaptureTime = now
                    self.targetHoldProgress = Float(self.currentBurstCount) / Float(self.targetBurstCount)
                    
                    self.lightTapGenerator.prepare()
                    self.lightTapGenerator.impactOccurred()
                    
                    if self.currentBurstCount >= self.targetBurstCount {
                        self.handleStageCompletion(frame: frame, faceAnchor: anchor)
                    }
                }
            } else {
                self.currentBurstCount = 0
                self.lastBurstCaptureTime = nil
                self.targetHoldProgress = 0.0
                self.depthAccumulator.reset()
            }
        }
    }
}
