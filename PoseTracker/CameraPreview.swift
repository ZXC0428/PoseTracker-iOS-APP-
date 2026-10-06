import AVFoundation
import SwiftUI

/// 將 UIKit 的 AVCaptureVideoPreviewLayer 包裝成 SwiftUI View。
///
/// SwiftUI 沒有原生的相機預覽元件，所以透過 UIViewRepresentable
/// 把 AVCaptureSession 的影像顯示在畫面最底層。
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    /// 第一次建立 View 時，將相機 Session 綁定到預覽圖層。
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    /// SwiftUI 狀態更新時，確保預覽仍使用最新的 Session。
    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }
}

/// 底層 layer 直接使用 AVCaptureVideoPreviewLayer，避免額外複製影像。
final class PreviewView: UIView {
    /// 告訴 UIKit 這個 View 的 backing layer 類型。
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    /// 提供型別安全的方式取得相機預覽圖層。
    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
