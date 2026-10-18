import SwiftUI

// Shared Sought components (plan section 6.4). Sizes and colors follow the Figma Home hi-fi and Item Log frames.

// MARK: - Photos

struct PhotoView: View {
    let photo: PhotoRef
    @Environment(\.palette) private var p

    var body: some View {
        switch photo {
        case let .asset(name): Image(name).resizable().scaledToFill()
        case let .jpeg(data):
            if let ui = UIImage(data: data) { Image(uiImage: ui).resizable().scaledToFill() } else { placeholder }
        case .none: placeholder
        }
    }

    private var placeholder: some View {
        ZStack { p.surface; Image(systemName: "photo").font(.title2).foregroundStyle(p.text.opacity(0.5)) }
    }
}

/// Photo with the Figma bottom shade (night at the bottom fading out by about a third of the height).
struct ShadedPhoto: View {
    let photo: PhotoRef
    var shadeTo: Double = 0.31
    var radius: CGFloat = Radius.photo
    @Environment(\.palette) private var p

    var body: some View {
        Color.clear
            .overlay(PhotoView(photo: photo))
            .overlay(LinearGradient(stops: [.init(color: p.photoShade, location: 0.02),
                                            .init(color: Color(hex: 0x39738A, alpha: 0.13), location: shadeTo),
                                            .init(color: .clear, location: 1)],
                                    startPoint: .bottom, endPoint: .top))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Status line and header

struct BatteryGlyph: View {
    let level: Double?
    @Environment(\.palette) private var p

    var body: some View {
        let l = max(0, min(1, level ?? 0))
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).stroke(p.text, lineWidth: 1.2).frame(width: 14, height: 8)
            RoundedRectangle(cornerRadius: 1).fill(l < 0.2 ? p.alert : p.found).frame(width: 12 * l, height: 6).padding(.leading, 1)
            Rectangle().fill(p.text).frame(width: 1.5, height: 3).offset(x: 14.5)
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

struct StatusLine: View {
    var singleLine = false
    @EnvironmentObject private var robot: RobotSource
    @Environment(\.palette) private var p

    var body: some View {
        let online = robot.status.isOnline(now: robot.now)
        HStack(alignment: .center, spacing: 6) {
            if robot.status.state != .idle && online {
                Circle().fill(p.signal).frame(width: 6, height: 6).accessibilityHidden(true)
            }
            Text(StatusCopy.line(robot.status, now: robot.now))
                .contentTransition(.interpolate)
                .animation(Motion.fade, value: StatusCopy.line(robot.status, now: robot.now))
                .font(SoughtFont.status)
                .foregroundStyle(p.text)
                .lineLimit(singleLine ? 1 : 3)
                .fixedSize(horizontal: singleLine, vertical: false)
                .multilineTextAlignment(singleLine ? .trailing : .leading)
            if online, robot.status.battery != nil { BatteryGlyph(level: robot.status.battery) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StatusCopy.spoken(robot.status, now: robot.now))
        .accessibilityIdentifier("statusLine")
    }
}

struct ScreenHeader: View {
    let title: String
    @Environment(\.palette) private var p

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                titleText
                Spacer(minLength: Space.s)
                StatusPill()
            }
            VStack(alignment: .leading, spacing: Space.xs) { titleText; StatusPill(singleLine: false) }
        }
    }

    private var titleText: some View {
        Text(title).font(SoughtFont.screenTitle).foregroundStyle(p.title).accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Search and mic

struct SearchBar: View {
    @Binding var text: String
    var placeholder: String
    var hero = false
    /// Zoom source id for the find flow this search opens ("search-home", "search-items").
    var heroKey: String? = nil
    var onSubmit: (String) -> Void
    @EnvironmentObject private var router: Router
    @StateObject private var speech = SpeechInput()
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    /// One glass capsule: magnifier, field, and the mic attached at the trailing end.
    var body: some View {
        let height: CGFloat = hero ? 56 : 48
        HStack(spacing: Space.s) {
            Image("icon_search").renderingMode(.template).resizable().frame(width: 16, height: 16)
                .foregroundStyle(p.text).accessibilityHidden(true)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(p.placeholder))
                .font(hero ? SoughtFont.searchHero : SoughtFont.search)
                .foregroundStyle(p.text)
                .submitLabel(.search)
                .focused($focused)
                .onSubmit { submit() }
                .frame(minHeight: 44)
                .accessibilityLabel("Search for an item")
                .accessibilityHint("Type what you are looking for, then search.")
                .accessibilityIdentifier("searchField")
            Button {
                Haptics.shared.tap()
                if speech.isListening { speech.stop() } else { speech.start() }
            } label: {
                Image("icon_mic").renderingMode(.template)
                    .foregroundStyle(speech.isListening ? p.onPrimary : p.text)
                    .frame(width: height - 12, height: height - 12)
                    .background(Circle().fill(speech.isListening ? p.call : p.micFill))
                    .overlay(Circle().stroke(p.signal, lineWidth: speech.isListening ? 2 : 0))
                    .scaleEffect(speech.isListening && !reduceMotion ? 1.06 : 1)
                    .animation(Motion.spring, value: speech.isListening)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(speech.isListening ? "Stop listening" : "Speak to search")
            .accessibilityIdentifier("micButton")
        }
        .padding(.leading, Space.l)
        .padding(.trailing, 6)
        .frame(minHeight: height)
        .soughtGlass(.search, in: Capsule())
        .modifier(OptionalHero(id: heroKey))
        .onChange(of: speech.transcript) { _, t in if !t.isEmpty { text = t } }
        .onChange(of: speech.isListening) { was, now in
            if was && !now && !speech.transcript.isEmpty { submit() }
        }
        .overlay(alignment: .bottomLeading) {
            if let e = speech.errorText {
                Text(e).font(SoughtFont.cardMeta).foregroundStyle(p.alert).offset(y: 22)
            }
        }
    }

    private func submit() {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        focused = false
        router.pendingHero = heroKey
        onSubmit(q)
    }
}

// MARK: - Item card and row

struct FindItButton: View {
    let action: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Image("icon_search").renderingMode(.template).resizable().frame(width: 12, height: 12)
                Text("Find it").font(SoughtFont.findIt)
            }
            .foregroundStyle(p.onPrimary)
            .frame(maxWidth: .infinity, minHeight: 22)
            .background(Capsule().fill(p.primary))
            .padding(.vertical, 11)          // 44 pt tap target around the 22 pt pill
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -11)
    }
}

