import SwiftData
import SwiftUI
import TidyCore

/// One step on screen, a gentle timer, big buttons. Built for ADHD: no list to get lost in.
struct FocusView: View {
    let room: Room
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var organizer: Organizer
    @State private var doneThisSession = 0
    @State private var sessionTotal = 0
    @State private var cheer: String?
    @State private var elapsed = 0
    @State private var running = true
    @State private var stepID: UUID?
    @State private var errorText: String?

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let step = room.todoSteps.first
        VStack(spacing: 24) {
            HStack {
                Text(room.name).font(.headline).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 5) {
                    ForEach(0..<min(max(sessionTotal, doneThisSession), 20), id: \.self) { i in
                        Circle().fill(i < doneThisSession ? Color.green : Color.secondary.opacity(0.25)).frame(width: 9, height: 9)
                    }
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title) }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Leave focus mode")
            }

            Spacer(minLength: 0)
            if let step {
                VStack(spacing: 18) {
                    Text("Just this one thing" + (step.trip > 1 ? " · trip \(step.trip)" : ""))
                        .font(.footnote.weight(.bold)).textCase(.uppercase).foregroundStyle(Palette.teal)
                    Text(step.title)
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                    if !step.detail.isEmpty {
                        Text(step.detail).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if let id = step.itemID, let item = room.items.first(where: { $0.uid == id }) {
                        HStack(spacing: 12) {
                            ItemThumb(file: item.thumbFile, category: item.category, size: 64)
                            VStack(alignment: .leading) {
                                Text(item.name).font(.headline)
                                Text(room.zone(item.suggestedZoneID).map { "→ \($0.name)" } ?? item.reason)
                                    .font(.callout.weight(.semibold)).foregroundStyle(Palette.teal)
                            }
                        }
                        .card()
                    }
                    timer(minutes: step.minutes)
                }
                .id(step.uid)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                Spacer(minLength: 0)
                VStack(spacing: 12) {
                    Button {
                        withAnimation(.spring) { organizer.complete(step, in: room, context: context) }
                        doneThisSession += 1
                        cheer = Cheers.all.randomElement()
                    } label: {
                        Label("Done", systemImage: "checkmark").font(.title2.weight(.bold)).frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    HStack {
                        Button {
                            withAnimation { organizer.skip(step, context: context) }
                        } label: { Label("Skip", systemImage: "forward.fill").frame(maxWidth: .infinity) }
                        Button {
                            Task {
                                do { _ = try await organizer.breakDown(step, in: room, context: context) }
                                catch { errorText = error.localizedDescription }
                            }
                        } label: {
                            HStack {
                                if organizer.busy { ProgressView() } else { Image(systemName: "scissors") }
                                Text("Too big?")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(organizer.busy)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "party.popper.fill").font(.system(size: 60)).foregroundStyle(.green)
                    Text(doneThisSession > 0 ? "You did it!" : "No steps waiting").font(.display(.largeTitle))
                    Text(doneThisSession > 0
                         ? "\(doneThisSession) step\(doneThisSession == 1 ? "" : "s") done. Take a breath, you earned it."
                         : "Make a plan for this room first, then come back here.")
                        .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Back to \(room.name)") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(24)
        .background(Palette.paper.ignoresSafeArea())
        .overlay(alignment: .top) {
            if let cheer {
                Label(cheer, systemImage: "sparkles")
                    .font(.display(.title3))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    .background(Color.green, in: Capsule())
                    .shadow(radius: 10)
                    .padding(.top, 70)
                    .transition(.scale.combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(1.6))
                        withAnimation { self.cheer = nil }
                    }
            }
        }
        .animation(.spring, value: cheer)
        .onAppear { sessionTotal = room.todoSteps.count }
        .onReceive(tick) { _ in
            if room.todoSteps.first?.uid != stepID {
                stepID = room.todoSteps.first?.uid
                elapsed = 0
                running = true
            } else if running {
                elapsed += 1
            }
        }
        .onChange(of: room.todoSteps.count) { _, n in sessionTotal = max(sessionTotal, doneThisSession + n) }
        .alert("Couldn't split that step", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func timer(minutes: Int) -> some View {
        let total = max(1, minutes * 60)
        let over = elapsed >= total
        let shown = over ? elapsed - total : total - elapsed
        return Button { running.toggle() } label: {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: min(1, Double(elapsed) / Double(total)))
                    .stroke(over ? Color.orange : Palette.teal, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: elapsed)
                VStack(spacing: 2) {
                    Text((over ? "+" : "") + String(format: "%d:%02d", shown / 60, shown % 60))
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    Image(systemName: running ? "pause.fill" : "play.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, height: 140)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(running ? "Pause timer" : "Resume timer")
        .overlay(alignment: .bottom) {
            if over {
                Text("Time's up. Finish it or skip it, both are fine.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize().offset(y: 26)
            }
        }
    }
}
