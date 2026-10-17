import Foundation

public enum ModelAsset: String, CaseIterable {
    case textModel = "MobileCLIP_S0_Text.mlmodelc"
    case imageModel = "MobileCLIP_S0_Image.mlmodelc"
    case vocab = "vocab.json"
    case merges = "merges.txt"
}

public struct ModelLocatorError: Error, Equatable, CustomStringConvertible {
    public let missing: [ModelAsset]
    public let searched: [String]

    /// Short sentence for the robot to say aloud.
    public var spokenMessage: String {
        "I can't search by name yet because my vision models aren't installed on this phone."
    }
    public var description: String {
        "Missing \(missing.map(\.rawValue).joined(separator: ", ")); searched \(searched.joined(separator: ", ")). "
        + "Produce them with ml/conversion (see ios/Recall/Sources/MLEncoders/README.md)."
    }
}

public struct ModelLocations: Equatable {
    public let textModel: URL
    public let imageModel: URL
    public let tokenizerDirectory: URL
    public let vocab: URL
    public let merges: URL
}

/// Finds the (uncommitted) compiled models and tokenizer files: app bundle first, then
/// Application Support/Recall/Models. Each asset is resolved independently.
public struct ModelLocator {
    public var bundles: [Bundle]
    public var applicationSupport: URL?
    public var fileManager: FileManager

    public init(bundles: [Bundle] = [Bundle.main], applicationSupport: URL? = ModelLocator.defaultApplicationSupport(),
                fileManager: FileManager = .default) {
        self.bundles = bundles; self.applicationSupport = applicationSupport; self.fileManager = fileManager
    }

    public static func defaultApplicationSupport() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Recall/Models", isDirectory: true)
    }

    public func locate(_ asset: ModelAsset) -> URL? {
        let name = (asset.rawValue as NSString)
        for b in bundles {
            if let u = b.url(forResource: name.deletingPathExtension, withExtension: name.pathExtension),
               fileManager.fileExists(atPath: u.path) { return u }
            if let root = b.resourceURL {
                let u = root.appendingPathComponent(asset.rawValue)
                if fileManager.fileExists(atPath: u.path) { return u }
            }
        }
        if let dir = applicationSupport {
            let u = dir.appendingPathComponent(asset.rawValue)
            if fileManager.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    public func locateAll() throws -> ModelLocations {
        var found: [ModelAsset: URL] = [:]
        var missing: [ModelAsset] = []
        for a in ModelAsset.allCases { if let u = locate(a) { found[a] = u } else { missing.append(a) } }
        guard missing.isEmpty, let t = found[.textModel], let i = found[.imageModel],
              let v = found[.vocab], let m = found[.merges] else {
            let searched = bundles.compactMap { $0.resourceURL?.path } + [applicationSupport?.path].compactMap { $0 }
            throw ModelLocatorError(missing: missing, searched: searched)
        }
        return ModelLocations(textModel: t, imageModel: i, tokenizerDirectory: v.deletingLastPathComponent(), vocab: v, merges: m)
    }
}
