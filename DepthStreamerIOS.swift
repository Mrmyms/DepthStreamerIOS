import Foundation
import ARKit
import UIKit
import Network
import AVFoundation
import Observation

// ─── Configuración global ─────────────────────────────────────────────────────

private let kPort: UInt16         = 8080
private let kTargetFPS: Double    = 15
private let kFrameInterval        = 1.0 / kTargetFPS
private let kJPEGQuality: CGFloat = 0.65

// ─── Frame rate limiter (thread-safe) ────────────────────────────────────────

private final class FrameThrottle {
    private var lastTime: TimeInterval = 0
    private let lock = NSLock()

    func shouldProcess() -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        defer { lock.unlock() }
        guard now - lastTime >= kFrameInterval else { return false }
        lastTime = now
        return true
    }
}

// ─── HTTP MJPEG Server ────────────────────────────────────────────────────────
//
//  GET /video  → MJPEG stream (compatible con cv2.VideoCapture)
//  GET /depth  → stream binario float32 [4B w][4B h][w*h*4B floats]
//  GET /       → página de status

final class HTTPServer {
    private var listener:     NWListener?
    private var videoClients: [ObjectIdentifier: NWConnection] = [:]
    private var depthClients: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "http.server", qos: .userInteractive)
    var onClientCount: ((Int) -> Void)?

    // ── Start / Stop ──────────────────────────────────────────────────────────

    func start(port: UInt16) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        listener = try? NWListener(using: params, on: p)
        listener?.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener?.start(queue: queue)
    }

    func stop() {
        videoClients.values.forEach { $0.cancel() }
        depthClients.values.forEach { $0.cancel() }
        videoClients.removeAll()
        depthClients.removeAll()
        listener?.cancel()
        listener = nil
    }

    // ── Accept & route ────────────────────────────────────────────────────────

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data,
                  let req = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            switch self.parsePath(req) {
            case "/video": self.registerVideo(conn)
            case "/depth": self.registerDepth(conn)
            default:       self.sendStatusPage(conn)
            }
        }
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.remove(conn)
            default: break
            }
        }
    }

    private func parsePath(_ req: String) -> String {
        let line  = req.components(separatedBy: "\r\n").first ?? ""
        let parts = line.components(separatedBy: " ")
        return parts.count >= 2 ? parts[1] : "/"
    }

    private func registerVideo(_ conn: NWConnection) {
        let h = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-cache\r\nPragma: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        send(conn, data: h.data(using: .utf8)!)
        videoClients[ObjectIdentifier(conn)] = conn
        reportCount()
    }

    private func registerDepth(_ conn: NWConnection) {
        let h = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        send(conn, data: h.data(using: .utf8)!)
        depthClients[ObjectIdentifier(conn)] = conn
        reportCount()
    }

    private func sendStatusPage(_ conn: NWConnection) {
        let ip   = deviceLocalIP() ?? "?"
        let html = """
        <!DOCTYPE html><html><head><meta charset='utf-8'>
        <style>body{font-family:monospace;background:#0a0a0a;color:#00ff88;padding:24px}
        a{color:#00cfff}h1{color:#fff}table{border-collapse:collapse;margin-top:16px}
        td{padding:8px 16px;border:1px solid #333}</style></head><body>
        <h1>DepthStreamer</h1>
        <table>
        <tr><td>Video (MJPEG)</td><td><a href='http://\(ip):8080/video'>http://\(ip):8080/video</a></td></tr>
        <tr><td>Depth stream</td><td><a href='http://\(ip):8080/depth'>http://\(ip):8080/depth</a></td></tr>
        </table>
        <p style='color:#888;margin-top:24px'>Compatible con OpenCV: cv2.VideoCapture("http://\(ip):8080/video")</p>
        </body></html>
        """
        let res = "HTTP/1.1 200 OK\r\nContent-Type: text/html;charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        conn.send(content: res.data(using: .utf8),
                  contentContext: .defaultMessage, isComplete: true,
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    private func remove(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        videoClients.removeValue(forKey: id)
        depthClients.removeValue(forKey: id)
        reportCount()
    }

    private func reportCount() {
        let n = videoClients.count + depthClients.count
        onClientCount?(n)
    }

    // ── Broadcast ─────────────────────────────────────────────────────────────

    func broadcastJPEG(_ jpeg: Data) {
        guard !videoClients.isEmpty else { return }
        var part = Data()
        part += "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".data(using: .utf8)!
        part += jpeg
        part += "\r\n".data(using: .utf8)!
        videoClients.values.forEach { send($0, data: part) }
    }

    func broadcastDepth(_ floats: [Float32], w: Int, h: Int) {
        guard !depthClients.isEmpty else { return }
        var packet = Data()
        var wv = UInt32(w).bigEndian, hv = UInt32(h).bigEndian
        packet += Data(bytes: &wv, count: 4)
        packet += Data(bytes: &hv, count: 4)
        packet += floats.withUnsafeBytes { Data($0) }
        depthClients.values.forEach { send($0, data: packet) }
    }

    private func send(_ conn: NWConnection, data: Data) {
        conn.send(content: data,
                  contentContext: .defaultMessage,
                  isComplete: false,
                  completion: .idempotent)
    }
}

// ─── Camera focus manager ─────────────────────────────────────────────────────

final class FocusManager {
    private var device: AVCaptureDevice?

