import SwiftUI

/// Root screen: a speak-or-type find bar. Large controls, VoiceOver labels, Dynamic Type friendly.
struct FindBarView: View {
    @ObservedObject var model: FindBarViewModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Text("What should I find?")
                .font(.largeTitle.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 12) {
                TextField("Find my keys, go to the kitchen…", text: $model.text)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .frame(minHeight: 56)
                    .submitLabel(.go)
                    .focused($fieldFocused)
                    .onSubmit { model.submitText() }
                    .accessibilityLabel("Find bar")
                    .accessibilityHint("Type what to find or where to go, then press Go")
                Button { fieldFocused = false; model.submitText() } label: {
                    Text("Go").font(.title2.bold()).frame(minWidth: 64, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.text.trimmingCharacters(in: .whitespaces).isEmpty || model.state == .listening)
                .accessibilityLabel("Go")
                .accessibilityHint("Sends the typed request")
            }

            if model.canTalk {
                Button { fieldFocused = false; Task { await model.toggleListening() } } label: {
                    VStack(spacing: 6) {
                        Image(systemName: model.state == .listening ? "waveform.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 64))
                        Text(model.state == .listening ? "Tap to send" : "Talk").font(.title2.bold())
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.state == .listening ? .orange : .blue)
                .disabled(model.isBusy)
                .accessibilityLabel(model.state == .listening ? "Stop listening and send" : "Talk")
                .accessibilityHint("Tap, say what to find, then tap again to send. The robot must be stopped.")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(model.statusLine)
                    .font(.title3)
                    .foregroundStyle(isError ? Color.red : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Status: \(model.statusLine)")
                if let last = model.lastToolCall {
                    Text("Last action: \(last)")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Last action: \(last)")
                }
            }
            .accessibilityElement(children: .contain)

            Spacer(minLength: 0)

            Button { model.stop() } label: {
                Text("STOP").font(.system(size: 40, weight: .heavy)).foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 88)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 16))
            }
            .accessibilityLabel("Stop the rover now")
        }
        .padding()
    }

    private var isError: Bool {
        if case .error = model.state { return true }
        return false
    }
}
