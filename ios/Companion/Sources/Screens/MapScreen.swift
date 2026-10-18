import SwiftUI

// Map tab (Isaac: "more data and options"). Top to bottom:
//   room chips with counts -> interactive map (room zoom, follow, layers, pinch, pin cards) ->
//   robot card -> counts from the data -> item list for the selected room (sort by recent, nearest, name).
// Every number on this screen is counted from the RobotSource; nothing is estimated.

struct MapScreen: View {
    @EnvironmentObject private var robot: RobotSource
    @EnvironmentObject private var router: Router
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var room: String?             // nil = all rooms
    @State private var selected: TrackedObject?
    @State private var follow = false
    @State private var layers = MapLayers()
    @State private var sort: Sort = .recent
    @State private var pinch: CGFloat = 1
    @State private var userZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var livePan: CGSize = .zero

    enum Sort: String, CaseIterable, Identifiable { case recent = "Recent", nearest = "Nearest", name = "A to Z"; var id: String { rawValue } }

    /// Card height follows the floor plan's shape, within a sensible range.
    private func mapHeight(_ map: MapSnapshot, width: CGFloat) -> CGFloat {
        let b = map.bounds
        let aspect = (b.maxZ - b.minZ) / max(0.1, b.maxX - b.minX)
        return min(380, max(250, width * CGFloat(aspect) + 24))
    }

