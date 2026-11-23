import SwiftUI
import AVFoundation
import ZCodeMobileCore

/// 配对页:毛玻璃卡片 + 动态激光扫码取景框 + 一键粘贴链接 + 已配对设备管理
struct PairingView: View {
    @EnvironmentObject var model: AppModel
    @State private var pasteText = ""
    @State private var pairError: String?
    @State private var showScanner = true
    @State private var scanSweep = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let device = model.device {
                        pairedDeviceCard(device)
                    }

                    scannerCard
                    pasteLinkCard

                    if let pairError {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.amber)
                            Text(pairError)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                        }
                        .padding(14)
                        .frostedSurface(
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                            strong: true,
                            tint: Theme.amber.opacity(0.12),
                            shadowRadius: 8
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .animation(Motion.smooth, value: pairError)
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .navigationTitle("配对桌面端")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("退出登录") {
                        Haptics.warning()
                        model.logout()
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func pairedDeviceCard(_ device: PairedDevice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已配对桌面")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 4)

            GlassCard(padding: 16, cornerRadius: 20, strong: true) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.azure)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Theme.azure.opacity(0.14)))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.deviceName ?? "我的电脑")
                                .font(.system(size: 15.5, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(device.deviceSid)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                    }

                    HStack(spacing: 10) {
                        Button {
                            Haptics.medium()
                            model.connect()
                        } label: {
                            Label("立即连接", systemImage: "bolt.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                        }
                        .buttonStyle(.glassProminent)

                        Button(role: .destructive) {
                            Haptics.warning()
                            model.unpair()
                        } label: {
                            Text("解除配对")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(Theme.coral)
                                .padding(.horizontal, 16)
                                .frame(height: 42)
                                .liquidGlassChrome(in: Capsule(), tint: Theme.coral.opacity(0.10), interactive: true)
                        }
                        .buttonStyle(bouncy())
                    }
                }
            }
        }
    }

    private var scannerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("扫码配对")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 4)

            GlassCard(padding: 12, cornerRadius: 22, strong: true) {
                VStack(spacing: 12) {
                    if showScanner {
                        ZStack {
                            QRScannerView { raw in
                                handlePair(raw: raw)
                            }
                            .frame(height: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                            // 动态玻璃取景框与激光扫描线
                            scannerOverlay
                                .frame(height: 300)
                                .allowsHitTesting(false)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Theme.specularBorderGradient, lineWidth: 1)
                        }
                    } else {
                        Button {
                            Haptics.light()
                            withAnimation(Motion.smooth) { showScanner = true }
                        } label: {
                            Label("打开相机扫码", systemImage: "camera.viewfinder")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                        }
                        .buttonStyle(.glassProminent)
                    }

                    Text("在电脑端 ZCode 左下角点击手机图标，打开「移动端远程控制」，对准弹出的二维码即可自动配对。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    private var scannerOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [24, 18]))
                .frame(width: 196, height: 196)
                .shadow(color: Theme.azure.opacity(0.6), radius: 10)

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [.clear, Theme.azure, Theme.mint, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 176, height: 2.5)
                .shadow(color: Theme.azure.opacity(0.9), radius: 8)
                .offset(y: scanSweep ? 78 : -78)
                .onAppear {
                    withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) {
                        scanSweep = true
                    }
                }
        }
    }

    private var pasteLinkCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("或粘贴连接地址")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 4)

            GlassCard(padding: 14, cornerRadius: 20, strong: true) {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        TextField("https://zcode.z.ai/remote/v4?sid=…", text: $pasteText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13.5, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 11)
                            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.inputFill))
                            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 0.8))

                        Button {
                            if let clip = UIPasteboard.general.string, !clip.isEmpty {
                                Haptics.light()
                                pasteText = clip
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 42, height: 42)
                                .liquidGlassChrome(in: Circle(), interactive: true)
                        }
                        .buttonStyle(bouncy(scale: 0.92))
                        .accessibilityLabel("粘贴剪贴板")
                    }

                    PrimaryActionButton(title: "连接此地址", systemName: "link") {
                        handlePair(raw: pasteText)
                    }
                    .opacity(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                    .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func handlePair(raw: String) {
        if let error = model.pairAndProceed(raw: raw) {
            Haptics.error()
            pairError = error
        } else {
            Haptics.success()
            pairError = nil
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
            label.text = "无法访问相机\n请在系统设置中允许 ZCodeMobile 使用相机，或使用下方粘贴连接地址"
            label.numberOfLines = 0
            label.font = .systemFont(ofSize: 13.5, weight: .medium)
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            ])
        }
    }
}

enum AudioServicesPlaySystemSoundShim {
    static func beep() {
        AudioServicesPlaySystemSound(SystemSoundID(1057))
    }
}
