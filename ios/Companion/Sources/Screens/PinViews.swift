import PhotosUI
import SwiftUI

// Pin placement and naming (Isaac's pins, approved 2026-10-17).

struct PinSpot: Identifiable, Equatable {
    var id: String { "\(x),\(z)" }
    var x: Double
    var z: Double
    var place: String
    var room: String?
}

/// Fixed ring in the middle of the map while placing a pin; the person moves the map under it.
struct PlacementRing: View {
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle().fill(p.call.opacity(0.12)).frame(width: 46, height: 46)
                .scaleEffect(breathe ? 1.08 : 0.94)
            Circle().strokeBorder(p.call, style: StrokeStyle(lineWidth: 2, dash: [5, 4])).frame(width: 46, height: 46)
            Path { path in
                path.move(to: CGPoint(x: 23, y: 4)); path.addLine(to: CGPoint(x: 23, y: 14))
                path.move(to: CGPoint(x: 23, y: 32)); path.addLine(to: CGPoint(x: 23, y: 42))
                path.move(to: CGPoint(x: 4, y: 23)); path.addLine(to: CGPoint(x: 14, y: 23))
                path.move(to: CGPoint(x: 32, y: 23)); path.addLine(to: CGPoint(x: 42, y: 23))
            }
            .stroke(p.call, lineWidth: 2).frame(width: 46, height: 46)
            Circle().fill(p.call).frame(width: 5, height: 5)
        }
        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 1.2).repeatForever()) { breathe = true } } }
        .accessibilityHidden(true)
    }
}

struct PinEditor: View {
    let spot: PinSpot
    let initialName: String
    var onSave: (UserPin) -> Void
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speech = SpeechInput()
    @State private var name = ""
    @State private var note = ""
    @State private var pick: PhotosPickerItem?
    @State private var photo: Data?
    @FocusState private var nameFocused: Bool

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack {
                    Button("Cancel") { dismiss() }.font(SoughtFont.body).foregroundStyle(p.text).frame(minHeight: 44)
                    Spacer()
                }
                Text("What did you leave here?").font(SoughtFont.largeTitle).foregroundStyle(p.text).accessibilityAddTraits(.isHeader)

                HStack(spacing: Space.s) {
                    TextField("", text: $name, prompt: Text("TV remote").foregroundStyle(p.placeholder))
                        .font(SoughtFont.searchHero).foregroundStyle(p.text)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .accessibilityLabel("Name of the item")
                    Button {
                        if speech.isListening { speech.stop() } else { speech.start() }
                    } label: {
                        Image("icon_mic").renderingMode(.template)
                            .foregroundStyle(speech.isListening ? p.onPrimary : p.text)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(speech.isListening ? p.call : p.micFill))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(speech.isListening ? "Stop listening" : "Say the name")
                }
                .padding(.leading, Space.l).padding(.trailing, 6)
                .frame(minHeight: 56)
                .soughtGlass(.search, in: Capsule())

                HStack(spacing: 6) {
                    UserPinMarker().scaleEffect(0.7).frame(width: 16, height: 20)
                    Text(spot.place + (spot.room.map { " · \($0)" } ?? "")).font(SoughtFont.body).foregroundStyle(p.text)
                }
                .accessibilityElement(children: .combine)

                Text("Note (optional)").font(SoughtFont.activityHeading).foregroundStyle(p.text)
                TextField("", text: $note, prompt: Text("Under the blue cushion").foregroundStyle(p.placeholder), axis: .vertical)
                    .font(SoughtFont.body).foregroundStyle(p.text)
                    .lineLimit(1...3)
                    .padding(Space.m)
                    .soughtGlass(.search, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    .accessibilityLabel("Note")

                PhotosPicker(selection: $pick, matching: .images) {
                    Group {
                        if let photo, let ui = UIImage(data: photo) {
                            Image(uiImage: ui).resizable().scaledToFill().frame(height: 140)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                                .overlay(alignment: .bottomTrailing) {
                                    Text("Change photo").font(SoughtFont.findIt).foregroundStyle(p.onPrimary)
                                        .padding(.horizontal, Space.s).padding(.vertical, 4)
                                        .background(Capsule().fill(p.primary)).padding(Space.s)
                                }
                        } else {
                            Label("Add a photo", systemImage: "plus").font(SoughtFont.bodyMedium).foregroundStyle(p.text)
                                .frame(maxWidth: .infinity, minHeight: 64)
                                .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                                    .strokeBorder(p.text.opacity(0.45), style: StrokeStyle(lineWidth: 1.4, dash: [5, 4])))
                        }
                    }
                }
                .accessibilityLabel(photo == nil ? "Add a photo, optional" : "Change photo")

                Text("Pins stay on this iPhone. Soughtbot does not check them, so Sought shows how old each pin is.")
                    .font(SoughtFont.cardMeta).foregroundStyle(p.text)

                Button {
                    let pin = UserPin(id: "pin_\(UUID().uuidString.prefix(10).lowercased())",
                                      label: name.trimmingCharacters(in: .whitespaces).capitalizedFirst,
                                      note: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note,
                                      x: spot.x, z: spot.z, place: spot.place, room: spot.room, createdAt: Date(), photo: photo)
                    Haptics.shared.success()
                    onSave(pin)
                    dismiss()
                } label: {
                    Text("Save pin").font(SoughtFont.button).foregroundStyle(p.onPrimary)
                        .frame(maxWidth: .infinity, minHeight: 56).background(Capsule().fill(canSave ? p.primary : p.primary.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }
            .padding(Space.margin)
        }
        .background(SoughtBackground())
        .onAppear {
            name = initialName
            if initialName.isEmpty { nameFocused = true }
        }
        .onChange(of: speech.transcript) { _, t in if !t.isEmpty { name = t } }
        .onChange(of: pick) { _, item in
            Task {
                if let d = try? await item?.loadTransferable(type: Data.self), let ui = UIImage(data: d) { photo = PinStore.jpeg(from: ui) }
            }
        }
    }
}
