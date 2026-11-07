import AppKit
import SwiftUI

enum PermissionGuide: String {
    case input = "Input Monitoring"
    case accessibility = "Accessibility"
}

struct RecordingBar: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let width: CGFloat = 76
    static let height: CGFloat = 30
    var body: some View {
        Group {
            if (model.recording || model.busy) && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                    GlassWaveform(level: model.audioLevel, finishing: model.busy,
                        time: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                // A hidden idle panel must not retain an animation scheduler.
                GlassWaveform(level: model.audioLevel, finishing: model.busy,
                    time: 0, reduceMotion: true)
            }
        }
        .accessibilityLabel(model.busy ? "Finishing dictation" : "Recording")
    }
}

struct GlassWaveform: View {
    let level: Double
    let finishing: Bool
    let time: Double
    var reduceMotion = false
    private let weights = [0.35, 0.72, 1.0, 0.68, 0.32]
    var body: some View {
        HStack(spacing: 4.5) {
            ForEach(0..<5) { index in
                let ripple = reduceMotion ? 0 : sin(time * 2.4 + Double(index) * 0.7)
                let energy = finishing ? 0.15 : max(0.05, min(1, level))
                Capsule()
                    .fill(LinearGradient(colors: [
                        .white.opacity(0.95),
                        Color(red: 0.77, green: 0.91, blue: 0.96).opacity(0.8),
                        Color(red: 0.5, green: 0.72, blue: 0.78).opacity(0.6)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Capsule().stroke(.white.opacity(0.28), lineWidth: 0.5))
                    .frame(width: 2.5, height: 4 + weights[index] * energy * 14 + ripple * 0.7)
                    .opacity(finishing ? 0.64 + ripple * 0.08 : 0.86)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: level)
        .frame(width: RecordingBar.width, height: RecordingBar.height)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Capsule().fill(Color.black.opacity(0.13)))
        .overlay(Capsule().fill(LinearGradient(colors: [
            .white.opacity(0.09), .clear, .black.opacity(0.07)
        ], startPoint: .top, endPoint: .bottom)).allowsHitTesting(false))
        .overlay(Capsule().stroke(LinearGradient(colors: [
            .white.opacity(0.3), .white.opacity(0.05), .white.opacity(0.12)
        ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

struct PermissionGuideView: View {
    @ObservedObject var model: AppModel
    let guide: PermissionGuide
    private var granted: Bool {
        guide == .input ? model.inputAllowed : model.accessibilityAllowed
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(granted ? "\(guide.rawValue) enabled" : guide.rawValue,
                      systemImage: granted ? "checkmark.circle.fill" : "arrow.right.circle.fill")
                    .font(.headline).foregroundStyle(.teal)
                    .padding(8).background(.teal.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                Spacer()
                Button("Done") { model.dismissPermissionGuide() }.controlSize(.small)
            }
            if granted {
                Text(model.needsPermissionRestart ? "Permission granted. Restarting to apply…" :
                    (model.inputAllowed && model.accessibilityAllowed && model.micAllowed ?
                        "All permissions granted. Ready to dictate." : "This permission is enabled. Continue with the remaining permissions."))
                    .font(.callout).foregroundStyle(.teal)
                if guide == .input && !model.accessibilityAllowed {
                    Button("Continue: Accessibility") { model.requestAccessibility() }
                }
            } else { HStack(spacing: 18) {
                DraggableAppIcon().frame(width: 64, height: 64)
                Image(systemName: "arrow.right").foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Drag into the list in System Settings").font(.system(size: 15, weight: .semibold))
                    Text("Then enable Floe").font(.caption).foregroundStyle(.secondary)
                }
            } }
            Text("System Settings → Privacy & Security → \(guide.rawValue)")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Open System Settings") {
                    model.openSettings(guide == .input ? "Privacy_ListenEvent" : "Privacy_Accessibility")
                }
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }.controlSize(.small)
            }
        }.padding(20).frame(width: 370)
    }
}

final class QuietPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
