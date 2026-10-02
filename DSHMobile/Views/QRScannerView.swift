// ============================================================================
//  QRScannerView.swift — 扫码配对
//  ----------------------------------------------------------------------------
//  用 VisionKit 的 DataScannerViewController（iOS 16+，本 App 目标 iOS 17.0）
//  扫「远程配对链接」的二维码，直接提取配对令牌，替代手输 token。
//
//  二维码内容通常是：
//    https://<id>.dsh-market.com/pair-accept?pair=<token>
//  也可能是裸 token。QRScannerView 只负责把扫码得到的原始字符串回调出去，
//  令牌解析（提取 pair 参数 / 裸 token 兜底）由调用方 SetupView 完成。
//
//  说明：
//    · DataScannerViewController.isSupported/isAvailable 不满足时（无相机/被禁用），
//      回退显示一个"无法扫码"的提示页。
//    · 相机权限（NSCameraUsageDescription）已在 Info.plist 声明。
// ============================================================================
import SwiftUI
import VisionKit

/// 扫码视图（SwiftUI 包装 VisionKit DataScannerViewController）
struct QRScannerView: UIViewControllerRepresentable {
    /// 扫码成功的回调：参数是二维码的原始字符串
    var onScan: (String) -> Void
    /// 关闭（仅用于回退提示页）
    var onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            return UIHostingController(rootView: ScannerUnavailableView(onDismiss: onDismiss))
        }
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        guard let scanner = vc as? DataScannerViewController else { return }
        Task { @MainActor in
            guard !scanner.isScanning else { return }
            try? await scanner.startScanning()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: QRScannerView

        init(parent: QRScannerView) {
            self.parent = parent
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard let first = addedItems.first else { return }
            switch first {
            case .barcode(let barcode):
                if let payload = barcode.payloadStringValue {
                    parent.onScan(payload)
                }
            @unknown default:
                break
            }
        }
    }
}

/// 回退页：设备不支持扫码或相机不可用时显示
private struct ScannerUnavailableView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.on.rectangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("无法使用相机扫码")
                .font(.headline)
            Text("这台设备不支持二维码扫描，或相机权限未开启。\n请手动粘贴配对令牌。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("返回") { onDismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(.systemBackground))
    }
}
