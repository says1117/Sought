import SwiftUI

// Item Log (Figma "Item Log"): search + mic, then Recent Finds, Essentials, Frequently Sought, and one row per room.
// Typing filters the rows live; pressing search starts a find.

struct ItemLogView: View {
    @EnvironmentObject private var robot: RobotSource
    @EnvironmentObject private var router: Router
    @Environment(\.palette) private var p
    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Space.m) {
                    SampleBanner()
                    ScreenHeader(title: "Item Log")
                    SearchBar(text: $query, placeholder: "Try typing \u{201C}Backpack\u{201D}") { q in router.search(q, in: robot) }
                }
                .padding(.horizontal, Space.margin)
                .padding(.top, Space.l)
                .padding(.bottom, Space.s)

                if robot.objects.isEmpty {
                    empty
                } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    let hits = filtered
                    ItemRow(title: "Matches", items: hits, emptyText: "Nothing called \u{201C}\(query)\u{201D} yet. Press search to ask Soughtbot to look.",
                            onFind: router.find, onOpen: router.open)
                } else {
                    ItemRow(title: "Recent Finds", items: Array(robot.recentFinds.prefix(10)), onFind: router.find, onOpen: router.open)
                    ItemRow(title: "Essentials", items: robot.essentials, banded: true,
                            emptyText: "Pin items you need often from their detail page.", onFind: router.find, onOpen: router.open)
                    ItemRow(title: "Frequently Sought", items: robot.frequentlySought,
                            emptyText: "Items you search for most show up here.", onFind: router.find, onOpen: router.open)
                    ForEach(Array(robot.byRoom.enumerated()), id: \.element.room) { i, group in
                        ItemRow(title: group.room, items: group.items, banded: i % 2 == 0, onFind: router.find, onOpen: router.open)
                    }
                }
            }
            .padding(.bottom, Space.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.clear)
    }

    private var filtered: [TrackedObject] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return robot.recentFinds.filter { $0.label.lowercased().contains(q) || $0.whereText.lowercased().contains(q) || ($0.room ?? "").lowercased().contains(q) }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("No items yet").font(SoughtFont.sectionTitle).foregroundStyle(p.sectionTitle)
            Text("Soughtbot remembers things as it looks around. Once it has explored a room, items appear here.")
                .font(SoughtFont.body).foregroundStyle(p.text)
        }
        .padding(Space.margin)
    }
}

// MARK: - Item detail

struct ItemDetailView: View {
    let itemId: String
    @EnvironmentObject private var robot: RobotSource
    @EnvironmentObject private var router: Router
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let item = robot.objects.first(where: { $0.id == itemId }) { content(item) } else {
            Text("This item is no longer in Soughtbot's memory.").font(SoughtFont.body).padding()
        }
    }

    private func content(_ item: TrackedObject) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                HStack {
                    SampleBanner()
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).foregroundStyle(p.text)
                            .frame(width: 44, height: 44).background(Circle().fill(p.micFill))
                    }
                    .accessibilityLabel("Close")
                }
                ShadedPhoto(photo: item.photo, shadeTo: 0.25)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .softShadow()
                    .accessibilityLabel("Photo of \(item.label)")
                Text(item.label).font(SoughtFont.largeTitle).foregroundStyle(p.text).accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: Space.s) {
                    fact("Where", item.whereText)
                    if let r = item.room { fact("Room", r) }
                    fact("Last seen", StatusCopy.ago(item.lastSeen, now: robot.now))
                    fact("First seen", StatusCopy.ago(item.firstSeen, now: robot.now))
                    fact("Seen", "\(item.sightings) \(item.sightings == 1 ? "time" : "times")")
                }
                Button { router.find(item) } label: {
                    Label("Find it", systemImage: "magnifyingglass").font(SoughtFont.button)
                        .foregroundStyle(p.onPrimary).frame(maxWidth: .infinity, minHeight: 56)
                        .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(p.primary))
                }
                .accessibilityHint("Soughtbot drives to the \(item.label.lowercased()).")
                Button { toggleEssential(item) } label: {
                    Label(item.isEssential ? "Remove from Essentials" : "Pin as Essential", systemImage: item.isEssential ? "pin.slash" : "pin")
                        .font(SoughtFont.button).foregroundStyle(p.text).frame(maxWidth: .infinity, minHeight: 50)
                        .background(RoundedRectangle(cornerRadius: Radius.button, style: .continuous).stroke(p.text, lineWidth: 1.5))
                }
                if item.history.count > 1 {
                    Text("History").font(SoughtFont.sectionTitle).foregroundStyle(p.sectionTitle).accessibilityAddTraits(.isHeader)
                    ForEach(Array(item.history.sorted { $0.t > $1.t }.enumerated()), id: \.offset) { _, h in
                        HStack {
                            Text(ActivityDeriver.location(x: h.x, z: h.z, object: item, map: robot.map))
                            Spacer()
                            Text(StatusCopy.ago(h.t, now: robot.now))
                        }
                        .font(SoughtFont.activityMeta).foregroundStyle(p.text)
                        .accessibilityElement(children: .combine)
                    }
                    Text("Based on where the item was last seen.").font(SoughtFont.cardMeta).foregroundStyle(p.text)
                }
            }
            .padding(Space.margin)
        }
        .background(Color.clear)
    }

    private func fact(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k.uppercased()).font(SoughtFont.readout).foregroundStyle(p.text.opacity(0.8)).frame(width: 100, alignment: .leading)
            Text(v).font(SoughtFont.body).foregroundStyle(p.text)
        }
        .accessibilityElement(children: .combine)
    }

    private func toggleEssential(_ item: TrackedObject) {
        guard let i = robot.objects.firstIndex(where: { $0.id == item.id }) else { return }
        robot.objects[i].isEssential.toggle()
        Haptics.shared.tap()
        UIAccessibility.post(notification: .announcement, argument: robot.objects[i].isEssential ? "Pinned as essential" : "Removed from essentials")
    }
}
