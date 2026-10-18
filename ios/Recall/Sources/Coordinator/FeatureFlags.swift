import Foundation

/// Every on/off switch for unfinished features, in one place. Defaults are the shipping configuration.
///
/// - explore: autonomous Explore (live LiDAR grid, Robot tools > Explore preview). T-059 inset is in, but it has never
///   run on the rover, so it stays OFF. Flip to true locally for a supervised floor try.
/// - comeToMe: paired-phone, foreground approach. Requires explicit pairing and fresh range/direction; no range-only search.
/// - comeToPlace: Come to me v2, waypoint version (T-066): drive to a taught place along taught routes. ON; every leg
///   is a guarded Controller.goTo under the drive lease, the same motion as go_to_waypoint.
struct RecallFeatureFlags: Equatable {
    var exploreEnabled = false
    var comeToMeEnabled = true
    var comeToPlaceEnabled = true
}