    var body: some View {
        GeometryReader { outer in
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                header
                if let map = robot.map {
                    roomChips(map)
                    mapCard(map).frame(height: mapHeight(map, width: outer.size.width - Space.margin * 2))
                    robotCard
                    counts(map)
                    itemList.id("list")
                } else {
                    empty
                }
            }
            .padding(.horizontal, Space.margin)
            .padding(.top, Space.l)
            .padding(.bottom, Space.xl)
        }
        .task {   // screenshot hooks: -mapRoom Kitchen, -mapPin obj_sample0008, -mapScrolled YES
            let d = UserDefaults.standard
            if let r = d.string(forKey: "mapRoom") { room = r }
            if let id = d.string(forKey: "mapPin") { selected = robot.objects.first { $0.id == id } }
            if d.bool(forKey: "mapScrolled") { try? await Task.sleep(nanoseconds: 2_000_000_000); proxy.scrollTo("list", anchor: .top) }
        }
        }
        }
    }

    // MARK: Header and chips

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ViewThatFits(in: .horizontal) {
                HStack { SampleBanner().fixedSize(); Spacer(minLength: Space.s); StatusPill() }
                VStack(alignment: .leading, spacing: Space.s) { SampleBanner().fixedSize(); StatusPill(singleLine: false) }
            }
            Text("Map").font(SoughtFont.screenTitle).foregroundStyle(p.title).accessibilityAddTraits(.isHeader)
        }
    }

    private func roomChips(_ map: MapSnapshot) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s) {
                chip("All", count: robot.objects.count, on: room == nil) { setRoom(nil) }
                ForEach(map.rooms) { r in
                    chip(r.name, count: items(in: r.name).count, on: room == r.name) { setRoom(r.name) }
                }
            }
            .padding(.horizontal, Space.margin)
            .padding(.vertical, 2)
        }
        .padding(.horizontal, -Space.margin)
    }

    private func chip(_ title: String, count: Int, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(SoughtFont.cardTitle)
                Text("\(count)").font(SoughtFont.readout)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(on ? p.onPrimary.opacity(0.2) : p.text.opacity(0.08)))
            }
            .foregroundStyle(on ? p.onPrimary : p.text)
            .padding(.horizontal, Space.m)
            .frame(minHeight: 36)
            .background { if on { Capsule().fill(p.primary) } }
            .soughtGlassIf(!on, .pill, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) items")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func setRoom(_ r: String?) {
        Haptics.shared.tap()
        withAnimation(reduceMotion ? Motion.fade : Motion.spring) {
            room = r; follow = false; selected = nil; userZoom = 1; pan = .zero
        }
    }

    // MARK: Map

    private func mapCard(_ map: MapSnapshot) -> some View {
        GeometryReader { geo in
            let size = geo.size
            let tf = MapCanvas.Transform(bounds: map.bounds, size: size, inset: 12)
            let (baseScale, baseOffset) = focus(map, tf, size)
            let scale = baseScale * userZoom * pinch
            let offset = CGSize(width: baseOffset.width * userZoom * pinch + pan.width + livePan.width,
                                height: baseOffset.height * userZoom * pinch + pan.height + livePan.height)
            ZStack(alignment: .topTrailing) {
                MapCanvas(map: map, robot: robot.status.pose, pins: robot.objects, highlight: selected?.id,
                          active: robot.status.isOnline(now: robot.now) && robot.status.state != .idle,
                          onPin: { o in withAnimation(Motion.spring) { selected = o }; Haptics.shared.tap() },
                          layers: layers, focusRoom: room, roomCounts: roomCounts(map), markerScale: 1 / scale)
                    .scaleEffect(scale)
                    .offset(offset)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .gesture(MagnificationGesture()
                        .onChanged { pinch = max(0.6, min(3, $0)) }
                        .onEnded { _ in userZoom = max(1, min(4, userZoom * pinch)); pinch = 1 })
                    .simultaneousGesture(DragGesture(minimumDistance: 8)
                        .updating($livePan) { v, s, _ in if scale > 1.01 { s = v.translation } }
                        .onEnded { v in if scale > 1.01 { pan.width += v.translation.width; pan.height += v.translation.height } })
                controls
                    .padding(Space.s)
                if let o = selected {
                    pinCard(o)
                        .padding(Space.s)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(p.surface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: Radius.card * 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card * 2, style: .continuous).strokeBorder(.white.opacity(0.6), lineWidth: 1))
        .softShadow()
        .animation(reduceMotion ? Motion.fade : Motion.spring, value: room)
        .animation(reduceMotion ? Motion.fade : .easeInOut(duration: 1.2), value: follow ? robot.status.pose : nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Floor map" + (room.map { ", showing the \($0.lowercased())" } ?? ""))
    }

    /// Zoom and offset that bring the focused room, or the robot when following, to the middle of the card.
    private func focus(_ map: MapSnapshot, _ tf: MapCanvas.Transform, _ size: CGSize) -> (CGFloat, CGSize) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        if follow, let r = robot.status.pose {
            let pt = tf.point(r.x, r.z), s: CGFloat = 2
            return (s, CGSize(width: (c.x - pt.x) * s, height: (c.y - pt.y) * s))
        }
        guard let name = room, let r = map.rooms.first(where: { $0.name == name }) else { return (1, .zero) }
        let rect = tf.rect(r.minX, r.minZ, r.maxX, r.maxZ)
        let s = min(3, min(size.width / rect.width, size.height / rect.height) * 0.85)
        return (s, CGSize(width: (c.x - rect.midX) * s, height: (c.y - rect.midY) * s))
    }

    private var controls: some View {
        VStack(spacing: Space.s) {
            mapButton(follow ? "location.fill" : "location", label: follow ? "Stop following Soughtbot" : "Follow Soughtbot", on: follow) {
                withAnimation(Motion.spring) { follow.toggle(); room = nil; userZoom = 1; pan = .zero }
            }
            Menu {
                Toggle("Items", isOn: $layers.items)
                Toggle("Soughtbot's path", isOn: $layers.trail)
                Toggle("Taught spots", isOn: $layers.spots)
                Toggle("Fade items it is unsure about", isOn: $layers.fadeByCertainty)
            } label: {
                mapButtonLabel("square.3.layers.3d", on: layers != MapLayers())
            }
            .accessibilityLabel("Map layers")
            if userZoom > 1 || pan != .zero {
                mapButton("arrow.down.right.and.arrow.up.left", label: "Reset zoom", on: false) {
                    withAnimation(Motion.spring) { userZoom = 1; pan = .zero }
                }
            }
        }
    }

    private func mapButton(_ icon: String, label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.shared.tap(); action() } label: { mapButtonLabel(icon, on: on) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    private func mapButtonLabel(_ icon: String, on: Bool) -> some View {
        Image(systemName: icon).font(.system(size: 17, weight: .semibold))
            .foregroundStyle(on ? p.onPrimary : p.text)
            .frame(width: 44, height: 44)
            .background { if on { Circle().fill(p.primary) } }
            .soughtGlassIf(!on, .pill, in: Circle())
    }

    private func pinCard(_ o: TrackedObject) -> some View {
        HStack(spacing: Space.m) {
            ShadedPhoto(photo: o.photo, shadeTo: 0).frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(o.label).font(SoughtFont.bodyMedium).foregroundStyle(p.text)
                Text("\(o.whereText) · \(StatusCopy.ago(o.lastSeen, now: robot.now))").font(SoughtFont.cardMeta).foregroundStyle(p.text)
                Text(o.certaintyWord).font(SoughtFont.cardMeta).foregroundStyle(p.text)
            }
            Spacer(minLength: 0)
            VStack(spacing: Space.xs) {
                Button { router.find(o) } label: {
                    Label("Find", systemImage: "magnifyingglass").font(SoughtFont.findIt).foregroundStyle(p.onPrimary)
                        .padding(.horizontal, Space.m).frame(minHeight: 36).background(Capsule().fill(p.primary))
                }
                Button { router.open(o) } label: {
                    Text("Details").font(SoughtFont.findIt).foregroundStyle(p.text).frame(minHeight: 32)
                }
            }
            .buttonStyle(.plain)
            Button { withAnimation(Motion.spring) { selected = nil } } label: {
                Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(p.text).frame(width: 32, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close summary")
        }
        .padding(Space.s)
        .soughtGlass(.sheet, in: RoundedRectangle(cornerRadius: Radius.card * 1.5, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    // MARK: Robot card and counts

    private var robotCard: some View {
        let s = robot.status
        let online = s.isOnline(now: robot.now)
        return HStack(alignment: .center, spacing: Space.m) {
            ZStack {
                Circle().fill(online ? p.signal.opacity(0.25) : p.text.opacity(0.08)).frame(width: 44, height: 44)
                Circle().fill(p.mapPath).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 2.5))
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(robot.currentRoom.map { "Soughtbot · \($0)" } ?? "Soughtbot").font(SoughtFont.bodyMedium).foregroundStyle(p.text)
                Text(StatusCopy.line(s, now: robot.now)).font(SoughtFont.cardMeta).foregroundStyle(p.text).lineLimit(2)
                if let t = s.lastHeartbeat {
                    Text(online ? "Checked in \(Int(max(0, robot.now.timeIntervalSince(t)))) s ago" : "Last check-in \(StatusCopy.ago(t, now: robot.now))")
                        .font(SoughtFont.cardMeta).foregroundStyle(p.text.opacity(0.85))
                }
            }
            Spacer(minLength: 0)
            Button {
                Haptics.shared.tap()
                if robot.canComeToMe && online { robot.comeToMe() }
            } label: {
                Text(s.state == .comingToUser ? "Coming" : "Call").font(SoughtFont.findIt).foregroundStyle(p.onPrimary)
                    .padding(.horizontal, Space.l).frame(minHeight: 44)
                    .background(Capsule().fill(p.call))
            }
            .buttonStyle(.plain)
            .disabled(!(robot.canComeToMe && online))
            .accessibilityLabel(s.state == .comingToUser ? "Soughtbot is coming to you" : "Call Soughtbot")
        }
        .padding(Space.m)
        .soughtGlass(.activity, in: RoundedRectangle(cornerRadius: Radius.card * 1.5, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func counts(_ map: MapSnapshot) -> some View {
        let tiles: [(String, String)] = [
            ("\(robot.objects.count)", robot.objects.count == 1 ? "item" : "items"),
            ("\(map.rooms.count)", map.rooms.count == 1 ? "room" : "rooms"),
            ("\(map.waypoints.count)", "taught spots"),
            (StatusCopy.ago(map.updatedAt, now: robot.now).replacingOccurrences(of: " ago", with: ""), "map updated"),
        ]
        return HStack(spacing: Space.s) {
            ForEach(tiles, id: \.1) { v, label in
                VStack(alignment: .leading, spacing: 2) {
                    Text(v).font(SoughtFont.readout).foregroundStyle(p.text).lineLimit(1).minimumScaleFactor(0.7)
                    Text(label).font(SoughtFont.cardMeta).foregroundStyle(p.text.opacity(0.85)).lineLimit(2)
                }
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
                .padding(Space.s)
                .soughtGlass(.pill, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Item list

    private var itemList: some View {
        let list = sorted(room.map(items(in:)) ?? robot.objects)
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(room.map { "In the \($0)" } ?? "Everything").font(SoughtFont.sectionTitle).foregroundStyle(p.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    Picker("Sort", selection: $sort) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0) } }
                } label: {
                    Label(sort.rawValue, systemImage: "arrow.up.arrow.down").font(SoughtFont.findIt).foregroundStyle(p.text)
                        .frame(minHeight: 44)
                }
                .accessibilityLabel("Sort, \(sort.rawValue)")
            }
            if list.isEmpty {
                Text("Nothing remembered here yet.").font(SoughtFont.body).foregroundStyle(p.text)
            }
            ForEach(list) { o in row(o) }
        }
    }

    private func row(_ o: TrackedObject) -> some View {
        HStack(spacing: Space.m) {
            Button { withAnimation(Motion.spring) { room = o.room; selected = o; follow = false } } label: {
                HStack(spacing: Space.m) {
                    ShadedPhoto(photo: o.photo, shadeTo: 0).frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(o.label).font(SoughtFont.bodyMedium).foregroundStyle(p.text)
                        Text("\(o.whereText) · \(StatusCopy.ago(o.lastSeen, now: robot.now))").font(SoughtFont.cardMeta).foregroundStyle(p.text)
                        HStack(spacing: 6) {
                            Circle().fill(certaintyColor(o)).frame(width: 7, height: 7).accessibilityHidden(true)
                            Text(o.certaintyWord + (distance(o).map { " · " + String(format: "%.1f m away", $0) } ?? ""))
                                .font(SoughtFont.cardMeta).foregroundStyle(p.text).lineLimit(1).minimumScaleFactor(0.85)
                                .accessibilityLabel(o.certaintyWord + (distance(o).map { ", " + String(format: "%.1f meters from Soughtbot", $0) } ?? ""))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows it on the map.")
            Button { router.find(o) } label: {
                Image(systemName: "magnifyingglass").font(.body.weight(.semibold)).foregroundStyle(p.onPrimary)
                    .frame(width: 44, height: 44).background(Circle().fill(p.primary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Find \(o.label)")
        }
        .padding(Space.s)
        .soughtGlass(.pill, in: RoundedRectangle(cornerRadius: Radius.card * 1.5, style: .continuous))
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("No map yet").font(SoughtFont.sectionTitle).foregroundStyle(p.sectionTitle)
            Text("Soughtbot draws the map as it learns the room. Start a Teach walk on the robot phone.")
                .font(SoughtFont.body).foregroundStyle(p.text)
        }
    }

    // MARK: Data

    private func items(in room: String) -> [TrackedObject] { robot.objects.filter { $0.room == room } }

    private func roomCounts(_ map: MapSnapshot) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: map.rooms.map { ($0.name, items(in: $0.name).count) })
    }

    private func distance(_ o: TrackedObject) -> Double? {
        guard let r = robot.status.pose else { return nil }
        return hypot(o.x - r.x, o.z - r.z)
    }

    private func sorted(_ list: [TrackedObject]) -> [TrackedObject] {
        switch sort {
        case .recent: list.sorted { $0.lastSeen > $1.lastSeen }
        case .nearest: list.sorted { (distance($0) ?? .infinity) < (distance($1) ?? .infinity) }
        case .name: list.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        }
    }

    private func certaintyColor(_ o: TrackedObject) -> Color {
        switch o.persistence ?? 1 {
        case 0.7...: p.found
        case 0.4..<0.7: p.searching
        default: p.alert
        }
    }
}

extension View {
    @ViewBuilder func soughtGlassIf<S: InsettableShape>(_ on: Bool, _ style: GlassStyle, in shape: S) -> some View {
        if on { soughtGlass(style, in: shape) } else { self }
    }
}
