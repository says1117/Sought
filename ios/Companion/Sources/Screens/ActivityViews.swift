import SwiftUI

// Activity log, as approved by Isaac (2026-10-17): Home card "D" (one sentence, a light "Moved · 12 min ago" pill,
// page dots, cyan dot while busy) and a trimmed full log (Now line, Today / Earlier, one sentence + pill per row,
// a mini map with the item photo when a move is opened).

/// "Moved · 12 min ago"
func activityPill(_ e: ActivityEvent, now: Date) -> String { "\(e.kind.word) · \(StatusCopy.ago(e.at, now: now))" }

struct ActivityPill: View {
    let text: String
    var onCard = false
    @Environment(\.palette) private var p

    var body: some View {
        Text(text).font(onCard ? SoughtFont.pillSmall : SoughtFont.pill).foregroundStyle(p.activityText)
            .lineLimit(1).minimumScaleFactor(0.85)
            .padding(.horizontal, onCard ? 7 : 9).padding(.vertical, 3)
            .background(Capsule().fill(onCard ? Color.white.opacity(p.isHighContrast ? 0.12 : 0.55)
                                              : p.activityFill.opacity(p.isHighContrast ? 1 : 1.6)))
    }
}

// MARK: - Home card

struct ActivityCard: View {
    var onOpen: () -> Void
    @EnvironmentObject private var robot: RobotSource
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var index = 0

    private var recent: [ActivityEvent] { Array(robot.events.prefix(3)) }
    private var busy: Bool { robot.status.isOnline(now: robot.now) && robot.status.state != .idle }
    /// Rotation holds still with Reduce Motion or VoiceOver, so nothing changes while someone reads it.
    private var rotates: Bool { recent.count > 1 && !reduceMotion && !voiceOver }

    var body: some View {
        let e = recent.isEmpty ? nil : recent[min(index, recent.count - 1)]
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    Text("Activity log").font(SoughtFont.activityHeading)
                    Spacer(minLength: 4)
                    if busy {
                        Circle().fill(p.signal).frame(width: 7, height: 7)
                            .background(Circle().fill(p.signal.opacity(0.22)).frame(width: 15, height: 15))
                            .accessibilityHidden(true)
                    }
                }
                Text(e?.text ?? "No changes yet").font(SoughtFont.activityBody)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(e?.id ?? "none")
                    .transition(.opacity.combined(with: .offset(y: 4)))
                Spacer(minLength: 0)
                HStack(alignment: .center) {
                    if let e { ActivityPill(text: activityPill(e, now: robot.now), onCard: true).id(e.id).transition(.opacity) }
                    Spacer(minLength: 4)
                    if recent.count > 1 {
                        HStack(spacing: 4) {
                            ForEach(recent.indices, id: \.self) { i in
                                Capsule().fill(p.activityText.opacity(i == index ? 1 : 0.25))
                                    .frame(width: i == index ? 14 : 6, height: 6)
                            }
                        }
                        .accessibilityHidden(true)
                    }
                }
            }
            .foregroundStyle(p.activityText)
            .padding(Space.l)
            .frame(maxWidth: .infinity, minHeight: 147, alignment: .topLeading)
            .soughtGlass(.activity, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .animation(Motion.spring, value: index)
        }
        .buttonStyle(.plain)
        .task(id: rotates) {
            guard rotates else { index = 0; return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if Task.isCancelled { break }
                index = (index + 1) % max(1, recent.count)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity log. " + (e.map { "\($0.kind.word): \($0.text), \(StatusCopy.agoSpoken($0.at, now: robot.now))." } ?? "No changes yet."))
        .accessibilityHint("Double tap to see all changes.")
        .accessibilityIdentifier("activityCard")
    }
}

// MARK: - Full log

struct ActivitySheet: View {
    @EnvironmentObject private var robot: RobotSource
    @EnvironmentObject private var router: Router
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var open: String?

