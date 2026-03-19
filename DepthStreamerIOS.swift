import SwiftUI
import ARKit
import SceneKit

// ─── Live camera view ─────────────────────────────────────────────────────────

struct ARCameraView: UIViewRepresentable {
    let streamer: DepthStreamer

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.showsStatistics         = false
        view.automaticallyUpdatesLighting = false
        view.antialiasingMode        = .multisampling4X

        // Tap to focus
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // Compartir sesión ARKit con el streamer
        if streamer.isStreaming {
            uiView.session = streamer.arSession
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(streamer: streamer) }

    final class Coordinator: NSObject {
        let streamer: DepthStreamer
        init(streamer: DepthStreamer) { self.streamer = streamer }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            let pt = gesture.location(in: view)
            let normalized = CGPoint(x: pt.x / view.bounds.width,
                                     y: pt.y / view.bounds.height)
            Task { @MainActor in
                self.streamer.tapFocus(at: normalized)
            }
        }
    }
}

// ─── Focus indicator ──────────────────────────────────────────────────────────

struct FocusRing: View {
    @Binding var position: CGPoint
    @Binding var visible: Bool

    var body: some View {
        if visible {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.yellow, lineWidth: 1.5)
                .frame(width: 70, height: 70)
                .position(position)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.2), value: visible)
        }
    }
}

// ─── Stat badge ───────────────────────────────────────────────────────────────

struct StatBadge: View {
    let label: String
    let value: String
    var valueColor: Color = .white

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundColor(valueColor)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
    }
}

// ─── Main ContentView ─────────────────────────────────────────────────────────

struct ContentView: View {
    @State private var streamer      = DepthStreamer()
    @State private var focusPos      = CGPoint.zero
    @State private var focusVisible  = false
    @State private var showURLSheet  = false

    var body: some View {
        ZStack {
            // ── Live camera ───────────────────────────────────────────────────
            ARCameraView(streamer: streamer)
                .ignoresSafeArea()
                .onTapGesture { loc in
                    focusPos     = loc
                    focusVisible = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        focusVisible = false
                    }
                }

            // ── Focus ring ────────────────────────────────────────────────────
            FocusRing(position: $focusPos, visible: $focusVisible)

            // ── Error banner ──────────────────────────────────────────────────
            if let err = streamer.errorMessage {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.white)
                        Spacer()
                        Button("Reintentar") { streamer.restart() }
                            .font(.caption.bold())
                            .foregroundColor(.yellow)
                    }
                    .padding(12)
                    .background(Color.red.opacity(0.85))
                    .cornerRadius(10)
                    .padding(.horizontal)
                    Spacer()
                }
                .padding(.top, 60)
            }

            VStack {
                // ── Top stats bar ─────────────────────────────────────────────
                HStack(spacing: 8) {
                    // Status dot + IP
                    Button { showURLSheet = true } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(streamer.isStreaming ? .green : .red)
                                .frame(width: 8, height: 8)
                            if let ip = streamer.localIP {
                                Text(":\(8080)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.cyan)
                            }
                            Image(systemName: "info.circle")
                                .font(.caption2)
                                .foregroundColor(.cyan)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                    }

                    Spacer()

                    // Stats
                    StatBadge(label: "FPS",
                              value: String(format: "%.0f", streamer.fps),
                              valueColor: fpsColor)
                    StatBadge(label: "RGB", value: streamer.resolution)
                    StatBadge(label: "Depth", value: streamer.depthRes, valueColor: .orange)
                    StatBadge(label: "Clients",
                              value: "\(streamer.clientCount)",
                              valueColor: streamer.clientCount > 0 ? .green : .gray)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                Spacer()

                // ── Bottom controls ───────────────────────────────────────────
                HStack(spacing: 20) {
                    // Frames counter
                    VStack(spacing: 2) {
                        Text("\(streamer.frameCount)")
                            .font(.system(.caption, design: .monospaced).bold())
                            .foregroundColor(.white)
                        Text("frames")
                            .font(.system(size: 9))
                            .foregroundColor(.gray)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)

                    Spacer()

                    // Start / Stop
                    Button {
                        streamer.isStreaming ? streamer.stop() : streamer.start()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: streamer.isStreaming
                                  ? "stop.circle.fill" : "play.circle.fill")
                            Text(streamer.isStreaming ? "Detener" : "Iniciar")
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(streamer.isStreaming ? Color.red : Color.green)
                        .cornerRadius(12)
                    }

                    Spacer()

                    // Restart button
                    Button { streamer.restart() } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding(10)
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
        }
        // ── URL Sheet ─────────────────────────────────────────────────────────
        .sheet(isPresented: $showURLSheet) {
            URLSheet(streamer: streamer)
                .presentationDetents([.medium])
        }
        .onAppear  { streamer.start() }
        .onDisappear { streamer.stop() }
        // Mantener pantalla activa
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var fpsColor: Color {
        switch streamer.fps {
        case 12...: return .green
        case 8...:   return .yellow
        default:    return .red
        }
    }
}

// ─── URL Sheet ────────────────────────────────────────────────────────────────

struct URLSheet: View {
    let streamer: DepthStreamer
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            List {
                if let ip = streamer.localIP {
                    Section("Conectar desde Python / OpenCV") {
                        URLRow(label: "Video (MJPEG)",
                               url: "http://\(ip):8080/video",
                               color: .cyan)
                        URLRow(label: "Profundidad LiDAR",
                               url: "http://\(ip):8080/depth",
                               color: .orange)
                        URLRow(label: "Status",
                               url: "http://\(ip):8080/",
                               color: .gray)
                    }

                    Section("Comando Python") {
                        Text("cv2.VideoCapture(\n  \"http://\(ip):8080/video\"\n)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.green)
                            .textSelection(.enabled)
                    }
                }

                Section("Info") {
                    LabeledContent("FPS actual",    value: String(format: "%.1f", streamer.fps))
                    LabeledContent("Resolución RGB", value: streamer.resolution)
                    LabeledContent("Resolución depth", value: streamer.depthRes)
                    LabeledContent("Frames totales", value: "\(streamer.frameCount)")
                    LabeledContent("Clientes",       value: "\(streamer.clientCount)")
                }
            }
            .navigationTitle("DepthStreamer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }
}

struct URLRow: View {
    let label: String
    let url:   String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
            Text(url)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(color)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}
