import AVFoundation
import SwiftUI
import UIKit

/// The camera, looking for the QR code `t3bot pair` shows. It only accepts a pairing link
/// (t3bot://connect?url=...&token=...) and says so when it sees another code.
struct ConnectScanner: View {
    var onFound: (Connection) -> Void
    @StateObject private var model = ScannerModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch model.state {
                case .asking:
                    ProgressView().tint(.white)
                case .running:
                    ScannerPreview(session: model.session).ignoresSafeArea()
                    finder
                case .denied:
                    message(symbol: "camera.fill",
                            title: "The camera is off for T3 Bot",
                            text: "Allow the camera in Settings to scan the code, or go back and paste the pairing link.",
                            button: "Open Settings") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) }
                    }
                case .noCamera:
                    message(symbol: "camera.fill",
                            title: "No camera here",
                            text: "This device has no camera to scan with. Go back and paste the pairing link, or type the address and the token.",
                            button: nil) {}
                }
            }
            .navigationTitle("Scan the pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            model.onFound = { c in
                Haptics.success()
                onFound(c)
            }
            model.start()
        }
        .onDisappear { model.stop() }
    }

    /// A square to aim with, and what to do under it.
    private var finder: some View {
        VStack(spacing: 20) {
            Spacer()
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 3)
                .frame(width: 240, height: 240)
                .accessibilityHidden(true)
            Text(model.wrongCode
                 ? "That code is not a T3 Bot pairing code. Scan the one t3bot pair shows on your Mac."
                 : "Run t3bot pair on your Mac and point the camera at the code.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.55)))
                .padding(.horizontal, 24)
                .animation(.easeInOut(duration: 0.2), value: model.wrongCode)
            Spacer()
            Spacer()
        }
    }

    private func message(symbol: String, title: String, text: String, button: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.white.opacity(0.7))
            Text(title).font(.headline).foregroundStyle(.white)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let button {
                Button(button, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 32)
    }
}

/// The capture session behind the scanner. The session is set up and started off the main thread (starting
/// one blocks for a moment); what it reads comes back on the main thread.
final class ScannerModel: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {
    enum State: Equatable { case asking, running, denied, noCamera }

    @Published var state: State = .asking
    /// A QR code was read, but it is not a pairing link.
    @Published var wrongCode = false
    var onFound: ((Connection) -> Void)?

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "t3bot.scanner")
    private var configured = false
    private var found = false

    func start() {
        found = false
        #if targetEnvironment(simulator)
        // A simulator has no camera, and asking for it would only put an alert over the screen.
        state = .noCamera
        #else
        authorize()
        #endif
    }

    private func authorize() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async {
                    if ok { self?.run() } else { self?.state = .denied }
                }
            }
        default:
            state = .denied
        }
    }

    private func run() {
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else {
            state = .noCamera
            return
        }
        state = .running
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                self.session.beginConfiguration()
                if self.session.canAddInput(input) { self.session.addInput(input) }
                let output = AVCaptureMetadataOutput()
                if self.session.canAddOutput(output) {
                    self.session.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                    if output.availableMetadataObjectTypes.contains(.qr) { output.metadataObjectTypes = [.qr] }
                }
                self.session.commitConfiguration()
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        // The session itself is held, so the camera stops even when this model is let go first.
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !found, let text = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        if let c = Connection.parse(link: text) {
            found = true
            stop()
            onFound?(c)
        } else if !wrongCode {
            wrongCode = true
            // The hint goes back to normal once that code has left the frame for a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.wrongCode = false }
        }
    }
}

/// The camera picture, filling the sheet.
struct ScannerPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.backgroundColor = .black
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
