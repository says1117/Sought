import Foundation
#if canImport(CoreML)
import CoreML
#endif

public enum ModelAsset: String, CaseIterable {
    case textModel = "MobileCLIP_S0_Text.mlmodelc"
    case imageModel = "MobileCLIP_S0_Image.mlmodelc"
    case vocab = "vocab.json"
    case merges = "merges.txt"

    var isModel: Bool { rawValue.hasSuffix(".mlmodelc") }
    /// The uncompiled package the converter writes (`ml/conversion/convert.py`), accepted in Application Support.
    var packageName: String? { isModel ? String(rawValue.dropLast("mlmodelc".count)) + "mlpackage" : nil }

    /// File name to look for under `config`. The raw values are the MobileCLIP-S0 defaults; the two models take
    /// their names from the config, the tokenizer files never change.
    public func fileName(for config: ModelConfig) -> String {
        switch self {
        case .textModel: return config.textModel + ".mlmodelc"
        case .imageModel: return config.imageModel + ".mlmodelc"
        case .vocab, .merges: return rawValue
        }
    }
}

public struct ModelLocatorError: Error, Equatable, CustomStringConvertible {
    public let missing: [ModelAsset]
    /// The file names that were looked for, in the order of `missing` (config-specific; defaults to the raw values).
    public let missingNames: [String]
    public let searched: [String]
    /// Extra facts, e.g. "found MobileCLIP_S0_Text.mlpackage but compiling it failed: ...".
    public let details: [String]

    public init(missing: [ModelAsset], searched: [String], details: [String] = [], missingNames: [String]? = nil) {
        self.missing = missing; self.searched = searched; self.details = details
        self.missingNames = missingNames ?? missing.map(\.rawValue)
    }

    /// Short sentence for the robot to say aloud.
    public var spokenMessage: String {
        "I can't search by name yet because my vision models aren't installed on this phone."
    }
    public var description: String {
        "Missing \(missingNames.joined(separator: ", ")); searched \(searched.joined(separator: ", ")). "
        + (details.isEmpty ? "" : details.joined(separator: " ") + " ")
        + "Install the model folder with ml/conversion/install_models.sh (it must contain both .mlpackage/.mlmodelc models, "
        + "vocab.json, merges.txt and, for a non-MobileCLIP model, model_config.json; see ml/conversion/README.md)."
    }
}

public struct ModelLocations: Equatable {
    public let config: ModelConfig
    public let textModel: URL
    public let imageModel: URL
    public let tokenizerDirectory: URL
    public let vocab: URL
    public let merges: URL
}

/// Finds the (uncommitted) compiled models and tokenizer files. Each asset is resolved independently, searching in order:
///   (`model_config.json` is found the same way and names the models; absent = MobileCLIP-S0 defaults)
///   1. the app bundle root (where Xcode puts `<model>.mlmodelc` compiled from a bundled `.mlpackage`, and
///      flattened resources such as `vocab.json`)
///   2. the app bundle's subfolders, recursively (folder references)
///   3. `Application Support/Recall/Models/`: `.mlmodelc`, `vocab.json`, `merges.txt`, and also a raw `.mlpackage`,
///      which is compiled once with `MLModel.compileModel(at:)` and cached in `Application Support/Recall/Models/Compiled/`.
public struct ModelLocator {
    public var bundles: [Bundle]
    public var applicationSupport: URL?
    public var fileManager: FileManager
    /// Compiles a `.mlpackage` and returns the temporary `.mlmodelc` URL. Injectable for tests.
    public var compiler: (URL) throws -> URL

    public init(bundles: [Bundle] = [Bundle.main], applicationSupport: URL? = ModelLocator.defaultApplicationSupport(),
                fileManager: FileManager = .default, compiler: @escaping (URL) throws -> URL = ModelLocator.defaultCompiler) {
        self.bundles = bundles; self.applicationSupport = applicationSupport; self.fileManager = fileManager
        self.compiler = compiler
    }

