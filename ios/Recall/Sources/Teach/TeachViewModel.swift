import Foundation
import Combine
#if canImport(DriveLinkCore)
import DriveLinkCore
#endif
#if canImport(PoseCore)
import PoseCore
#endif

/// What the Teach screen drives. `DriveLink` conforms in the app target.
public protocol TeachDriving: AnyObject {
    var isConnected: Bool { get }
    func drive(left: Int, right: Int)
    func stop()
}

/// Saves the current ARKit world map. The ARKit adapter implements this.
public protocol TeachMapSaving: AnyObject {
    func saveCurrentMap(completion: @escaping (Result<Void, Error>) -> Void)
}

public final class TeachViewModel: ObservableObject {
    @Published public private(set) var waypoints: [Waypoint] = []
    @Published public private(set) var message: String = ""
    @Published public private(set) var isSaving = false
    @Published public var speed: Double = 150
    /// Typed or spoken text; the view binds a text field, a speech layer may set it.
    @Published public var nameDraft: String = ""

    private let store: WaypointStore
    private let driver: TeachDriving
    private let mapSaver: TeachMapSaving
    private let currentPose: () -> Pose2D?
    private var held: DriveIntent?
    private var enabled = true

    public init(store: WaypointStore, driver: TeachDriving, mapSaver: TeachMapSaving, currentPose: @escaping () -> Pose2D?) {
        self.store = store
        self.driver = driver
        self.mapSaver = mapSaver
        self.currentPose = currentPose
        reload()
    }

    /// Call when the Teach session starts: the `home` waypoint is the origin pose.
    public func beginSession() {
        if let pose = currentPose() {
            do { try store.ensureHome(at: pose) } catch { message = "Could not create home: \(error)" }
        }
        reload()
    }

    // MARK: driving (reuses DrivePad; no second deadman)

    /// `intent` nil means released or cancelled. `enabled` false (backgrounded, needs release) forces stop.
    public func setHeld(_ intent: DriveIntent?, enabled: Bool = true) {
        held = intent
        self.enabled = enabled
        applyDrive()
    }

    public func setSpeed(_ value: Double) { speed = value; applyDrive() }

    public func stopDriving() { held = nil; driver.stop() }

    private func applyDrive() {
        switch DrivePad.action(held: held, speed: Int(speed), isEnabled: enabled && driver.isConnected) {
        case .stop: driver.stop()
        case .drive(let l, let r): driver.drive(left: l, right: r)
        }
    }

    // MARK: waypoints

    /// Marks the current pose. `name` overrides the draft (for spoken text); both are trimmed.
    public func markWaypoint(name: String? = nil) {
        let text = name ?? nameDraft
        guard let pose = currentPose() else { message = "No pose yet. Wait for tracking."; return }
        do {
            let w = try store.addWaypoint(name: text, pose: pose)
            message = "Marked \(w.name)"
            nameDraft = ""
        } catch WaypointStoreError.emptyName {
            message = "Type a name first"
        } catch WaypointStoreError.duplicateName(let n) {
            message = "A waypoint named \(n) already exists"
        } catch { message = "Could not save waypoint: \(error)" }
        reload()
    }

    public func rename(_ w: Waypoint, to name: String) {
        do { try store.rename(id: w.id, to: name); message = "Renamed to \(name)" }
        catch WaypointStoreError.duplicateName(let n) { message = "A waypoint named \(n) already exists" }
        catch WaypointStoreError.homeIsProtected { message = "Home cannot be renamed" }
        catch WaypointStoreError.emptyName { message = "Type a name first" }
        catch { message = "Could not rename: \(error)" }
        reload()
    }

    public func delete(_ w: Waypoint) {
        do { try store.deleteWaypoint(id: w.id); message = "Deleted \(w.name)" }
        catch WaypointStoreError.homeIsProtected { message = "Home cannot be deleted" }
        catch { message = "Could not delete: \(error)" }
        reload()
    }

    // MARK: world map

    public func saveMap() {
        guard !isSaving else { return }
        isSaving = true
        mapSaver.saveCurrentMap { [weak self] result in
            guard let self else { return }
            self.isSaving = false
            switch result {
            case .success: self.message = "Map saved"
            case .failure(let e): self.message = "Map not saved: \(e.localizedDescription)"
            }
        }
    }

    private func reload() { waypoints = (try? store.waypoints()) ?? [] }
}
