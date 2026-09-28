import SwiftUI
import UIKit

public struct ContentView: View {
    @StateObject private var scanner = ScannerSession.shared
    
    public init() {}
    
    public var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if scanner.currentStage != .idle && scanner.currentStage != .unsupported {
                CameraPreviewView(session: scanner.session)
                    .edgesIgnoringSafeArea(.all)
                    .opacity(scanner.currentStage == .exporting ? 0.2 : 1.0)
            }
            
            VStack(spacing: 16) {
                headerView
                
                Spacer()
                
                if isScanningActive {
                    targetAngleGuide
                }
                
                Spacer()
                
                bottomControlPanel
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }
    
    private var isScanningActive: Bool {
        switch scanner.currentStage {
        case .centerFace, .turnHeadLeftPartial, .turnHeadLeftFull, .turnHeadRightPartial, .turnHeadRightFull:
            return true
        default:
            return false
        }
    }
    
    private var headerView: some View {
        VStack(spacing: 8) {
            HStack {
                Text("3D Сканер ушей")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Spacer()
                
                HStack(spacing: 8) {
                    Text("Ручной")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(scanner.isManualMode ? .white : .white.opacity(0.6))
                    
                    Toggle("", isOn: $scanner.isManualMode)
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: .orange))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular.tint(.orange).interactive())
            }
            
            Text(scanner.currentStage.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(stageColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.65))
                .cornerRadius(12)
            
