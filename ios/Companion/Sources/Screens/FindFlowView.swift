import SwiftUI

// Find flow (plan sections 4 and 5.3): Confirm, Searching, Guiding, Found, Not found, Failed.
// The person is usually not looking at the screen, so every phase change is spoken and guiding uses haptics
// that speed up as the distance drops.

struct FindFlowView: View {
    let request: FindRequest
    @EnvironmentObject private var robot: RobotSource
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = false
    @State private var pulseTask: Task<Void, Never>?
    @State private var lastDistance: Double?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SampleBanner()
                Spacer()
                Button { close() } label: {
                    Image(systemName: "xmark").font(.headline).foregroundStyle(p.text)
                        .frame(width: 44, height: 44).background(Circle().fill(p.micFill))
                }
                .accessibilityLabel(isActive ? "Cancel find" : "Close")
                .accessibilityIdentifier("findClose")
            }
            .padding(.horizontal, Space.margin)
            .padding(.top, Space.l)

            ScrollView {
                VStack(spacing: Space.xl) {
                    if !started { confirm } else { phaseView }
                }
                .id(phaseKey)
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
                .padding(Space.margin)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.clear)
        .animation(reduceMotion ? Motion.fade : Motion.spring, value: phaseKey)
        .onAppear { if request.confirmed { start() } }
        .onChange(of: robot.find?.phase) { _, phase in react(to: phase) }
        .onDisappear { pulseTask?.cancel() }
    }

    /// Changes once per step (not per distance tick), so each step blends into the next exactly once.
    private var phaseKey: String {
        guard started else { return "confirm" }
        switch robot.find?.phase ?? .searching {
        case .searching: return "searching"
        case .driving: return "driving"
        case .arrived: return "arrived"
        case .notFound: return "notFound"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    private var isActive: Bool {
        guard started, let ph = robot.find?.phase else { return false }
        switch ph { case .searching, .driving: return true; default: return false }
    }

    private var label: String { (request.match?.label ?? request.query).lowercased() }

    // MARK: Confirm

    @ViewBuilder private var confirm: some View {
        if let m = request.match {
            photo(m.photo)
            title("Looking for \(m.label.lowercased())?")
            body("Last seen \(m.whereText.lowercased()), \(StatusCopy.ago(m.lastSeen, now: robot.now)).")
            primary("Yes, find it", id: "confirmFind") { start() }
            secondary("Not that", id: "notThat") { close() }
        } else {
            icon("questionmark.circle", color: p.searching)
            title("Soughtbot has not seen \u{201C}\(request.query)\u{201D} yet")
            body("It can look around for it. This works best for things in rooms it has already explored.")
            primary("Ask Soughtbot to look", id: "confirmFind") { start() }
            secondary("Never mind", id: "notThat") { close() }
        }
    }

    // MARK: Phases

    @ViewBuilder private var phaseView: some View {
        switch robot.find?.phase ?? .searching {
        case .searching:
            Radar(color: p.signal, animate: !reduceMotion).frame(width: 180, height: 180)
            title("Looking for your \(label)")
            body(request.match != nil ? "Soughtbot is checking where it last saw it." : "Soughtbot is checking its memory.")
            secondary("Cancel", id: "cancelFind") { cancel() }
        case let .driving(d):
            if let m = request.match { photo(m.photo).frame(maxHeight: 220) }
            if let d {
                Text(String(format: "%.1f m", d)).font(SoughtFont.bigReadout).foregroundStyle(p.text).monospacedDigit()
                    .contentTransition(.numericText(value: d))
                    .animation(reduceMotion ? nil : .snappy, value: d)
                    .accessibilityLabel(String(format: "%.1f meters away", d))
                    .accessibilityIdentifier("distance")
            }
            title("Soughtbot is on its way")
            body(request.match.map { "Heading to the \($0.label.lowercased()), \($0.whereText.lowercased())." } ?? "Heading there now.")
            secondary("Cancel", id: "cancelFind") { cancel() }
        case .arrived:
            icon("checkmark.circle.fill", color: p.found)
            if let m = request.match { photo(m.photo).frame(maxHeight: 200) }
            title("Found your \(label)")
            body(request.match.map { "\($0.whereText). Soughtbot is waiting next to it." } ?? "Soughtbot is waiting next to it.")
            primary("Done", id: "findDone") { close() }
        case .notFound:
            icon("magnifyingglass.circle", color: p.searching)
            title("Soughtbot could not find your \(label)")
            body("It may be somewhere Soughtbot has not explored yet. Try another name, or check the Item Log.")
            primary("Try again", id: "tryAgain") { start() }
            secondary("Close", id: "findDone") { close() }
        case let .failed(reason):
            icon("exclamationmark.triangle.fill", color: p.alert)
            title("Soughtbot stopped")
            body(reason)
            primary("Try again", id: "tryAgain") { start() }
            secondary("Close", id: "findDone") { close() }
        case .cancelled:
            title("Find cancelled")
            primary("Close", id: "findDone") { close() }
        }
    }

    // MARK: Actions

    private func start() {
        started = true
        Haptics.shared.tap()
        robot.startFind(request.query, match: request.match)
        say("Looking for your \(label).")
    }

    private func cancel() {
        robot.cancelFind()
        say("Find cancelled.")
        close()
    }

    private func close() {
        if isActive { robot.cancelFind() }
        pulseTask?.cancel()
        robot.clearFind()
        dismiss()
    }

    private func react(to phase: FindPhase?) {
        guard let phase else { return }
        switch phase {
        case let .driving(d):
            if lastDistance == nil { say("Soughtbot is on its way to your \(label).") }
            lastDistance = d
            startPulses()
        case .arrived:
            pulseTask?.cancel()
            Haptics.shared.success()
            say("Soughtbot found your \(label)" + (request.match.map { ", \($0.whereText.lowercased())." } ?? "."))
        case .notFound:
            pulseTask?.cancel(); Haptics.shared.warning()
            say("Soughtbot could not find your \(label).")
        case let .failed(r):
            pulseTask?.cancel(); Haptics.shared.warning()
            say("Soughtbot stopped. \(r)")
        default: break
        }
    }

    private func startPulses() {
        guard pulseTask == nil || pulseTask!.isCancelled, settings.haptics else { return }
        pulseTask = Task { @MainActor in
            while !Task.isCancelled {
                guard case let .driving(d)? = robot.find?.phase else { return }
                Haptics.shared.tap()
                let wait = Haptics.pulseInterval(distanceM: d ?? 4)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    private func say(_ s: String) {
        Speaker.shared.enabled = settings.voiceFeedback
        Speaker.shared.say(s)
    }

    // MARK: Pieces

    private func photo(_ ph: PhotoRef) -> some View {
        ShadedPhoto(photo: ph, shadeTo: 0.2, radius: Radius.card).aspectRatio(4 / 3, contentMode: .fit).softShadow()
    }

    private func title(_ s: String) -> some View {
        Text(s).font(SoughtFont.largeTitle).foregroundStyle(p.text).multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader).accessibilityIdentifier("findTitle")
    }

    private func body(_ s: String) -> some View {
        Text(s).font(SoughtFont.body).foregroundStyle(p.text).multilineTextAlignment(.center)
    }

    private func icon(_ name: String, color: Color) -> some View {
        Image(systemName: name).font(.system(size: 64)).foregroundStyle(color).accessibilityHidden(true)
            .symbolEffect(.bounce.up, options: .nonRepeating, value: reduceMotion ? "" : phaseKey)
    }

    private func primary(_ s: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(SoughtFont.button).foregroundStyle(p.onPrimary).frame(maxWidth: .infinity, minHeight: 60)
                .background(Capsule().fill(p.primary))
        }
        .buttonStyle(.plain).accessibilityIdentifier(id)
    }

    private func secondary(_ s: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(SoughtFont.button).foregroundStyle(p.text).frame(maxWidth: .infinity, minHeight: 52)
                .background(Capsule().stroke(p.text, lineWidth: 1.5))
        }
        .buttonStyle(.plain).accessibilityIdentifier(id)
    }
}

/// Expanding rings in the signal color while Soughtbot searches.
struct Radar: View {
    var color: Color
    var animate: Bool
    @State private var t = false

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle().stroke(color.opacity(0.5), lineWidth: 2)
                    .scaleEffect(animate ? (t ? 1 : 0.2) : 0.4 + Double(i) * 0.25)
                    .opacity(animate ? (t ? 0 : 0.9) : 0.6)
                    .animation(animate ? .easeOut(duration: 2).repeatForever(autoreverses: false).delay(Double(i) * 0.6) : nil, value: t)
            }
            Image(systemName: "magnifyingglass").font(.system(size: 40, weight: .semibold)).foregroundStyle(color)
        }
        .onAppear { t = true }
        .accessibilityHidden(true)
    }
}
