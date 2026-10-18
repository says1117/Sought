import SwiftUI

// Come to me, user phone (board task T-068). Waypoint version of docs/COME_TO_ME_PLAN.md: the person says where they
// are by picking a taught spot or a room, and Soughtbot drives there and stops about 1 m short. The pose version
// (relocalize this phone against the robot's saved map) is the plan's stretch and is not offered here.
// With a server configured the pick goes over POST /api/commands as "go to <taught spot>" (BackendRobotSource).

struct ComeToMeSheet: View {
    @EnvironmentObject private var robot: RobotSource
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("lastComePlace") private var lastPlace = ""
    @State private var showPhonePairing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack {
                    SampleBanner().fixedSize()
                    Spacer()
                    Button(robot.come == nil ? "Cancel" : "Close") { closeSheet() }
                        .font(SoughtFont.bodyMedium).foregroundStyle(p.text).frame(minWidth: 44, minHeight: 44)
                }
                Group {
                    if let c = robot.come { progress(c) } else { picker }
                }
                .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
            }
            .padding(.horizontal, Space.margin)
            .padding(.vertical, Space.l)
            .animation(reduceMotion ? Motion.fade : Motion.spring, value: phaseKey)
        }
        .onChange(of: phaseKey) { _, k in speak(k) }
        .fullScreenCover(isPresented: $showPhonePairing) { ComeToMeTestView() }
    }

    private var phaseKey: String {
        guard let c = robot.come else { return "pick" }
        switch c.phase {
        case .going: return "going"
        case .arrived: return "arrived"
        case .failed: return "failed"
        case .lostContact: return "lostContact"
        case .cancelled: return "cancelled"
        }
    }

    // MARK: Pick a place

    private struct Place { var target: ComeTarget; var isRoom: Bool }

    /// Taught spots first, then rooms. A room whose name repeats a spot ("kitchen") is dropped.
    private var places: [Place] {
        guard let map = robot.map else { return [] }
        let spots = map.waypoints.map { Place(target: ComeTarget(waypointId: $0.id, name: "the \($0.name)", x: $0.x, z: $0.z), isRoom: false) }
        let spotNames = Set(spots.map { $0.target.name.lowercased() })
        let rooms = map.rooms.compactMap { r -> Place? in
            let name = "the \(r.name.lowercased())"
            guard !spotNames.contains(name) else { return nil }
            // A room has no waypoint id of its own; use the taught spot inside it closest to its middle.
            let mid = (x: (r.minX + r.maxX) / 2, z: (r.minZ + r.maxZ) / 2)
            let inside = map.waypoints.filter { r.contains(x: $0.x, z: $0.z) }
                .min { hypot($0.x - mid.x, $0.z - mid.z) < hypot($1.x - mid.x, $1.z - mid.z) }
            return Place(target: ComeTarget(waypointId: inside?.id, name: name, x: inside?.x ?? mid.x, z: inside?.z ?? mid.z), isRoom: true)
        }
        return spots + rooms
    }

    @ViewBuilder private var picker: some View {
        Text("Call Soughtbot").font(SoughtFont.largeTitle).foregroundStyle(p.text).accessibilityAddTraits(.isHeader)
        wideButton("Come to my phone", primary: true) { showPhonePairing = true }
            .accessibilityIdentifier("comeToMyPhone")
        Text("Pair the two nearby phones to follow this phone in the same room.").font(SoughtFont.body).foregroundStyle(p.text)
        Text("Go to a saved place").font(SoughtFont.activityHeading).foregroundStyle(p.text).accessibilityAddTraits(.isHeader)
        Text("Choose a taught spot. Soughtbot drives to that saved location and stops about 1 m away.").font(SoughtFont.body).foregroundStyle(p.text)
        if places.isEmpty {
            Text("Soughtbot needs taught spots first. Walk it through a Teach pass on the robot phone.")
                .font(SoughtFont.body).foregroundStyle(p.text).padding(.top, Space.l)
        }
        if let last = places.first(where: { $0.target.name == lastPlace }) {
            Text("Last time").font(SoughtFont.activityHeading).foregroundStyle(p.text).padding(.top, Space.s)
            placeRow(last, highlight: true)
        }
        let spots = places.filter { !$0.isRoom }, rooms = places.filter(\.isRoom)
        if !spots.isEmpty {
            Text("Near").font(SoughtFont.activityHeading).foregroundStyle(p.text).padding(.top, Space.s)
            ForEach(spots, id: \.target.name) { placeRow($0) }
        }
        if !rooms.isEmpty {
            Text("In").font(SoughtFont.activityHeading).foregroundStyle(p.text).padding(.top, Space.s)
            ForEach(rooms, id: \.target.name) { placeRow($0) }
        }
    }

    private func placeRow(_ place: Place, highlight: Bool = false) -> some View {
        let t = place.target
        return Button {
            Haptics.shared.tap()
            lastPlace = t.name
            robot.comeToMe(to: t)
        } label: {
            HStack(spacing: Space.m) {
                Image(systemName: place.isRoom ? "square.split.bottomrightquarter" : "mappin.and.ellipse")
                    .font(.title3).foregroundStyle(p.text).frame(width: 28).accessibilityHidden(true)
                Text(t.name.capitalizedFirst).font(SoughtFont.bodyMedium).foregroundStyle(p.text)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(p.text).accessibilityHidden(true)
            }
            .padding(.horizontal, Space.l)
            .frame(minHeight: 56)
            .background { if highlight { RoundedRectangle(cornerRadius: Radius.row, style: .continuous).fill(p.signal.opacity(0.12)) } }
            .soughtGlass(.pill, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(place.isRoom ? "I\u{2019}m in \(t.name)" : "I\u{2019}m near \(t.name)")
        .accessibilityHint("Soughtbot drives there.")
    }

    // MARK: Progress

    @ViewBuilder private func progress(_ c: ComeProgress) -> some View {
        switch c.phase {
        case let .going(d):
            Text("Soughtbot is coming to \(c.target.name)").font(SoughtFont.largeTitle).foregroundStyle(p.text)
                .accessibilityAddTraits(.isHeader)
            if let d {
                Text(String(format: "%.1f m", d)).font(SoughtFont.bigReadout).foregroundStyle(p.text).monospacedDigit()
                    .contentTransition(.numericText(value: d))
                    .animation(reduceMotion ? nil : .snappy, value: d)
                    .accessibilityLabel(String(format: "%.1f meters to go", d))
            }
            if let map = robot.map { ComeMap(map: map, target: c.target).frame(height: 220) }
            Text("It stops about 1 m away and slows down near things in its path.").font(SoughtFont.cardMeta).foregroundStyle(p.text)
            wideButton("Stop", primary: false) { robot.cancelComeToMe() }
        case .arrived:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(p.found)
                .symbolEffect(.bounce.up, options: .nonRepeating, value: phaseKey).accessibilityHidden(true)
            Text("Soughtbot is here").font(SoughtFont.largeTitle).foregroundStyle(p.text).accessibilityAddTraits(.isHeader)
            Text(c.result ?? "It stopped near \(c.target.name).").font(SoughtFont.body).foregroundStyle(p.text)
            wideButton("Done", primary: true) { closeSheet() }
        case let .failed(reason):
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 56)).foregroundStyle(p.alert).accessibilityHidden(true)
            Text("Soughtbot stopped").font(SoughtFont.largeTitle).foregroundStyle(p.text).accessibilityAddTraits(.isHeader)
            Text(reason).font(SoughtFont.body).foregroundStyle(p.text)
            wideButton("Close", primary: true) { closeSheet() }
        case let .lostContact(reason):
            // The robot may still be driving, so Stop stays first (review F2).
            Image(systemName: "wifi.exclamationmark").font(.system(size: 56)).foregroundStyle(p.alert).accessibilityHidden(true)
            Text("Lost contact with Soughtbot").font(SoughtFont.largeTitle).foregroundStyle(p.text).accessibilityAddTraits(.isHeader)
            Text("\(reason) It may still be moving.").font(SoughtFont.body).foregroundStyle(p.text)
            wideButton("Stop Soughtbot", primary: true) { robot.cancelComeToMe() }
            wideButton("Close", primary: false) { closeSheet() }
        case .cancelled:
            Text("Stopped").font(SoughtFont.largeTitle).foregroundStyle(p.text)
            wideButton("Close", primary: true) { closeSheet() }
        }
    }

    private func wideButton(_ title: String, primary: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(SoughtFont.button).foregroundStyle(primary ? p.onPrimary : p.text)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background { if primary { Capsule().fill(p.primary) } }
                .soughtGlassIf(!primary, .pill, in: Capsule())
                .overlay { if !primary { Capsule().strokeBorder(p.text, lineWidth: 1.5) } }
        }
        .buttonStyle(.plain)
        .padding(.top, Space.s)
    }

    private func closeSheet() {
        switch robot.come?.phase {
        case .going?, .lostContact?: break   // keep it; the Call card still offers Stop
        default: robot.come = nil
        }
        dismiss()
    }

    private func speak(_ key: String) {
        guard let c = robot.come else { return }
        Speaker.shared.enabled = settings.voiceFeedback
        switch key {
        case "going": Speaker.shared.say("Soughtbot is coming to \(c.target.name).")
        case "arrived": Haptics.shared.success(); Speaker.shared.say("Soughtbot is here.")
        case "failed": Haptics.shared.warning(); Speaker.shared.say("Soughtbot stopped.")
        case "lostContact": Haptics.shared.warning(); Speaker.shared.say("Lost contact with Soughtbot. It may still be moving.")
        default: break
        }
    }
}

/// The floor plan with Soughtbot and a ring where it is heading.
private struct ComeMap: View {
    let map: MapSnapshot
    let target: ComeTarget
    @EnvironmentObject private var robot: RobotSource
    @Environment(\.palette) private var p

    var body: some View {
        GeometryReader { g in
            let tf = MapCanvas.Transform(bounds: map.bounds, size: g.size, inset: 12)
            ZStack(alignment: .topLeading) {
                MapCanvas(map: map, robot: robot.status.pose, showLabels: true, active: true,
                          layers: MapLayers(items: false, trail: true, spots: true, userPins: false, fadeByCertainty: false))
                PlacementRing().position(tf.point(target.x, target.z))
            }
        }
        .background(p.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map: Soughtbot heading to \(target.name)")
    }
}
