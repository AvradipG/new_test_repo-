import AVFoundation
import Speech
import SwiftData
import SwiftUI
import TidyCore

/// Which tab is showing and which room to open, so the voice assistant can take the owner somewhere.
@MainActor
final class AppRouter: ObservableObject {
    @Published var tab = 0
    @Published var openRoomID: UUID?
    @Published var focusRoomID: UUID?
    /// A share file someone sent, waiting to be added.
    @Published var incomingShare: IncomingShare?
    /// The room on screen right now ("call this room Studio").
    var currentRoomID: UUID?

    func open(_ room: Room) {
        tab = 0
        openRoomID = room.uid
    }

    func focus(_ room: Room) {
        tab = 0
        focusRoomID = room.uid
    }
}

/// Spoken replies (kept alive after the assistant sheet closes).
@MainActor
enum Speaker {
    static let synth = AVSpeechSynthesizer()
    static let enabledKey = "voice.speakReplies"

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    static func say(_ text: String) {
        guard enabled, !text.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first)
        synth.speak(u)
    }

    static func stop() { synth.stopSpeaking(at: .immediate) }
}

/// Push-to-talk speech recognition, on the iPhone itself when the language supports it.
@MainActor
final class VoiceListener: ObservableObject {
    @Published var transcript = ""
    @Published var listening = false
    @Published var problem: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    func start() async {
        problem = nil
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else {
            problem = "Allow Speech Recognition for Tidy Atlas (Settings › Privacy & Security › Speech Recognition), or type below."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            problem = "Allow the microphone for Tidy Atlas in Settings, or type below."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition isn't available right now. Type below instead."
            return
        }
        Speaker.stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            request = req
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(req))
            engine.prepare()
            try engine.start()
            transcript = ""
            listening = true
            task = recognizer.recognitionTask(with: req, resultHandler: Self.handler { [weak self] text, done in
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if done { self.stopAudio() }
                }
            })
        } catch {
            problem = "Couldn't start listening: \(error.localizedDescription)"
            stopAudio()
        }
    }

    // Made outside the main actor: iOS calls these on its audio and speech threads.
    nonisolated private static func tap(_ req: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in req.append(buffer) }
    }

    nonisolated private static func handler(_ update: @escaping @Sendable (String?, Bool) -> Void)
        -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in update(result?.bestTranscription.formattedString, (result?.isFinal ?? false) || error != nil) }
    }

    /// Stops listening and returns what was heard.
    func stop() async -> String {
        request?.endAudio()
        stopAudio()
        try? await Task.sleep(for: .milliseconds(500))
        task?.cancel()
        task = nil
        request = nil
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        listening = false
    }
}

/// The mic button in the top bar of the main screens.
struct AssistantButton: View {
    @State private var show = false

    var body: some View {
        Button { show = true } label: { Image(systemName: "mic.circle.fill").font(.title2) }
            .accessibilityLabel("Talk to Tidy Atlas")
            .sheet(isPresented: $show) { AssistantSheet() }
    }
}

/// Talk (or type) to the app: "take me to the kitchen", "where's my passport?", "I put the charger away",
/// "call this room Studio", "remember the keys go on the hook", "what should I do next?".
struct AssistantSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var organizer: Organizer
    @EnvironmentObject private var router: AppRouter
    @StateObject private var voice = VoiceListener()
    @State private var typed = ""
    @State private var turns: [Turn] = []
    @State private var working = false
    @AppStorage("voice.speakReplies") private var speak = true

    struct Turn: Identifiable {
        let id = UUID()
        var said: String
        var reply: String
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if turns.isEmpty { examples }
                        ForEach(turns) { t in
                            Text(t.said).padding(10).background(Palette.tint, in: RoundedRectangle(cornerRadius: 12))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(t.reply).padding(10).background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal)
                }
                if voice.listening || !voice.transcript.isEmpty {
                    Text(voice.transcript.isEmpty ? "Listening…" : voice.transcript)
                        .font(.title3).multilineTextAlignment(.center).padding(.horizontal)
                }
                if let p = voice.problem { Text(p).font(.footnote).foregroundStyle(.orange).padding(.horizontal) }
                if !KeyStore.hasKey {
                    Text("Add a Claude or ChatGPT key in Settings so the assistant can understand you.")
                        .font(.footnote).foregroundStyle(.orange).padding(.horizontal)
                }
                micButton
                HStack {
                    TextField("Or type here", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit { send(typed) }
                    Button { send(typed) } label: { Image(systemName: "paperplane.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty || working)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle("Talk to Tidy Atlas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Toggle(isOn: $speak) { Image(systemName: speak ? "speaker.wave.2.fill" : "speaker.slash") }
                        .toggleStyle(.button)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .background(Palette.paper)
        }
        .presentationDetents([.medium, .large])
    }

    private var micButton: some View {
        Button {
            Task {
                if voice.listening {
                    let heard = await voice.stop()
                    send(heard)
                } else {
                    await voice.start()
                }
            }
        } label: {
            ZStack {
                Circle().fill(voice.listening ? Color.red : Palette.teal).frame(width: 84, height: 84)
                if working {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: voice.listening ? "stop.fill" : "mic.fill").font(.largeTitle).foregroundStyle(.white)
                }
            }
        }
        .disabled(working)
        .accessibilityLabel(voice.listening ? "Stop and send" : "Start talking")
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tap the mic, talk, tap again.").font(.headline)
            ForEach(["“Take me to the kitchen”", "“Where's my passport?”", "“I put the charger away”",
                     "“Call this room Studio”", "“Remember the keys go on the hook”", "“What should I do next?”"], id: \.self) {
                Text($0).foregroundStyle(.secondary)
            }
            Text("Claude or ChatGPT understands what you say, using everything the app remembers. Speech is turned into text on this iPhone where possible. iOS doesn't let apps recognise whose voice it is, so it treats whoever talks as you.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }
        .padding(.vertical)
    }

    private func send(_ text: String) {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, !working else { return }
        typed = ""
        guard KeyStore.hasKey else {
            turns.append(Turn(said: said, reply: "I need a Claude or ChatGPT key first. Add one in Settings."))
            return
        }
        working = true
        Task {
            defer { working = false }
            do {
                let o = try await organizer.assistant(said, currentRoomID: router.currentRoomID, context: context)
                turns.append(Turn(said: said, reply: o.reply))
                voice.transcript = ""
                if speak { Speaker.say(o.reply) }
                if let r = o.focusRoom {
                    dismiss()
                    router.focus(r)
                } else if let r = o.openRoom {
                    dismiss()
                    router.open(r)
                }
            } catch {
                turns.append(Turn(said: said, reply: "That didn't work: \(error.localizedDescription)"))
            }
        }
    }
}
