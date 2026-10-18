import SwiftUI

// Naming what Soughtbot found (Isaac's option B, 2026-10-18). The robot uploads objects without labels (no labeler
// on the robot yet), so Sought asks the person: "Soughtbot found something near the sofa. What is it?" The name is
// saved on this iPhone only, keyed by the object's id; search and find then work on the real object by that name.

struct NameItemsSheet: View {
    let ids: [String]
    @EnvironmentObject private var robot: RobotSource
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var speech = SpeechInput()
    @State private var index = 0
    @State private var name = ""
    @State private var named = 0
    @FocusState private var focused: Bool

    private var queue: [TrackedObject] { ids.compactMap { id in robot.objects.first { $0.id == id } } }
    private var current: TrackedObject? { index < queue.count ? queue[index] : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack {
                    SampleBanner().fixedSize()
                    Spacer()
                    Button("Done") { dismiss() }.font(SoughtFont.bodyMedium).foregroundStyle(p.text).frame(minWidth: 44, minHeight: 44)
                }
                if let item = current {
                    form(item).id(item.id).transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
                } else {
                    finished
                }
            }
            .padding(.horizontal, Space.margin)
            .padding(.vertical, Space.l)
            .animation(reduceMotion ? Motion.fade : Motion.spring, value: index)
        }
        .onChange(of: speech.transcript) { _, t in if !t.isEmpty { name = t } }
    }

    private func form(_ item: TrackedObject) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if queue.count > 1 {
                Text("\(index + 1) of \(queue.count)").font(SoughtFont.readout).foregroundStyle(p.text)
            }
            Text("What is this?").font(SoughtFont.largeTitle).foregroundStyle(p.text).accessibilityAddTraits(.isHeader)
            Text("Soughtbot found something \(item.whereText.lowercased()), \(StatusCopy.ago(item.lastSeen, now: robot.now)).")
                .font(SoughtFont.body).foregroundStyle(p.text)
            if case .jpeg = item.photo {
                ShadedPhoto(photo: item.photo, shadeTo: 0.15, radius: Radius.card).aspectRatio(4 / 3, contentMode: .fit)
            }
            if let map = robot.map { MiniMoveMap(map: map, object: item, from: nil, to: nil) }
            HStack(spacing: Space.s) {
                TextField("", text: $name, prompt: Text("Slippers").foregroundStyle(p.placeholder))
                    .font(SoughtFont.searchHero).foregroundStyle(p.text)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { save(item) }
                    .accessibilityLabel("Name for this item")
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
            Text("The name stays on this iPhone. Search and Find use it from now on.").font(SoughtFont.cardMeta).foregroundStyle(p.text)
            Button { save(item) } label: {
                Text("Save name").font(SoughtFont.button).foregroundStyle(p.onPrimary)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Capsule().fill(canSave ? p.primary : p.primary.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            Button { next() } label: {
                Text(index + 1 < queue.count ? "Skip for now" : "Not now").font(SoughtFont.button).foregroundStyle(p.text)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.plain)
        }
        .onAppear { name = ""; focused = true }
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    private var finished: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(p.found).accessibilityHidden(true)
            Text(named > 0 ? "Named \(named) \(named == 1 ? "item" : "items")" : "All caught up")
                .font(SoughtFont.largeTitle).foregroundStyle(p.text)
            Text("You can search for them by name now.").font(SoughtFont.body).foregroundStyle(p.text)
            Button { dismiss() } label: {
                Text("Done").font(SoughtFont.button).foregroundStyle(p.onPrimary)
                    .frame(maxWidth: .infinity, minHeight: 56).background(Capsule().fill(p.primary))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Space.xxl)
    }

    private func save(_ item: TrackedObject) {
        guard canSave else { return }
        robot.setName(name, for: item.id)
        named += 1
        Haptics.shared.success()
        UIAccessibility.post(notification: .announcement, argument: "Saved as \(name)")
        speech.stop()
        next()
    }

    private func next() {
        name = ""
        index += 1
        if index >= queue.count, named == 0 { dismiss() }
    }
}

/// Home prompt when Soughtbot has found things that need a name.
struct NamePrompt: View {
    @EnvironmentObject private var robot: RobotSource
    @EnvironmentObject private var router: Router
    @Environment(\.palette) private var p

    var body: some View {
        let list = robot.unnamed
        if !list.isEmpty {
            Button { router.nameRequest = list.map(\.id) } label: {
                HStack(spacing: Space.m) {
                    Circle().fill(p.signal).frame(width: 8, height: 8).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(list.count == 1 ? "Soughtbot found something new" : "Soughtbot found \(list.count) new things")
                            .font(SoughtFont.bodyMedium).foregroundStyle(p.text)
                        Text(list.count == 1 ? "\(list[0].whereText). What is it?" : "Tell Sought what they are")
                            .font(SoughtFont.cardMeta).foregroundStyle(p.text)
                    }
                    Spacer(minLength: 0)
                    Text("Name").font(SoughtFont.findIt).foregroundStyle(p.onPrimary)
                        .padding(.horizontal, Space.m).frame(minHeight: 36).background(Capsule().fill(p.call))
                }
                .padding(Space.m)
                .soughtGlass(.activity, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Double tap to name them.")
            .accessibilityIdentifier("namePrompt")
        }
    }
}
