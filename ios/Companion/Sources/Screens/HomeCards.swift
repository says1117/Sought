import SwiftUI

// Home cards shared by HomeView: map widget, Call SoughtBot, Live View (card and full screen).

// MARK: - Cards

struct MapWidget: View {
    @EnvironmentObject private var robot: RobotSource
    @Environment(\.palette) private var p

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let map = robot.map {
                MapCanvas(map: map, robot: robot.status.pose, showLabels: false,
                          active: robot.status.isOnline(now: robot.now) && robot.status.state != .idle, fillWidth: true)
                    .background(p.surface)
            } else {
                p.surface.overlay(Text("No map yet. Teach Soughtbot the room first.").font(SoughtFont.cardMeta).foregroundStyle(p.text))
            }
            LinearGradient(stops: [.init(color: .clear, location: 0.6), .init(color: Color(red: 39 / 255, green: 208 / 255, blue: 246 / 255, opacity: 0.45), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            Text(robot.currentRoom ?? (robot.status.isOnline(now: robot.now) ? "Mapping" : "Last known spot"))
                .font(SoughtFont.mapLabel).foregroundStyle(p.isHighContrast ? p.text : Color(hex: 0x0F1E24))
                .padding(.trailing, 4)   // italic overhang
                .padding(.horizontal, Space.l).padding(.bottom, Space.s)
        }
        .frame(height: 141)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .softShadow()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map. " + (robot.currentRoom.map { "Soughtbot is in the \($0.lowercased())." } ?? "Soughtbot's position is unknown."))
        .accessibilityIdentifier("mapWidget")
    }
}

struct CallCard: View {
    @EnvironmentObject private var robot: RobotSource
    @EnvironmentObject private var router: Router
    @Environment(\.palette) private var p
    @State private var notice: String?

    var body: some View {
        let coming = robot.status.state == .comingToUser
        Button {
            Haptics.shared.tap()
            if coming || (robot.canComeToMe && robot.status.isOnline(now: robot.now)) {
                router.showComeToMe = true
            } else {
                notice = robot.status.isOnline(now: robot.now) ? "Not connected yet" : "Soughtbot is offline"
                UIAccessibility.post(notification: .announcement, argument: notice)
            }
        } label: {
            HStack(spacing: Space.s) {
                Image("icon_eye").renderingMode(.template).resizable().frame(width: 36, height: 36)
                Text(coming ? "Coming to you" : "Call SoughtBot").font(SoughtFont.callButton).multilineTextAlignment(.leading)
                    .lineLimit(3).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
            .foregroundStyle(p.onPrimary)
            .padding(.horizontal, Space.m).padding(.vertical, Space.l)
            .frame(maxWidth: .infinity, minHeight: 87)
            .soughtGlass(.call, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if coming { Circle().fill(p.signal).frame(width: 8, height: 8).padding(Space.s) }
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice).font(SoughtFont.cardMeta).foregroundStyle(p.text)
                    .padding(.horizontal, Space.s).padding(.vertical, 2)
                    .background(Capsule().fill(p.surface))
                    .offset(y: 14)
                    .task { try? await Task.sleep(nanoseconds: 3_000_000_000); self.notice = nil }
            }
        }
        .accessibilityLabel(coming ? "Soughtbot is coming to you" : "Call Soughtbot")
        .accessibilityHint(coming ? "Double tap to see where it is." : "Choose where you are, and Soughtbot drives there.")
        .accessibilityIdentifier("callButton")
    }
}

struct LiveViewCard: View {
    var onOpen: () -> Void
    @EnvironmentObject private var robot: RobotSource
    @Environment(\.palette) private var p

    var body: some View {
        let latest = robot.recentFinds.first
        Button(action: onOpen) {
            ZStack(alignment: .bottomLeading) {
                if let f = robot.liveFrame {
                    ShadedPhoto(photo: .jpeg(f.jpegData(compressionQuality: 0.6) ?? Data()), shadeTo: 0.48, radius: Radius.card)
                } else {
                    ShadedPhoto(photo: latest?.photo ?? .none, shadeTo: 0.48, radius: Radius.card)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if robot.liveFrame == nil, let latest {
                        Text("Last snapshot, \(StatusCopy.ago(latest.lastSeen, now: robot.now))").font(SoughtFont.cardMeta)
                    }
                    HStack(spacing: Space.xs) {
                        Text(robot.liveFrame == nil ? "Snapshot" : "Live View").font(SoughtFont.liveView)
                        Image("icon_video").renderingMode(.template)
                        if robot.liveFrame != nil { Circle().fill(p.signal).frame(width: 7, height: 7) }
                    }
                }
                .foregroundStyle(p.textOnDark)
                .padding(Space.s)
            }
            .shadow(color: .black.opacity(0.15), radius: 2, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(robot.liveFrame != nil ? "Live view from Soughtbot's camera" :
                                "Last snapshot from Soughtbot" + (latest.map { ", \(StatusCopy.agoSpoken($0.lastSeen, now: robot.now))" } ?? ""))
        .accessibilityHint("Double tap to open full screen.")
        .accessibilityIdentifier("liveViewCard")
    }
}

// MARK: - Activity and live view screens

struct LiveViewScreen: View {
    @EnvironmentObject private var robot: RobotSource
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            Group {
                if let f = robot.liveFrame { Image(uiImage: f).resizable().scaledToFit() }
                else if let o = robot.recentFinds.first { PhotoView(photo: o.photo).scaledToFit() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(robot.liveFrame != nil ? "Live camera view" : "Last snapshot")
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    SampleBanner()
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.title2.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(Circle().fill(.black.opacity(0.4)))
                    }
                    .accessibilityLabel("Close")
                }
                Text(robot.liveFrame != nil ? "Live from Soughtbot. Stays on your home network, never uploaded."
                                            : "No live video in this build. Showing the last snapshot.")
                    .font(SoughtFont.cardMeta).foregroundStyle(.white)
                    .padding(Space.s).background(RoundedRectangle(cornerRadius: Radius.thumb, style: .continuous).fill(.black.opacity(0.45)))
            }
            .padding(Space.l)
        }
    }
}
