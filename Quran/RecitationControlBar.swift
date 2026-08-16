import Foundation
import Observation
import SwiftUI

/// Visibility/recording state for the bottom recitation control. Owned by
/// `ContentView` via `@State` and shared with `RecitationControlBar`.
///
/// `isVisible` is purely a chrome-visibility toggle (tapping the page
/// content hides/shows the control) and is orthogonal to `isRecording` -
/// hiding the control never ends a session; only `endRecording()` does.
@Observable
final class RecitationBarState {
    var isVisible = true
    var isExpanded = false

    var isRecording = false
    var isPaused = false
    var elapsed: TimeInterval = 0

    // Mock values until real live-transcription scoring is wired up.
    var accuracy: Int = 100
    var mistakes: Int = 0

    /// Live in-progress Arabic ASR transcript, written to from elsewhere as
    /// recognition results stream in. Purely display data - no logic here.
    var liveTranscript: String = ""

    private var timer: Timer?

    func toggle() { isVisible.toggle() }

    func startRecording() {
        isRecording = true
        isPaused = false
        elapsed = 0
        accuracy = 100
        mistakes = 0
        startTimer()
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused {
            timer?.invalidate()
        } else {
            startTimer()
        }
    }

    func endRecording() {
        isRecording = false
        isPaused = false
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.elapsed += 1
        }
    }

    deinit { timer?.invalidate() }
}

/// Bottom-docked control for live recitation transcription.
///
/// A single `.ultraThinMaterial` shape backs every state - its width,
/// height and corner radius are plain computed properties driven by
/// `state`, so changing them inside `withAnimation` makes the shape itself
/// stretch (circle -> pill -> rounded rectangle) instead of cross-fading
/// between separately-shaped views. Only the content inside cross-fades.
/// Idle tap starts a recording session; the same control then shows
/// elapsed time and live accuracy/mistake stats with quiet pause/Done
/// controls. Tapping the page content anywhere toggles the whole control's
/// visibility - `state.toggle()` - independent of whether a session is in
/// progress.
struct RecitationControlBar: View {
    var state: RecitationBarState
    var onStartReciting: () -> Void
    var onStopReciting: () -> Void

    @State private var pulse = false

    private let idleSize: CGFloat = 56
    private let expandedIdleWidth: CGFloat = 190
    private let recordingWidth: CGFloat = 220
    private let recordingHeight: CGFloat = 150

    private var width: CGFloat {
        if state.isRecording { return recordingWidth }
        return state.isExpanded ? expandedIdleWidth : idleSize
    }

    private var height: CGFloat {
        state.isRecording ? recordingHeight : idleSize
    }

    private var cornerRadius: CGFloat {
        state.isRecording ? 24 : height / 2
    }

    var body: some View {
        if state.isVisible {
            // Both idleContent and recordingContent stay in the tree at all
            // times - only their opacity toggles. Swapping them via if/else
            // instead would replace the whole subtree each time, and mixing
            // that with an ancestor's geometry animation is a known-flaky
            // combo in SwiftUI (particularly on macOS): the ancestor's
            // frame/clipShape change can silently stop animating when its
            // child's view identity changes in the same update. Content is
            // always laid out at its own final/intrinsic size (never the
            // live animating size), so it never reflows mid-animation - the
            // outer frame below is what actually animates, clipping/
            // revealing the fixed-size content underneath as it grows.
            ZStack {
                // Sequenced, not simultaneous: the outgoing piece fades out
                // fast with no delay, the incoming piece fades in slightly
                // scaled-up-from-small after a short delay, so they don't
                // sit on top of each other mid-crossfade (which read as a
                // flat double-exposure ghost rather than one thing becoming
                // another).
                idleContent
                    .opacity(state.isRecording ? 0 : 1)
                    .scaleEffect(state.isRecording ? 0.9 : 1)
                    .allowsHitTesting(!state.isRecording)
                    .animation(
                        state.isRecording
                            ? .easeOut(duration: 0.15)
                            : .easeOut(duration: 0.2).delay(0.15),
                        value: state.isRecording
                    )
                recordingContent
                    .opacity(state.isRecording ? 1 : 0)
                    .scaleEffect(state.isRecording ? 1 : 0.9)
                    .allowsHitTesting(state.isRecording)
                    .animation(
                        state.isRecording
                            ? .easeOut(duration: 0.2).delay(0.15)
                            : .easeOut(duration: 0.15),
                        value: state.isRecording
                    )
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
            // Tied directly to the trigger values, rather than depending on
            // every call site remembering to wrap its mutation in
            // `withAnimation` - guarantees the geometry (and the
            // idle/recording content crossfade riding along with it) always
            // animates however `isRecording`/`isExpanded` end up changing.
            .animation(.spring(response: 0.45, dampingFraction: 0.78), value: state.isRecording)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state.isExpanded)
            .onHover { hovering in
                guard !state.isRecording else { return }
                state.isExpanded = hovering
            }
            .padding(.bottom, 28)
            .onAppear { pulse = true }
        }
    }

    private var idleContent: some View {
        Button {
            onStartReciting()
            state.startRecording()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .medium))
                if state.isExpanded {
                    Text("Start Reciting")
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .foregroundStyle(.primary)
            .frame(width: state.isExpanded ? expandedIdleWidth : idleSize, height: idleSize)
        }
        .buttonStyle(.plain)
    }

    private var recordingContent: some View {
        VStack(spacing: 10) {
            HStack {
                Circle()
                    .fill(state.isPaused ? Color.secondary : Color.green)
                    .frame(width: 8, height: 8)
                    .opacity(state.isPaused ? 0.6 : (pulse ? 1 : 0.4))
                    .animation(
                        state.isPaused ? nil : .easeInOut(duration: 1).repeatForever(autoreverses: true),
                        value: pulse
                    )
                Spacer()
                Text(formattedElapsed)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer()
                Color.clear.frame(width: 8, height: 8)
            }

            Text("\(state.accuracy)% accuracy \u{00B7} \(state.mistakes) spots")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(state.accuracy >= 90 ? Color.green : Color.secondary)

            // Quiet, secondary readout of the in-progress ASR transcript -
            // deliberately small/low-contrast and single-line so it never
            // competes with the accuracy stat above, which stays the primary
            // focus. Right-aligned for Arabic text.
            Text(state.liveTranscript)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .environment(\.layoutDirection, .rightToLeft)

            HStack {
                Button {
                    state.togglePause()
                } label: {
                    Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 13, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state.isPaused)

                Spacer()

                Button("Done") {
                    state.endRecording()
                    onStopReciting()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(width: recordingWidth, height: recordingHeight)
    }

    private var formattedElapsed: String {
        let total = Int(state.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
