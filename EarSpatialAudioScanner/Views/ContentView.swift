import SwiftUI

public struct ContentView: View {
    @StateObject private var scanner = ScannerSession.shared
    @State private var showingShareSheet = false
    
    public init() {}
    
    public var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if scanner.currentStage != .idle && scanner.currentStage != .unsupported {
                CameraPreviewView(session: scanner.session)
                    .edgesIgnoringSafeArea(.all)
                    .opacity(scanner.currentStage == .exporting ? 0.3 : 1.0)
            }
            
            VStack(spacing: 20) {
                headerView
                
                Spacer()
                
                if scanner.currentStage == .centerFace ||
                    scanner.currentStage == .turnHeadLeft ||
                    scanner.currentStage == .turnHeadRight {
                    targetAngleGuide
                }
                
                Spacer()
                
                bottomControlPanel
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .sheet(isPresented: $showingShareSheet) {
            if let zipURL = scanner.exportedZipURL {
                ShareSheet(activityItems: [zipURL])
            }
        }
        .onReceive(scanner.$exportedZipURL) { url in
            if url != nil {
                showingShareSheet = true
            }
        }
    }
    
    private var headerView: some View {
        VStack(spacing: 8) {
            Text("3D Сканер ушей (Face ID)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            
            Text(scanner.currentStage.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(stageColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.65))
                .cornerRadius(12)
            
            if scanner.isFaceDetected {
                HStack(spacing: 16) {
                    Label(
                        title: { Text(String(format: "%.0f см", scanner.distanceMeters * 100)) },
                        icon: { Image(systemName: "ruler") }
                    )
                    Label(
                        title: { Text(String(format: "Угол: %.0f°", scanner.currentYaw)) },
                        icon: { Image(systemName: "arrow.left.and.right") }
                    )
                }
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.45))
                .cornerRadius(8)
            }
        }
        .padding(.top, 8)
    }
    
    private var targetAngleGuide: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.2), lineWidth: 4)
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
            
            VStack(spacing: 12) {
                indicatorSymbol
                
                if scanner.targetHoldProgress > 0 {
                    Text(String(format: "%.0f%%", scanner.targetHoldProgress * 100))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.green)
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
        case .turnHeadLeft:
            Image(systemName: "arrow.left.circle.fill")
                .font(.system(size: 52, weight: .bold))
                .foregroundColor(.white)
        case .turnHeadRight:
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 52, weight: .bold))
                .foregroundColor(.white)
        default:
            EmptyView()
        }
    }
    
    private var bottomControlPanel: some View {
        VStack(spacing: 16) {
            switch scanner.currentStage {
            case .idle:
                Button(action: {
                    scanner.startScanning()
                }) {
                    Text("Начать сканирование")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.white)
                        .cornerRadius(14)
                }
                
            case .centerFace, .turnHeadLeft, .turnHeadRight:
                HStack(spacing: 12) {
                    stepBadge(index: 1, active: scanner.currentStage == .centerFace, text: "Центр")
                    stepBadge(index: 2, active: scanner.currentStage == .turnHeadLeft, text: "Влево")
                    stepBadge(index: 3, active: scanner.currentStage == .turnHeadRight, text: "Вправо")
                }
                
                Button(action: {
                    scanner.stopScanning()
                }) {
                    Text("Отмена")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.vertical, 8)
                }
                
            case .exporting:
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.3)
                    Text("Генерация OBJ и PLY файлов...")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding()
                
            case .finished(let url):
                VStack(spacing: 12) {
                    Button(action: {
                        showingShareSheet = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Поделиться архивом (ZIP)")
                        }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.white)
                        .cornerRadius(14)
                    }
                    
                    Text("Файл также сохранен в папку приложения (доступен через провод USB на ПК)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                    
                    Button(action: {
                        scanner.startScanning()
                    }) {
                        Text("Сканировать заново")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
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
                }
            }
        }
        .padding(.bottom, 8)
    }
    
    private func stepBadge(index: Int, active: Bool, text: String) -> some View {
        HStack(spacing: 4) {
            Text("\(index)")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(active ? .black : .white)
                .frame(width: 20, height: 20)
                .background(active ? Color.white : Color.white.opacity(0.2))
                .clipShape(Circle())
            
            Text(text)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .white : .white.opacity(0.5))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(active ? Color.white.opacity(0.2) : Color.clear)
        .cornerRadius(10)
    }
    
    private var stageColor: Color {
        switch scanner.currentStage {
        case .centerFace, .turnHeadLeft, .turnHeadRight:
            return scanner.targetHoldProgress > 0 ? .green : .white
        case .finished:
            return .green
        case .unsupported, .error:
            return .red
        default:
            return .white
        }
    }
}
