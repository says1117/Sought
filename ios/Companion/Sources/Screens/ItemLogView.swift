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
                    SearchBar(text: $query, placeholder: "Try typing \u{201C}Backpack\u{201D}", heroKey: "search-items") { q in router.search(q, in: robot) }
                }
                .padding(.horizontal, Space.margin)
                .padding(.top, Space.l)
                .padding(.bottom, Space.s)

                if robot.isLoading {
                    VStack(alignment: .leading, spacing: Space.l) {
                        ForEach(0..<2, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: Space.s) {
                                Capsule().fill(p.surface.opacity(0.7)).frame(width: 160, height: 18).shimmer()
                                HStack(spacing: Space.l) { SkeletonCard(); SkeletonCard() }
                            }
                        }
                    }
                    .padding(.horizontal, Space.margin).padding(.top, Space.l)
                    .accessibilityElement().accessibilityLabel("Loading items")
                } else if robot.items.isEmpty {
                    empty
                } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    let hits = filtered
                    ItemRow(title: "Matches", items: hits, emptyText: "Nothing called \u{201C}\(query)\u{201D} yet. Press search to ask Soughtbot to look.",
                            onFind: router.find, onOpen: router.open)
                } else {
                    if !robot.toName.isEmpty {
                        ItemRow(title: "Needs a name", items: robot.toName, onFind: router.find, onOpen: router.open)
                    }
                    ItemRow(title: "Recent Finds", items: Array(robot.recentFinds.prefix(10)),
                            emptyText: "Name what Soughtbot found and it shows up here.", onFind: router.find, onOpen: router.open)
                    ItemRow(title: "Essentials", items: robot.essentials, banded: true,
                            emptyText: "Pin items you need often from their detail page.", onFind: router.find, onOpen: router.open)
                    if !robot.pins.isEmpty {
                        ItemRow(title: "Your pins", items: robot.pinnedItems, onFind: router.find, onOpen: router.open)
                    }
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
    @Environment(\.dynamicTypeSize) private var dts
    @EnvironmentObject private var robot: RobotSource
    @EnvironmentObject private var router: Router
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let item = robot.items.first(where: { $0.id == itemId }) { content(item) } else {
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
                ItemPhoto(item: item, radius: Radius.card)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .softShadow()
                    .accessibilityLabel("Photo of \(item.label)")
                Text(item.label).font(SoughtFont.largeTitle).foregroundStyle(p.text).accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: Space.s) {
                    fact("Where", item.whereText)
                    if let r = item.room { fact("Room", r) }
                    if item.isPin {
                        fact("Pinned", "By you, \(StatusCopy.ago(item.lastSeen, now: robot.now))")
                        if let n = item.pin?.note { fact("Note", n) }
                    } else {
                        fact("Last seen", StatusCopy.ago(item.lastSeen, now: robot.now))
                        fact("First seen", StatusCopy.ago(item.firstSeen, now: robot.now))
                        fact("Seen", "\(item.sightings) \(item.sightings == 1 ? "time" : "times")")
                    }
                }
                if item.needsName {
                    Button { router.nameRequest = [item.id] } label: {
                        Label("Name it", systemImage: "pencil").font(SoughtFont.button)
                            .foregroundStyle(p.onPrimary).frame(maxWidth: .infinity, minHeight: 56)
                            .background(Capsule().fill(p.call))
                    }
                }
                Button { router.find(item) } label: {
                    Label("Find it", systemImage: "magnifyingglass").font(SoughtFont.button)
                        .foregroundStyle(p.onPrimary).frame(maxWidth: .infinity, minHeight: 56)
                        .background(Capsule().fill(p.primary))
                }
                .accessibilityHint("Soughtbot drives to the \(item.label.lowercased()).")
                if item.isPin {
                    Button { robot.removePin(id: item.id); dismiss() } label: {
                        Label("Remove pin", systemImage: "mappin.slash").font(SoughtFont.button).foregroundStyle(p.text)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .soughtGlass(.pill, in: Capsule())
                            .overlay(Capsule().strokeBorder(p.text, lineWidth: 1.5))
                    }
                } else {
                Button { toggleEssential(item) } label: {
                    Label(item.isEssential ? "Remove from Essentials" : "Pin as Essential", systemImage: item.isEssential ? "pin.slash" : "pin")
                        .font(SoughtFont.button).foregroundStyle(p.text).frame(maxWidth: .infinity, minHeight: 50)
                        .soughtGlass(.pill, in: Capsule())
                        .overlay(Capsule().strokeBorder(p.text, lineWidth: 1.5))
                }
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
        let key = Text(k.uppercased()).font(SoughtFont.readout).foregroundStyle(p.text)
        let value = Text(v).font(SoughtFont.body).foregroundStyle(p.text)
        return Group {
            if dts >= .xxxLarge {
                VStack(alignment: .leading, spacing: 2) { key; value }
            } else {
                HStack(alignment: .firstTextBaseline) { key.frame(width: 100, alignment: .leading); value }
            }
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
