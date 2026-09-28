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
            return "Держите лицо прямо (уберите волосы за уши)"
        case .turnHeadLeftPartial:
            return "Поверните голову немного влево (раковина)"
        case .turnHeadLeftFull:
            return "Поверните голову влево до конца (профиль уха)"
        case .turnHeadRightPartial:
            return "Поверните голову немного вправо (раковина)"
        case .turnHeadRightFull:
            return "Поверните голову вправо до конца (профиль уха)"
        case .exporting:
            return "Серийное усреднение и сборка 3D модели..."
        case .finished:
            return "Сканирование успешно завершено"
        case .error(let msg):
            return "Ошибка: \(msg)"
        }
    }
}

final class DepthTemporalAccumulator {
    var width: Int = 0
    var height: Int = 0
    var depthSum: [Float] = []
    var depthCount: [Int] = []
    var sampleCount: Int = 0
    
    func reset() {
        sampleCount = 0
        depthSum.removeAll(keepingCapacity: true)
        depthCount.removeAll(keepingCapacity: true)
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
        
        if width != w || height != h || depthSum.count != w * h {
            width = w
            height = h
            depthSum = [Float](repeating: 0, count: w * h)
            depthCount = [Int](repeating: 0, count: w * h)
        }
        
        for y in 0..<h {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: Float32.self)
            let offset = y * w
            for x in 0..<w {
                let d = row[x]
                if !d.isNaN && !d.isInfinite && d >= 0.15 && d <= 0.70 {
                    depthSum[offset + x] += d
                    depthCount[offset + x] += 1
                }
            }
        }
        sampleCount += 1
    }
    
    func buildAveragedBuffer() -> (buffer: [Float], width: Int, height: Int)? {
        guard sampleCount > 0, width > 0, height > 0 else { return nil }
        var result = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let c = depthCount[i]
            result[i] = c > 0 ? (depthSum[i] / Float(c)) : .nan
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
    public let targetBurstCount: Int = 7
    
    public let session = ARSession()
    
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let completionHaptic = UIImpactFeedbackGenerator(style: .heavy)
    private let lightTapGenerator = UIImpactFeedbackGenerator(style: .light)
    private let ciContext = CIContext(options: nil)
    private var snapshots: [CaptureSnapshot] = []
    private var latestDepthData: AVDepthData?
    private let depthAccumulator = DepthTemporalAccumulator()
    
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
        targetHoldProgress = 0.0
        currentBurstCount = 0
        lastBurstCaptureTime = nil
        isCapturingStage = false
        depthAccumulator.reset()
        
        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = true
        config.providesAudioData = false
        
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        
        currentStage = .centerFace
        speak("Уберите волосы за уши. Держите телефон прямо перед лицом.")
    }
    
    public func stopScanning() {
        session.pause()
        currentStage = .idle
        targetHoldProgress = 0.0
        currentBurstCount = 0
        lastBurstCaptureTime = nil
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
    
    private func evaluateStageCondition(yaw: Float, distance: Float) -> Bool {
        guard distance >= 0.18 && distance <= 0.65 else {
            return false
        }
        
        switch currentStage {
        case .centerFace:
            return abs(yaw) <= 10.0
        case .turnHeadLeftPartial:
            return yaw <= -16.0 && yaw >= -30.0
        case .turnHeadLeftFull:
            return yaw <= -36.0
        case .turnHeadRightPartial:
            return yaw >= 16.0 && yaw <= 30.0
        case .turnHeadRightFull:
            return yaw >= 36.0
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
        
        let avgData = self.depthAccumulator.buildAveragedBuffer()
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
                averagedDepth: avgData?.buffer,
                avgWidth: avgData?.width ?? 0,
                avgHeight: avgData?.height ?? 0,
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
            speak("Отлично. Теперь поверните голову чуть-чуть влево")
        case .turnHeadLeftPartial:
            currentStage = .turnHeadLeftFull
            speak("Зафиксировано. Теперь поверните голову влево до конца, показывая ухо")
        case .turnHeadLeftFull:
            currentStage = .turnHeadRightPartial
            speak("Отлично. Теперь поверните голову чуть-чуть вправо")
        case .turnHeadRightPartial:
            currentStage = .turnHeadRightFull
            speak("Зафиксировано. Теперь поверните голову вправо до конца, показывая правое ухо")
        case .turnHeadRightFull:
            finishAndExport()
        default:
            break
        }
    }
    
    private func finishAndExport() {
        currentStage = .exporting
        speak("Сканирование завершено. Формирую усредненную трехмерную модель высокой четкости.")
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
        if let depth = frame.capturedDepthData {
            Task { @MainActor in
                self.latestDepthData = depth
            }
        }
        
        guard let faceAnchor = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first else {
            Task { @MainActor in
                self.isFaceDetected = false
                self.currentBurstCount = 0
                self.lastBurstCaptureTime = nil
                self.targetHoldProgress = 0.0
                self.depthAccumulator.reset()
            }
            return
        }
        
        let transform = faceAnchor.transform
        let r02 = transform.columns.2.x
        let r12 = transform.columns.2.y
        let yaw = asin(max(min(r02, 1.0), -1.0)) * 180.0 / .pi
        let pitch = asin(max(min(-r12, 1.0), -1.0)) * 180.0 / .pi
        let distance = simd_length(simd_float3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z))
        
        Task { @MainActor in
            self.isFaceDetected = true
            self.currentYaw = yaw
            self.currentPitch = pitch
            self.distanceMeters = distance
            
            guard self.currentStage == .centerFace ||
                    self.currentStage == .turnHeadLeftPartial ||
                    self.currentStage == .turnHeadLeftFull ||
                    self.currentStage == .turnHeadRightPartial ||
                    self.currentStage == .turnHeadRightFull else {
                return
            }
            
            guard !self.isCapturingStage else { return }
            
            let isConditionMet = self.evaluateStageCondition(yaw: yaw, distance: distance)
            
            if isConditionMet {
                let now = Date()
                let interval: TimeInterval = 0.11
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
                        self.handleStageCompletion(frame: frame, faceAnchor: faceAnchor)
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