    var body: some View {
        let all = robot.events
        let today = all.filter { Calendar.current.isDate($0.at, inSameDayAs: robot.now) }
        let earlier = all.filter { !Calendar.current.isDate($0.at, inSameDayAs: robot.now) }
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    SampleBanner().fixedSize()
                    Spacer()
                    Button("Done") { dismiss() }.font(SoughtFont.bodyMedium).foregroundStyle(p.text).frame(minWidth: 44, minHeight: 44)
                }
                Text("Activity log").font(SoughtFont.largeTitle).foregroundStyle(p.text).accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if robot.status.isOnline(now: robot.now) && robot.status.state != .idle {
                            Circle().fill(p.signal).frame(width: 7, height: 7).accessibilityHidden(true)
                        }
                        Text(nowLine).font(SoughtFont.activityMeta)
                    }
                    Text("\(today.count) \(today.count == 1 ? "change" : "changes") today").font(SoughtFont.cardMeta)
                }
                .foregroundStyle(p.text)
                .accessibilityElement(children: .combine)

                if all.isEmpty {
                    Text("No changes yet. When Soughtbot sees an item in a new spot, it shows up here.")
                        .font(SoughtFont.body).foregroundStyle(p.text).padding(.top, Space.l)
                }
                group("Today", today)
                group("Earlier", earlier)
                Text("Based on what Soughtbot reported. A move is an item seen more than 0.75 m from its last spot.")
                    .font(SoughtFont.cardMeta).foregroundStyle(p.text).padding(.top, Space.s)
            }
            .padding(.horizontal, Space.margin)
            .padding(.vertical, Space.l)
        }
        .background(SoughtBackground())
        .onAppear {   // screenshot hook: -activityOpenFirst YES opens the newest move
            if UserDefaults.standard.bool(forKey: "activityOpenFirst") { open = robot.events.first { $0.kind == .moved }?.id }
        }
    }

    private var nowLine: String {
        let s = robot.status
        guard s.isOnline(now: robot.now) else { return StatusCopy.line(s, now: robot.now) }
        let base = StatusCopy.line(RobotStatus(state: s.state, task: s.task, battery: nil, pose: nil, lastHeartbeat: s.lastHeartbeat), now: robot.now)
        guard s.state == .exploring, let room = robot.currentRoom else { return base }
        return "Soughtbot is roaming the \(room.lowercased())"
    }

    @ViewBuilder private func group(_ title: String, _ list: [ActivityEvent]) -> some View {
        if !list.isEmpty {
            Text(title).font(SoughtFont.activityHeading).foregroundStyle(p.text).padding(.top, Space.l)
                .accessibilityAddTraits(.isHeader)
            ForEach(list) { e in row(e) }
        }
    }

    private func row(_ e: ActivityEvent) -> some View {
        let object = e.objectId.flatMap { id in robot.objects.first { $0.id == id } }
        let canOpen = e.kind == .moved && object != nil
        let isOpen = open == e.id
        return VStack(alignment: .leading, spacing: Space.s) {
            Button {
                guard canOpen else { return }
                withAnimation(reduceMotion ? Motion.fade : Motion.spring) { open = isOpen ? nil : e.id }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(e.text).font(SoughtFont.body).foregroundStyle(p.text).frame(maxWidth: .infinity, alignment: .leading)
                    ActivityPill(text: activityPill(e, now: robot.now))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(e.text). \(e.kind.word), \(StatusCopy.agoSpoken(e.at, now: robot.now)).")
            .accessibilityHint(canOpen ? (isOpen ? "Double tap to hide the map." : "Double tap to show where it moved.") : "")
            if isOpen, let object, let map = robot.map {
                MiniMoveMap(map: map, object: object, from: e.from, to: e.to)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                HStack(spacing: Space.s) {
                    Button { dismiss(); router.find(object) } label: {
                        Label("Find it", systemImage: "magnifyingglass").font(SoughtFont.findIt).foregroundStyle(p.onPrimary)
                            .frame(maxWidth: .infinity, minHeight: 44).background(Capsule().fill(p.primary))
                    }
                    Button { dismiss(); router.open(object) } label: {
                        Text("Details").font(SoughtFont.findIt).foregroundStyle(p.text)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .overlay(Capsule().strokeBorder(p.text, lineWidth: 1.2)).contentShape(Capsule())
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Space.m)
        .soughtGlass(.pill, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }
}

/// Small floor plan with a dashed ring where the item was, a dotted arrow, and its photo where it is now.
struct MiniMoveMap: View {
    let map: MapSnapshot
    let object: TrackedObject
    let from: (x: Double, z: Double)?
    let to: (x: Double, z: Double)?
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                let tf = MapCanvas.Transform(bounds: map.bounds, size: g.size, inset: 8)
                let a = from.map { tf.point($0.x, $0.z) }
                let b = tf.point(to?.x ?? object.x, to?.z ?? object.z)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        for r in map.rooms {
                            let rect = tf.rect(r.minX, r.minZ, r.maxX, r.maxZ).insetBy(dx: 2, dy: 2)
                            let here = r.contains(x: to?.x ?? object.x, z: to?.z ?? object.z)
                            ctx.fill(Path(roundedRect: rect, cornerRadius: 8, style: .continuous),
                                     with: .color(here ? p.signal.opacity(0.10) : p.mapRoom.opacity(0.6)))
                            ctx.stroke(Path(roundedRect: rect, cornerRadius: 8, style: .continuous), with: .color(p.mapWall), lineWidth: 2)
                        }
                        if let a {
                            ctx.stroke(Path(ellipseIn: CGRect(x: a.x - 8, y: a.y - 8, width: 16, height: 16)),
                                       with: .color(p.text), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                            var path = Path()
                            path.move(to: a)
                            let mid = CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - 24)
                            path.addQuadCurve(to: b, control: mid)
                            ctx.stroke(path.trimmedPath(from: 0.08, to: 0.85), with: .color(p.mapPath),
                                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 6]))
                        }
                    }
                    Group {
                        if object.isPin {
                            UserPinMarker(selected: true).offset(y: -14)
                        } else if case .none = object.photo {
                            Circle().fill(p.mapPath).frame(width: 16, height: 16)
                                .overlay(Circle().stroke(.white, lineWidth: 3)).overlay(Circle().stroke(p.found, lineWidth: 2).padding(-4))
                        } else {
                            PhotoView(photo: object.photo)
                                .frame(width: 30, height: 30).clipShape(Circle())
                                .overlay(Circle().stroke(p.found, lineWidth: 3))
                        }
                    }
                    .position(b)
                }
            }
            .frame(height: 150)
            HStack(spacing: Space.m) {
                if from != nil {
                    HStack(spacing: 4) { Circle().strokeBorder(p.text, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2])).frame(width: 10, height: 10); Text("Was here") }
                }
                HStack(spacing: 4) { Circle().strokeBorder(p.found, lineWidth: 2).frame(width: 10, height: 10); Text("Now here") }
            }
            .font(SoughtFont.cardMeta).foregroundStyle(p.text)
            .accessibilityHidden(true)
        }
        .padding(Space.s)
        .background(RoundedRectangle(cornerRadius: Radius.thumb, style: .continuous).fill(p.surface))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map showing \(object.label.lowercased()) moving to \(object.whereText.lowercased()).")
    }
}
