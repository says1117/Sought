import Foundation
import UIKit

// User pins (Isaac, approved 2026-10-17): "my remote is on this table". A note the person leaves on the map for things
// Soughtbot cannot see. Always marked as the person's, never as a sighting. Saved on this iPhone only (pins.json in
// Application Support); sharing them as object tracks with label_source "user" is an open question on the board.

struct UserPin: Codable, Identifiable, Equatable {
    var id: String
    var label: String
    var note: String?
    var x: Double
    var z: Double
    var place: String          // "On the coffee table"
    var room: String?
    var createdAt: Date
    var photo: Data?           // JPEG, longest side 640
}

/// Extra fields a TrackedObject carries when it is a pin.
struct PinInfo: Equatable {
    var note: String?
    var createdAt: Date
}

enum PinStore {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pins.json")
    }

    static func load() -> [UserPin] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([UserPin].self, from: d)) ?? []
    }

    static func save(_ pins: [UserPin]) {
        guard let d = try? JSONEncoder().encode(pins) else { return }
        try? d.write(to: url, options: [.atomic, .completeFileProtection])
    }

    /// Downscale a picked photo so pins.json stays small.
    static func jpeg(from image: UIImage) -> Data? {
        let maxSide: CGFloat = 640
        let s = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * s, height: image.size.height * s)
        let small = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return small.jpegData(compressionQuality: 0.7)
    }

    /// "On the coffee table" from the nearest taught spot, else "In the kitchen", else "Here".
    static func placeName(x: Double, z: Double, map: MapSnapshot?) -> (place: String, room: String?) {
        let room = map?.room(atX: x, z: z)?.name
        if let w = map?.nearestWaypoint(x: x, z: z), hypot(w.x - x, w.z - z) < 1.2 { return ("On the \(w.name)", room) }
        if let room { return ("In the \(room.lowercased())", room) }
        return ("On the map", nil)
    }
}

extension UserPin {
    var asItem: TrackedObject {
        TrackedObject(id: id, label: label, description: note, x: x, z: z, firstSeen: createdAt, lastSeen: createdAt,
                      sightings: 0, persistence: nil, history: [], whereText: place, room: room,
                      photo: photo.map { .jpeg($0) } ?? .none, pin: PinInfo(note: note, createdAt: createdAt))
    }
}
