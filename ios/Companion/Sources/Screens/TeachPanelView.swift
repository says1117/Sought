import SwiftUI

// Drive & Teach sheet (opened from the Drive & Teach card on Home). Drives Soughtbot in small steps and teaches places
// over the remote command route, so a teach tour can be run from this phone while the robot phone rides the rover.
// Logic and exact phrases live in TeachPanelModel.

struct TeachPanelView: View {
    @StateObject private var model: TeachPanelModel
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool

    init(robot: RobotSource) { _model = StateObject(wrappedValue: TeachPanelModel(robot: robot)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                HStack {
                    SampleBanner().fixedSize()
                    Spacer()
                    Button("Close") { dismiss() }
                        .font(SoughtFont.bodyMedium).foregroundStyle(p.text).frame(minWidth: 44, minHeight: 44)
                }
                Text("Drive & Teach").font(SoughtFont.screenTitle).foregroundStyle(p.title).accessibilityAddTraits(.isHeader)
                Text("Tour: drive, Mark place, Scan here, repeat, then Save map.")
                    .font(SoughtFont.cardMeta).foregroundStyle(p.text)
                    .accessibilityIdentifier("teachHint")

                stopButton
                statusCard

                section("Drive") {
                    Picker("Step", selection: $model.step) {
                        ForEach(TeachPanelModel.steps, id: \.self) { Text("\(TeachPanelModel.meters($0)) m").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Step distance")
                    HStack(spacing: Space.m) {
                        action("Back", icon: "arrow.down", id: "teachBack", action: model.back)
                        action("Forward", icon: "arrow.up", id: "teachForward", action: model.forward)
                    }
                    Picker("Turn", selection: $model.turn) {
                        ForEach(TeachPanelModel.turns, id: \.self) { Text("\($0)\u{00B0}").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Turn angle")
                    HStack(spacing: Space.m) {
                        action("Turn left", icon: "arrow.counterclockwise", id: "teachLeft", action: model.turnLeft)
                        action("Turn right", icon: "arrow.clockwise", id: "teachRight", action: model.turnRight)
                    }
                }

                section("Teach") {
                    TextField("Place name, e.g. kitchen", text: $model.placeName)
                        .font(SoughtFont.body).foregroundStyle(p.text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onSubmit { model.markPlace() }
                        .padding(.horizontal, Space.m).frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: Radius.thumb, style: .continuous).fill(p.surface))
                        .accessibilityIdentifier("teachPlaceName")
                    HStack(spacing: Space.m) {
                        action("Mark place", icon: "mappin.and.ellipse", id: "teachMark", enabled: model.canMark) {
                            nameFocused = false
                            model.markPlace()
                        }
                        action("Scan here", icon: "viewfinder", id: "teachScan", action: model.scanHere)
                    }
                    action("Save map", icon: "square.and.arrow.down", id: "teachSave", action: model.saveMap)
                }
            }
            .padding(.horizontal, Space.margin)
            .padding(.vertical, Space.l)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(p.background.ignoresSafeArea())
        .onChange(of: model.current) { _, line in announce(line) }
        .onChange(of: model.stopLine) { _, line in announce(line) }
    }

    // MARK: Pieces

    /// Never disabled.
    private var stopButton: some View {
        Button {
            Haptics.shared.tap()
            model.stop()
        } label: {
            HStack(spacing: Space.s) {
                Image(systemName: "stop.fill").font(.system(size: 22, weight: .bold))
                Text("STOP").font(SoughtFont.bigReadout.weight(.bold)).minimumScaleFactor(0.5).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 88)
            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(p.alert))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .softShadow()
        .accessibilityLabel("Stop Soughtbot")
        .accessibilityHint("Sends stop right away, even while another command is running.")
        .accessibilityIdentifier("teachStop")
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let line = model.current {
                statusRow(line)
            } else {
                Text("No command sent yet.").font(SoughtFont.activityBody).foregroundStyle(p.text)
            }
            if let s = model.stopLine { statusRow(s) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.l)
        .soughtGlass(.sheet, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("teachStatus")
    }

    private func statusRow(_ line: TeachPanelModel.Line) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Space.s) {
                Text("\u{201C}\(line.text)\u{201D}").font(SoughtFont.readout).foregroundStyle(p.title)
                Spacer(minLength: Space.s)
                Text(Self.badge(line.phase)).font(SoughtFont.badge).foregroundStyle(badgeColor(line.phase))
            }
            if let detail = Self.detail(line.phase) {
                Text(detail).font(SoughtFont.activityBody).foregroundStyle(p.text).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(title).font(SoughtFont.activityHeading).foregroundStyle(p.sectionTitle).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func action(_ title: String, icon: String, id: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        let on = enabled && !model.busy
        return Button {
            Haptics.shared.tap()
            action()
        } label: {
            HStack(spacing: Space.s) {
                Image(systemName: icon).font(.system(size: 15, weight: .bold))
                Text(title).font(SoughtFont.button).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(p.onPrimary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Capsule().fill(p.primary))
            .opacity(on ? 1 : 0.4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!on)
        .accessibilityIdentifier(id)
    }

    // MARK: Words

    static func badge(_ phase: TeachPanelModel.Phase) -> String {
        switch phase {
        case .sending: return "SENDING"
        case .queued: return "QUEUED"
        case .running: return "RUNNING"
        case .done: return "DONE"
        case .failed: return "FAILED"
        case .stopped: return "STOPPED"
        }
    }

    static func detail(_ phase: TeachPanelModel.Phase) -> String? {
        switch phase {
        case .sending, .queued, .running: return nil
        case .done(let r): return r
        case .failed(let r): return r
        case .stopped: return "Stop sent; no longer following this command."
        }
    }

    private func badgeColor(_ phase: TeachPanelModel.Phase) -> Color {
        switch phase {
        case .sending, .queued, .running: return p.searching
        case .done: return p.found
        case .failed, .stopped: return p.alert
        }
    }

    private func announce(_ line: TeachPanelModel.Line?) {
        guard let line else { return }
        let words = Self.detail(line.phase) ?? Self.badge(line.phase).lowercased()
        UIAccessibility.post(notification: .announcement, argument: "\(line.text): \(words)")
    }
}

/// Home entry point for the remote teach tour.
struct TeachCard: View {
    let action: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        Button {
            Haptics.shared.tap()
            action()
        } label: {
            HStack(spacing: Space.m) {
                Image(systemName: "dpad.fill").font(.system(size: 26, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drive & Teach").font(SoughtFont.callButton)
                    Text("Drive Soughtbot and teach it places").font(SoughtFont.cardMeta)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(p.text)
            .padding(.horizontal, Space.l).padding(.vertical, Space.m)
            .frame(maxWidth: .infinity, minHeight: 64)
            .soughtGlass(.activity, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drive and Teach")
        .accessibilityHint("Drive Soughtbot in small steps, mark places, scan and save the map.")
        .accessibilityIdentifier("teachCard")
    }
}