    public static func defaultApplicationSupport() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Recall/Models", isDirectory: true)
    }

    public static let defaultCompiler: (URL) throws -> URL = { url in
        #if canImport(CoreML)
        return try MLModel.compileModel(at: url)
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    /// Where compiled copies of Application Support packages are cached.
    var compiledCacheDirectory: URL? { applicationSupport?.appendingPathComponent("Compiled", isDirectory: true) }

    /// Finds an asset that needs no compiling (bundle root, bundle subfolders, Application Support), under the
    /// MobileCLIP-S0 default name. Use `locate(_:config:)` for a configured model.
    public func locate(_ asset: ModelAsset) -> URL? { locate(fileName: asset.rawValue) }

    public func locate(_ asset: ModelAsset, config: ModelConfig) -> URL? { locate(fileName: asset.fileName(for: config)) }

    func locate(fileName: String) -> URL? {
        let name = fileName as NSString
        for b in bundles {
            if let u = b.url(forResource: name.deletingPathExtension, withExtension: name.pathExtension),
               fileManager.fileExists(atPath: u.path) { return u }
            guard let root = b.resourceURL else { continue }
            let direct = root.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: direct.path) { return direct }
            if let u = findRecursively(fileName, under: root) { return u }
        }
        if let dir = applicationSupport {
            let u = dir.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// Reads `model_config.json` (same search order as the models). Absent -> MobileCLIP-S0 defaults. Present but
    /// unreadable or invalid -> throws `ModelConfigError` (never silently falls back, which would feed a 224 px
    /// model 256 px images).
    public func loadConfig() throws -> ModelConfig {
        guard let url = locate(fileName: ModelConfig.fileName) else { return .mobileClipS0 }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ModelConfigError(reason: "cannot read \(url.path): \(error.localizedDescription)") }
        return try ModelConfig.parse(data)
    }

    private func findRecursively(_ filename: String, under root: URL) -> URL? {
        guard let it = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in it {
            if u.lastPathComponent == filename { return u }
            // never descend into compiled models / packages / frameworks
            if ["mlmodelc", "mlpackage", "framework", "bundle"].contains(u.pathExtension) { it.skipDescendants() }
        }
        return nil
    }

    /// Compiles `Application Support/.../X.mlpackage` once and returns the cached `.mlmodelc`; nil if there is no
    /// package. A cached copy is reused while it is at least as new as the package. Throws if compiling fails.
    func compiledFromPackage(fileName: String) throws -> URL? {
        guard fileName.hasSuffix(".mlmodelc"), let dir = applicationSupport, let cacheDir = compiledCacheDirectory else { return nil }
        let pkgName = String(fileName.dropLast("mlmodelc".count)) + "mlpackage"
        let package = dir.appendingPathComponent(pkgName)
        guard fileManager.fileExists(atPath: package.path) else { return nil }
        let cached = cacheDir.appendingPathComponent(fileName)
        func modified(_ u: URL) -> Date? { (try? fileManager.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
        if fileManager.fileExists(atPath: cached.path), let c = modified(cached), let p = modified(package), c >= p { return cached }
        let tmp = try compiler(package)
        try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: cached.path) { try fileManager.removeItem(at: cached) }
        try fileManager.moveItem(at: tmp, to: cached)
        return cached
    }

    public func locateAll() throws -> ModelLocations {
        let config = try loadConfig()
        var found: [ModelAsset: URL] = [:]
        var missing: [ModelAsset] = []
        var details: [String] = []
        for a in ModelAsset.allCases {
            let name = a.fileName(for: config)
            if let u = locate(fileName: name) { found[a] = u; continue }
            do { if let u = try compiledFromPackage(fileName: name) { found[a] = u; continue } }
            catch { details.append("Found \(name.replacingOccurrences(of: ".mlmodelc", with: ".mlpackage")) but compiling it failed: \(error).") }
            missing.append(a)
        }
        guard missing.isEmpty, let t = found[.textModel], let i = found[.imageModel],
              let v = found[.vocab], let m = found[.merges] else {
            let searched = bundles.compactMap { $0.resourceURL?.path } + [applicationSupport?.path].compactMap { $0 }
            throw ModelLocatorError(missing: missing, searched: searched, details: details,
                                    missingNames: missing.map { $0.fileName(for: config) })
        }
        return ModelLocations(config: config, textModel: t, imageModel: i, tokenizerDirectory: v.deletingLastPathComponent(), vocab: v, merges: m)
    }
}