struct ItemCard: View {
    let item: TrackedObject
    var width: CGFloat = 169
    /// Where this card lives ("home", a row title), so its zoom source id is unique on screen.
    var heroPrefix = "card"
    var onFind: (TrackedObject) -> Void
    var onOpen: (TrackedObject) -> Void
    @EnvironmentObject private var robot: RobotSource
    @EnvironmentObject private var router: Router
    @Environment(\.dynamicTypeSize) private var dts
    private var heroKey: String { "\(heroPrefix)-\(item.id)" }
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button { router.pendingHero = heroKey; onOpen(item) } label: {
                ItemPhoto(item: item).frame(width: width, height: width * 141 / 169)
                    .heroSource(heroKey)
                    .softShadow()
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(item.label).font(SoughtFont.cardTitle).foregroundStyle(p.text).lineLimit(dts.isAccessibilitySize ? 4 : 2)
                Text(item.isPin ? "\(item.whereText) · pinned \(StatusCopy.ago(item.lastSeen, now: robot.now))"
                                : "\(item.whereText): \(StatusCopy.ago(item.lastSeen, now: robot.now))")
                    .font(SoughtFont.cardMeta).foregroundStyle(p.text).lineLimit(dts.isAccessibilitySize ? 5 : 2)
                FindItButton { router.pendingHero = heroKey; onFind(item) }.padding(.top, Space.xs)
            }
            .frame(width: width - 11, alignment: .leading)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.label), \(item.whereText.lowercased()), seen \(StatusCopy.agoSpoken(item.lastSeen, now: robot.now)).")
        .accessibilityHint("Double tap to find. Swipe up or down for more.")
        .accessibilityAction { onFind(item) }
        .accessibilityAction(named: "Find it") { onFind(item) }
        .accessibilityAction(named: "Details") { onOpen(item) }
        .accessibilityIdentifier("item-\(item.id)")
    }
}

/// Card width that grows with text size so names and places do not truncate.
func itemCardWidth(_ dts: DynamicTypeSize, base: CGFloat = 169) -> CGFloat {
    if dts.isAccessibilitySize { return 280 }
    if dts >= .xxxLarge { return max(base, 200) }
    return base
}

struct ItemRow: View {
    let title: String
    let items: [TrackedObject]
    var banded = false
    var emptyText = "Nothing here yet"
    var onFind: (TrackedObject) -> Void
    var onOpen: (TrackedObject) -> Void
    @Environment(\.palette) private var p
    @Environment(\.dynamicTypeSize) private var dts

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title).font(SoughtFont.sectionTitle).foregroundStyle(p.sectionTitle)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel("\(title), \(items.count) \(items.count == 1 ? "item" : "items")")
                .padding(.horizontal, Space.margin)
            if items.isEmpty {
                Text(emptyText).font(SoughtFont.body).foregroundStyle(p.text).padding(.horizontal, Space.margin)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Space.l) {
                        ForEach(items) { ItemCard(item: $0, width: itemCardWidth(dts), heroPrefix: title, onFind: onFind, onOpen: onOpen) }
                    }
                    .padding(.horizontal, Space.margin)
                    .padding(.vertical, Space.s)
                }
            }
        }
        .padding(.vertical, Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(banded ? p.band : .clear)
    }
}

// MARK: - Sample banner

struct SampleBanner: View {
    @EnvironmentObject private var robot: RobotSource
    @Environment(\.palette) private var p

    var body: some View {
        if robot.isSample {
            // Quiet on purpose (Isaac): a small glass tag in the UI's own text color. Still visible in every
            // screenshot and recording; VoiceOver reads the full explanation.
            Text(robot.sampleLabel).font(SoughtFont.badge).tracking(0.3)
                .foregroundStyle(p.text)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .soughtGlass(.pill, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(robot.sampleSpoken)
            .accessibilityIdentifier("sampleBanner")
        }
    }
}

private struct OptionalHero: ViewModifier {
    let id: String?
    func body(content: Content) -> some View {
        if let id { content.heroSource(id, radius: 28) } else { content }
    }
}

/// An item's picture; a pin without a photo shows its teardrop on a soft tile instead of a blank.
struct ItemPhoto: View {
    let item: TrackedObject
    var radius: CGFloat = Radius.photo
    @Environment(\.palette) private var p

    var body: some View {
        if item.isPin, case .none = item.photo {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(p.surface.opacity(0.85))
                .overlay(UserPinMarker(selected: false).scaleEffect(1.6))
                .overlay(alignment: .bottomLeading) {
                    Text("Pinned by you").font(SoughtFont.pillSmall).foregroundStyle(p.activityText)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(.white.opacity(0.6))).padding(8)
                }
                .accessibilityHidden(true)
        } else {
            ShadedPhoto(photo: item.photo, shadeTo: item.isPin ? 0.2 : 0.31, radius: radius)
                .overlay(alignment: .topLeading) {
                    if item.isPin { UserPinMarker().scaleEffect(0.8).padding(8).accessibilityHidden(true) }
                }
        }
    }
}
