import Foundation

/// Every on/off switch for unfinished features, in one place. Defaults are the shipping configuration.
///
/// - explore: autonomous Explore. OFF until the unknown-space footprint issue (board T-059) is fixed.
/// - comeToMe: Come-to-me. OFF, frozen by the master plan cut order (docs/00_MASTER_PLAN.md section 7).
struct RecallFeatureFlags: Equatable {
    var exploreEnabled = false
    var comeToMeEnabled = false
}