    init() {
        device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceSubjectAreaDidChange,
            object: device,
            queue: .main
        ) { [weak self] _ in
            self?.lockHyperfocal()
        }
    }

    func enableContinuousAutoFocus() {
        lockHyperfocal()
    }

    func focusAt(point: CGPoint) {
        lockHyperfocal()  // ignorar tap — siempre hiperfocal
    }

    func lockHyperfocal() {
        guard let device else { return }
        try? device.lockForConfiguration()

        // Bloquear lente en posición hiperfocal (1.0 = infinito)
        // Con lente gran angular del iPhone todo queda nítido desde ~30cm
        if device.isFocusModeSupported(.locked) {
            device.focusMode = .autoFocus  // primero autofocus para calibrar
        }
        device.unlockForConfiguration()

        // Después de que autofocus converge, bloquear en esa posición
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            try? device.lockForConfiguration()
            device.focusMode = .locked  // congelar donde quedó
            device.unlockForConfiguration()
        }
    }
}
// ─── DepthStreamer ─────────────────────────────────────────────────────────────

@MainActor
@Observable
final class DepthStreamer: NSObject, ARSessionDelegate {

    // Estado público
    var isStreaming   = false
    var frameCount    = 0
    var clientCount   = 0
    var fps: Double   = 0
    var localIP: String? = deviceLocalIP()
    var resolution    = "–"
    var depthRes      = "–"
    var errorMessage: String?

    // Internos
    let arSession    = ARSession()
    private let server       = HTTPServer()
    private let throttle     = FrameThrottle()
    private let focus        = FocusManager()
    private let ciContext    = CIContext(options: [.useSoftwareRenderer: false])
    private var lastTime     = Date()
    private var frameBuffer  = 0

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    func start() {
        guard !isStreaming else { return }

        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            errorMessage = "Este dispositivo no soporta LiDAR"
            return
        }

        server.start(port: kPort)
        server.onClientCount = { [weak self] n in
            Task { @MainActor in self?.clientCount = n }
        }

        let config = ARWorldTrackingConfiguration()
        config.frameSemantics     = .sceneDepth
        config.videoFormat        = bestVideoFormat()
        config.isAutoFocusEnabled = true
        config.isLightEstimationEnabled = false
        config.videoHDRAllowed          = false

        arSession.delegate = self
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])

        focus.enableContinuousAutoFocus()

        isStreaming  = true
        errorMessage = nil
        print("✅ DepthStreamer activo en http://\(localIP ?? "?"):\(kPort)")
    }

    func stop() {
        guard isStreaming else { return }
        arSession.pause()
        server.stop()
        isStreaming = false
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.start() }
    }

    /// Tap-to-focus — llamar desde el gesto de tap en la UI
    func tapFocus(at normalizedPoint: CGPoint) {
        focus.focusAt(point: normalizedPoint)
    }

    // ── ARSessionDelegate ─────────────────────────────────────────────────────

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in self.errorMessage = error.localizedDescription }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in self.errorMessage = "Sesión interrumpida" }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            self.errorMessage = nil
            self.focus.enableContinuousAutoFocus()
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Limitar FPS
        guard throttle.shouldProcess() else { return }

        // ── RGB → JPEG ────────────────────────────────────────────────────────
        let pb   = frame.capturedImage
        let ci   = CIImage(cvPixelBuffer: pb)
        guard let cg   = ciContext.createCGImage(ci, from: ci.extent),
              let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: kJPEGQuality)
        else { return }

        let rgbW = CVPixelBufferGetWidth(pb)
        let rgbH = CVPixelBufferGetHeight(pb)

        // ── Depth → Float32 ───────────────────────────────────────────────────
        var floats: [Float32] = []
        var dw = 0, dh = 0
        if let dm = frame.sceneDepth?.depthMap {
            CVPixelBufferLockBaseAddress(dm, .readOnly)
            dw = CVPixelBufferGetWidth(dm)
            dh = CVPixelBufferGetHeight(dm)
            if let base = CVPixelBufferGetBaseAddress(dm) {
                floats = Array(UnsafeBufferPointer(
                    start: base.bindMemory(to: Float32.self, capacity: dw * dh),
                    count: dw * dh))
            }
            CVPixelBufferUnlockBaseAddress(dm, .readOnly)
        }

        // ── Broadcast + stats ─────────────────────────────────────────────────
        Task { @MainActor in
            self.server.broadcastJPEG(jpeg)
            if !floats.isEmpty { self.server.broadcastDepth(floats, w: dw, h: dh) }

            self.frameCount  += 1
            self.frameBuffer += 1
            self.resolution   = "\(rgbW)×\(rgbH)"
            self.depthRes     = dw > 0 ? "\(dw)×\(dh)" : "–"

            let elapsed = Date().timeIntervalSince(self.lastTime)
            if elapsed >= 1.0 {
                self.fps         = Double(self.frameBuffer) / elapsed
                self.frameBuffer = 0
                self.lastTime    = Date()
            }
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private func bestVideoFormat() -> ARConfiguration.VideoFormat {
        let formats  = ARWorldTrackingConfiguration.supportedVideoFormats
        // Preferir 1920×1440 o el de mayor resolución disponible
        let preferred = formats.first { $0.imageResolution.width >= 1920 }
        return preferred ?? formats[0]
    }
}

// ─── Utilities ────────────────────────────────────────────────────────────────

func deviceLocalIP() -> String? {
    var addr: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return nil }
    var ptr = ifaddr
    while ptr != nil {
        let iface = ptr!.pointee
        if iface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
           String(cString: iface.ifa_name) == "en0" {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            addr = String(cString: host)
        }
        ptr = ptr!.pointee.ifa_next
    }
    freeifaddrs(ifaddr)
    return addr
}
