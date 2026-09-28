import SwiftUI
import ARKit
import SceneKit

public struct CameraPreviewView: UIViewRepresentable {
    public let session: ARSession
    
    public init(session: ARSession) {
        self.session = session
    }
    
    public func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = true
        view.rendersContinuously = true
        return view
    }
    
    public func updateUIView(_ uiView: ARSCNView, context: Context) {
        if uiView.session !== session {
            uiView.session = session
        }
    }
}
