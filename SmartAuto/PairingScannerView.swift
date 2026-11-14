import AVFoundation
import CoreImage
import PhotosUI
import SwiftUI
import UIKit

/// Reads a vehicle's pairing QR code with the camera or from a saved picture.
struct PairingScannerView: View {
    let onPaired: (VehiclePairingCode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var camera: CameraState = .checking
    @State private var photo: PhotosPickerItem?
    @State private var error: String?
    @State private var rejected: String?
    @State private var finished = false

    private enum CameraState { case checking, ready, denied, unavailable }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    viewfinder
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .background(AppTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("เลือกรูป QR Code จากคลังภาพ", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("สแกน QR Code ที่แอป ZONTES Smart ให้สแกนตอนผูกรถ ซึ่งมักอยู่บนกล่องกุญแจ (PKE) ของรถ")
                        Text("ใช้ QR แชร์รถจากแอป ZONTES Smart ได้เช่นกัน ถ้าอยู่ในเครื่องนี้ให้บันทึกภาพหน้าจอแล้วเลือกจากคลังภาพ")
                        Text("โหมดนี้สั่งรถผ่าน Bluetooth (ล็อก ปลดล็อก เบาะ ฝาถังน้ำมัน) และอ่านแบตเตอรี่ ส่วนน้ำมันและลมยางมาจากบัญชี ZONTES จึงไม่แสดง")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("เชื่อมรถด้วย QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ปิด") { dismiss() }
                }
            }
            .task { await checkCamera() }
            .onChange(of: photo) { item in
                guard let item else { return }
                photo = nil
                Task { await read(item) }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var viewfinder: some View {
        switch camera {
        case .checking:
            ProgressView()
        case .ready:
            QRCameraView { text in handle(text) }
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(AppTheme.accent, lineWidth: 3)
                        .padding(48)
                        .allowsHitTesting(false)
                }
                .accessibilityLabel("กล้องสำหรับสแกน QR Code")
        case .denied:
            VStack(spacing: 12) {
                Image(systemName: "camera.fill").font(.largeTitle).foregroundStyle(.secondary)
                Text("Smart Auto ยังไม่ได้รับสิทธิ์ใช้กล้อง")
                    .font(.subheadline)
                Button("เปิดการตั้งค่า") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
        case .unavailable:
            Text("เครื่องนี้ไม่มีกล้องที่ใช้ได้ กรุณาเลือกรูปจากคลังภาพ")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
        }
    }

    private func checkCamera() async {
        guard AVCaptureDevice.default(for: .video) != nil else {
            camera = .unavailable
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            camera = .ready
        case .notDetermined:
            camera = await AVCaptureDevice.requestAccess(for: .video) ? .ready : .denied
        default:
            camera = .denied
        }
    }

    /// The camera reports the same code many times a second; a rejected one is reported once.
    private func handle(_ text: String) {
        guard !finished, text != rejected else { return }
        do {
            finish(try VehiclePairingCode.parse(text))
        } catch {
            rejected = text
            self.error = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func read(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = CIImage(data: data, options: [.applyOrientationProperty: true])
        else {
            error = "เปิดรูปนี้ไม่ได้ กรุณาเลือกรูปอื่น"
            return
        }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let texts = detector?.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString } ?? []
        guard !texts.isEmpty else {
            error = "ไม่พบ QR Code ในรูปนี้ ลองครอปให้เห็น QR ชัด ๆ แล้วเลือกใหม่"
            return
        }
        if let code = texts.lazy.compactMap({ try? VehiclePairingCode.parse($0) }).first {
            finish(code)
        } else {
            error = VehiclePairingCode.invalidCode.localizedDescription
        }
    }

    private func finish(_ code: VehiclePairingCode) {
        guard !finished else { return }
        finished = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onPaired(code)
    }
}

private struct QRCameraView: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.onCode = onCode
        context.coordinator.start(in: view)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "pairing-camera")

        func start(in view: PreviewView) {
            view.previewLayer.session = session
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device)
            else { return }
            session.beginConfiguration()
            if session.canAddInput(input) { session.addInput(input) }
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                if output.availableMetadataObjectTypes.contains(.qr) {
                    output.metadataObjectTypes = [.qr]
                }
            }
            session.commitConfiguration()
            let session = session
            queue.async { session.startRunning() }
        }

        func stop() {
            let session = session
            queue.async { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            for case let code as AVMetadataMachineReadableCodeObject in metadataObjects {
                if let text = code.stringValue { onCode?(text) }
            }
        }
    }
}
