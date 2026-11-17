import SwiftUI
import AVFoundation
import ZCodeMobileCore

/// 配对页:扫桌面端二维码 / 粘贴连接地址 / 已配对设备管理
struct PairingView: View {
    @EnvironmentObject var model: AppModel
    @State private var pasteText = ""
    @State private var pairError: String?
    @State private var showScanner = true

    var body: some View {
        NavigationStack {
            List {
                if let device = model.device {
                    Section("已配对桌面") {
                        HStack {
                            Image(systemName: "desktopcomputer")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.deviceName ?? "我的电脑")
                                Text(device.deviceSid)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        Button("连接") { model.connect() }
                            .buttonStyle(.borderedProminent)
                        Button("解除配对", role: .destructive) { model.unpair() }
                    }
                }

                Section {
                    if showScanner {
                        QRScannerView { raw in
                            if let error = model.pairAndProceed(raw: raw) {
                                pairError = error
                            } else {
                                pairError = nil
                            }
                        }
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Button("打开相机扫码") { showScanner = true }
                    }
                } header: {
                    Text("扫码配对")
                } footer: {
                    Text("在电脑端 ZCode 左下角点击手机图标,打开「移动端远程控制」,扫描弹出的二维码")
                }

                Section {
                    TextField("https://zcode.z.ai/remote/v4?sid=…", text: $pasteText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("连接此地址") {
                        if let error = model.pairAndProceed(raw: pasteText) {
                            pairError = error
                        } else {
                            pairError = nil
                        }
                    }
                    .disabled(pasteText.isEmpty)
                } header: {
                    Text("或粘贴连接地址")
                }

                if let pairError {
                    Section {
                        Label(pairError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("配对桌面端")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("退出登录") { model.logout() }
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - AVFoundation 二维码扫描

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ vc: ScannerViewController, context: Context) {}

    final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var lastFire = Date.distantPast

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                showPermissionHint()
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
                let preview = AVCaptureVideoPreviewLayer(session: session)
                preview.videoGravity = .resizeAspectFill
                view.layer.addSublayer(preview)
                previewLayer = preview
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                if !session.isRunning { session.startRunning() }
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                if session.isRunning { session.stopRunning() }
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard Date().timeIntervalSince(lastFire) > 1.5 else { return } // 防重复触发
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  obj.type == .qr, let value = obj.stringValue else { return }
            lastFire = Date()
            AudioServicesPlaySystemSoundShim.beep()
            onCode?(value)
        }

        private func showPermissionHint() {
            let label = UILabel()
            label.text = "无法访问相机\n请在系统设置中允许 ZCodeMobile 使用相机,或使用下方粘贴连接地址"
            label.numberOfLines = 0
            label.textColor = .white
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
        }
    }
}

enum AudioServicesPlaySystemSoundShim {
    static func beep() {
        AudioServicesPlaySystemSound(SystemSoundID(1057))
    }
}