            if scanner.currentStage == .turnHeadLeftFull || scanner.currentStage == .turnHeadRightFull {
                HStack(spacing: 6) {
                    Image(systemName: "ear")
                        .font(.system(size: 13))
                    Text("Уберите волосы за ухо для четкого захвата")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.yellow)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.55))
                .cornerRadius(8)
            }
            
            if scanner.distanceMeters > 0 {
                HStack(spacing: 16) {
                    Label(
                        title: { Text(String(format: "%.0f см", scanner.distanceMeters * 100)) },
                        icon: { Image(systemName: "ruler") }
                    )
                    .foregroundColor(
                        (scanner.distanceMeters >= 0.20 && scanner.distanceMeters <= 0.38) ? .green : .yellow
                    )
                    
                    if scanner.isFaceDetected {
                        Label(
                            title: { Text(String(format: "Угол: %.0f°", scanner.currentYaw)) },
                            icon: { Image(systemName: "arrow.left.and.right") }
                        )
                        .foregroundColor(.white.opacity(0.85))
                    }
                }
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.45))
                .cornerRadius(8)
            }
        }
        .padding(.top, 4)
    }
    
    private var targetAngleGuide: some View {
        ZStack {
            Circle()
                .stroke(
                    Color.white.opacity(0.2),
                    lineWidth: 4
                )
                .frame(width: 240, height: 240)
            
            Circle()
                .trim(from: 0.0, to: CGFloat(scanner.targetHoldProgress))
                .stroke(
                    Color.green,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 240, height: 240)
                .animation(.linear(duration: 0.1), value: scanner.targetHoldProgress)
            
            VStack(spacing: 8) {
                indicatorSymbol
                
                if scanner.currentBurstCount > 0 {
                    VStack(spacing: 2) {
                        Text("\(scanner.currentBurstCount) / \(scanner.targetBurstCount)")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(.green)
                        Text("Серия кадров...")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var indicatorSymbol: some View {
        switch scanner.currentStage {
        case .centerFace:
            Image(systemName: "person.crop.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.white)
        case .turnHeadLeftPartial:
            Image(systemName: "arrow.down.left.circle")
                .font(.system(size: 48, weight: .bold))
                .foregroundColor(.white)
        case .turnHeadLeftFull:
            Image(systemName: "arrow.left.circle.fill")
                .font(.system(size: 52, weight: .bold))
                .foregroundColor(.white)
        case .turnHeadRightPartial:
            Image(systemName: "arrow.down.right.circle")
                .font(.system(size: 48, weight: .bold))
                .foregroundColor(.white)
        case .turnHeadRightFull:
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 52, weight: .bold))
                .foregroundColor(.white)
        default:
            EmptyView()
        }
    }
    
    private var bottomControlPanel: some View {
        VStack(spacing: 14) {
            switch scanner.currentStage {
            case .idle:
                Button(action: {
                    scanner.startScanning()
                }) {
                    Label("Начать сканирование", systemImage: "sparkles")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.blue)
                
            case .centerFace, .turnHeadLeftPartial, .turnHeadLeftFull, .turnHeadRightPartial, .turnHeadRightFull:
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        stepBadge(index: 1, active: scanner.currentStage == .centerFace, text: "Лицо")
                        stepBadge(index: 2, active: scanner.currentStage == .turnHeadLeftPartial, text: "Прав. 3/4")
                        stepBadge(index: 3, active: scanner.currentStage == .turnHeadLeftFull, text: "Прав. Профиль")
                        stepBadge(index: 4, active: scanner.currentStage == .turnHeadRightPartial, text: "Лев. 3/4")
                        stepBadge(index: 5, active: scanner.currentStage == .turnHeadRightFull, text: "Лев. Профиль")
                    }
                    .padding(.horizontal, 4)
                }
                
                Button(role: .cancel, action: {
                    scanner.stopScanning()
                }) {
                    Text("Отмена")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.white)
                
            case .exporting:
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.3)
                    Text("Формирование 3D-модели (OBJ / PLY)...")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding()
                
            case .finished:
                VStack(spacing: 14) {
                    Text("3D модель успешно создана!")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.green)
                    
                    Text("Точек в модели: \(scanner.totalVerticesCount)")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                    
                    if let zipURL = scanner.exportedZipURL {
                        ShareLink(item: zipURL) {
                            Label("Поделиться архивом (ZIP)", systemImage: "square.and.arrow.up")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(.green)
                        
                        Button(action: {
                            presentSystemShare(url: zipURL)
                        }) {
                            Text("Сохранить в «Файлы» / Отправить")
                                .font(.system(size: 15, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .tint(.white)
                    }
                    
                    Text("Все файлы сохранены в Documents:\nEarScan_Results и SpatialAudio_EarScan.zip\n(доступны через USB кабель на ПК)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                    
                    Button(action: {
                        scanner.startScanning()
                    }) {
                        Label("Сканировать заново", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(.white)
                }
                
            case .unsupported:
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.yellow)
                    Text("Для работы сканера необходим iPhone с поддержкой Face ID (сенсор TrueDepth).")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(Color.white.opacity(0.1))
                .cornerRadius(14)
                
            case .error(let msg):
                VStack(spacing: 12) {
                    Text("Ошибка: \(msg)")
                        .font(.system(size: 14))
                        .foregroundColor(.red)
                    Button(action: {
                        scanner.startScanning()
                    }) {
                        Text("Попробовать снова")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.bottom, 8)
    }
    
    private func stepBadge(index: Int, active: Bool, text: String) -> some View {
        HStack(spacing: 4) {
            Text("\(index)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(active ? .black : .white)
                .frame(width: 18, height: 18)
                .background(active ? Color.white : Color.white.opacity(0.2))
                .clipShape(Circle())
            
            Text(text)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .white : .white.opacity(0.5))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(active ? Color.white.opacity(0.2) : Color.clear)
        .cornerRadius(8)
    }
    
    private var stageColor: Color {
        switch scanner.currentStage {
        case .centerFace, .turnHeadLeftPartial, .turnHeadLeftFull, .turnHeadRightPartial, .turnHeadRightFull:
            return scanner.targetHoldProgress > 0 ? .green : .white
        case .finished:
            return .green
        case .unsupported, .error:
            return .red
        default:
            return .white
        }
    }
    
    private func presentSystemShare(url: URL) {
        let scenes = UIApplication.shared.connectedScenes
        guard let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene ?? scenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return
        }
        
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = rootVC.view
            popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        
        var topController = rootVC
        while let presented = topController.presentedViewController {
            topController = presented
        }
        topController.present(activityVC, animated: true)
    }
}
