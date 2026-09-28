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
            return "Расположите телефон перед лицом"
        case .turnHeadLeftPartial:
            return "Поверните голову немного влево (раковина)"
        case .turnHeadLeftFull:
            return "Поверните голову влево до конца (профиль)"
        case .turnHeadRightPartial:
            return "Поверните голову немного вправо (раковина)"
        case .turnHeadRightFull:
            return "Поверните голову вправо до конца (профиль)"
        case .exporting:
            return "Генерация 3D модели и архива..."
        case .finished:
            return "Сканирование успешно завершено"
        case .error(let msg):
            return "Ошибка: \(msg)"
        }
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
    
    public let session = ARSession()
    
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private let ciContext = CIContext(options: nil)
    private var snapshots: [CaptureSnapshot] = []
    
    private var holdStartTime: Date?
    private let holdDurationRequired: TimeInterval = 0.6
    private var isCapturingStage: Bool = false
    
    override private init() {
        super.init()
        session.delegate = self
        configureAudioSession()
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
        targetHoldProgress = 0.0
        holdStartTime = nil
        isCapturingStage = false
        
        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = true
        config.providesAudioData = false
        
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        
        currentStage = .centerFace
        speak("Держите телефон прямо перед лицом на расстоянии около сорока сантиметров")
    }
    
    public func stopScanning() {
        session.pause()
        currentStage = .idle
        targetHoldProgress = 0.0
        holdStartTime = nil
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
    
    private func playCaptureCue() {
        AudioServicesPlaySystemSound(1057)
        hapticGenerator.prepare()
        hapticGenerator.impactOccurred()
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
        playCaptureCue()
        
        let stage = currentStage
        let yaw = currentYaw
        let pitch = currentPitch
        
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
        let jpegData = self.ciContext.jpegRepresentation(
            of: ciImage,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [:]
        )
        
        Task.detached(priority: .userInitiated) {
            let vertices = DepthPointCloudProcessor.shared.processFrame(frame: frame, faceAnchor: faceAnchor, step: 2)
            let snapName: String
            switch stage {
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
                vertices: vertices,
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
        holdStartTime = nil
        targetHoldProgress = 0.0
        isCapturingStage = false
        
        switch completedStage {
        case .centerFace:
            currentStage = .turnHeadLeftPartial
            speak("Отлично. Теперь поверните голову чуть-чуть влево")
        case .turnHeadLeftPartial:
            currentStage = .turnHeadLeftFull
            speak("Зафиксировано. Теперь поверните голову влево до конца")
        case .turnHeadLeftFull:
            currentStage = .turnHeadRightPartial
            speak("Отлично. Теперь поверните голову чуть-чуть вправо")
        case .turnHeadRightPartial:
            currentStage = .turnHeadRightFull
            speak("Зафиксировано. Теперь поверните голову вправо до конца")
        case .turnHeadRightFull:
            finishAndExport()
        default:
            break
        }
    }
    
    private func finishAndExport() {
        currentStage = .exporting
        speak("Сканирование завершено. Формирую трехмерную модель.")
        session.pause()
        
        let snaps = self.snapshots
        Task.detached(priority: .userInitiated) {
            do {
                let zipURL = try ModelExporter.shared.exportScanPackage(snapshots: snaps)
                await MainActor.run {
                    self.exportedZipURL = zipURL
                    self.currentStage = .finished(zipURL)
                    self.playCaptureCue()
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
        guard let faceAnchor = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first else {
            Task { @MainActor in
                self.isFaceDetected = false
                self.holdStartTime = nil
                self.targetHoldProgress = 0.0
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
            
            let isConditionMet = self.evaluateStageCondition(yaw: yaw, distance: distance)
            
            if isConditionMet {
                if let startTime = self.holdStartTime {
                    let elapsed = Date().timeIntervalSince(startTime)
                    self.targetHoldProgress = Float(min(elapsed / self.holdDurationRequired, 1.0))
                    if elapsed >= self.holdDurationRequired {
                        self.handleStageCompletion(frame: frame, faceAnchor: faceAnchor)
                    }
                } else {
                    self.holdStartTime = Date()
                    self.targetHoldProgress = 0.05
                }
            } else {
                self.holdStartTime = nil
                self.targetHoldProgress = 0.0
            }
        }
    }
}
