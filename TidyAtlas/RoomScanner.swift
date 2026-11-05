import RoomPlan
import SwiftUI
import TidyCore
import simd

/// LiDAR room scan with Apple RoomPlan: walls give the real room size, furniture becomes storage zones.
enum RoomScanSupport {
    static var isAvailable: Bool { RoomCaptureSession.isSupported }

    static func box(_ transform: simd_float4x4, _ dims: simd_float3, label: String) -> WorldBox {
        let c0 = transform.columns.0
        let p = transform.columns.3
        return WorldBox(cx: Double(p.x), cy: Double(p.y), cz: Double(p.z),
                        width: Double(dims.x), height: Double(dims.y), depth: Double(dims.z),
                        yaw: Double(atan2(-c0.z, c0.x)), label: label)
    }

    static func layout(of room: CapturedRoom) -> RoomLayout? {
        let walls = room.walls.map { box($0.transform, $0.dimensions, label: "wall") }
        let objects = room.objects.map { box($0.transform, $0.dimensions, label: String(describing: $0.category)) }
        return RoomLayout.from(walls: walls, objects: objects)
    }
}

struct RoomScanSheet: View {
    var onFinish: (CapturedRoom) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var stop = false
    @State private var result: CapturedRoom?

    var body: some View {
        ZStack(alignment: .bottom) {
            RoomCaptureRepresentable(stop: stop) { result = $0 }
                .ignoresSafeArea()
            VStack(spacing: 12) {
                if result == nil {
                    Text(stop ? "Putting the room together…" : "Walk slowly around the edges of the room. Point at the walls, then the furniture.")
                        .font(.callout.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                HStack {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                    if let result {
                        Button {
                            onFinish(result)
                            dismiss()
                        } label: {
                            Label("Use this scan", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            stop = true
                        } label: {
                            Label("Done scanning", systemImage: "stop.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(stop)
                    }
                }
                .controlSize(.large)
            }
            .padding()
        }
    }
}

struct RoomCaptureRepresentable: UIViewRepresentable {
    var stop: Bool
    var onResult: (CapturedRoom) -> Void

    func makeCoordinator() -> RoomCaptureCoordinator { RoomCaptureCoordinator(onResult: onResult) }

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        view.delegate = context.coordinator
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
        return view
    }

    func updateUIView(_ view: RoomCaptureView, context: Context) {
        if stop && !context.coordinator.stopped {
            context.coordinator.stopped = true
            view.captureSession.stop()
        }
    }

    static func dismantleUIView(_ view: RoomCaptureView, coordinator: RoomCaptureCoordinator) {
        if !coordinator.stopped { view.captureSession.stop() }
    }
}

/// Top-level with a fixed Objective-C name: RoomCaptureViewDelegate inherits NSCoding, which needs a stable class name.
@objc(TARoomCaptureCoordinator)
final class RoomCaptureCoordinator: NSObject, RoomCaptureViewDelegate {
    var onResult: (CapturedRoom) -> Void
    var stopped = false

    init(onResult: @escaping (CapturedRoom) -> Void) {
        self.onResult = onResult
        super.init()
    }

    // RoomCaptureViewDelegate inherits NSCoding; the coordinator is never archived.
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {}

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool { true }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        DispatchQueue.main.async { self.onResult(processedResult) }
    }
}
