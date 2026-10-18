import Foundation

/// Every on/off switch for unfinished features, in one place. Defaults are the shipping configuration.
///
/// - explore: autonomous Explore (live LiDAR grid, Robot tools > Explore preview). T-059 inset is in, but it has never
///   run on the rover, so it stays OFF. Flip to true locally for a supervised floor try.
/// - comeToMe: Come-to-me. OFF, frozen by the master plan cut order (docs/00_MASTER_PLAN.md section 7).
struct RecallFeatureFlags: Equatable {
    var exploreEnabled = false
    var comeToMeEnabled = false
}
