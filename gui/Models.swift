import Foundation

enum SlimmingMode: String, CaseIterable, Identifiable {
  case memory = "Memory Use"
  case disk = "Disk Size"
  case derivedData = "Derived Data"

  var id: String { rawValue }
}

struct SimulatorDevice: Decodable, Identifiable, Equatable {
  let udid: String
  let name: String
  let state: String
  let osVersion: String
  let managedDisabled: Int?
  let managedTotal: Int
  let statusError: String?
  let memory: SimulatorMeasurement?
  let memoryError: String?

  var id: String { udid }
  var isBooted: Bool { state == "Booted" }
}

struct SlimCategory: Decodable, Identifiable, Equatable {
  let id: String
  let name: String
  let description: String
  let downside: String
  let approxMemoryMB: Int
  let labels: [String]
  let serviceDescriptions: [String: String]?
  let alwaysEnabled: [AlwaysEnabledService]?

  var alwaysEnabledServices: [AlwaysEnabledService] {
    alwaysEnabled ?? []
  }

  var approximateMemoryText: String {
    "Uses ~\(approxMemoryMB) MB RAM"
  }

  func serviceDescription(for label: String) -> String {
    serviceDescriptions?[label] ?? "Apple background service."
  }
}

struct AlwaysEnabledService: Decodable, Identifiable, Equatable {
  let label: String
  let reason: String

  var id: String { label }
}

struct SimulatorMeasurement: Decodable, Equatable {
  let processes: Int
  let bytes: Int64

  var memoryText: String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
  }
}

struct SimulatorDiskMeasurement: Decodable, Equatable {
  let bytes: Int64

  var sizeText: String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

struct DiskCleanupCategory: Decodable, Identifiable, Equatable {
  let id: String
  let name: String
  let description: String
  let downside: String
  let recovery: String
  let risk: String
  let defaultSelected: Bool
  let canClean: Bool
}

struct SimulatorDiskCleanupMeasurement: Decodable, Equatable {
  let id: String
  let bytes: Int64
  let targets: Int

  var sizeText: String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

struct SimulatorDiskStorageMeasurement: Decodable, Identifiable, Equatable {
  let id: String
  let name: String
  let description: String
  let bytes: Int64

  var sizeText: String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  var systemImage: String {
    switch id {
    case "installed-apps": return "app.dashed"
    case "documents": return "doc"
    case "app-data": return "externaldrive"
    case "user-media": return "photo.on.rectangle"
    default: return "folder"
    }
  }
}

struct SimulatorDiskCleanupPlan: Decodable, Equatable {
  let udid: String
  let totalBytes: Int64
  let cleanableBytes: Int64
  let categories: [SimulatorDiskCleanupMeasurement]
  let storage: [SimulatorDiskStorageMeasurement]

  func bytes(for categoryID: String) -> Int64 {
    categories.first(where: { $0.id == categoryID })?.bytes ?? 0
  }

  func storageBytes(for storageID: String) -> Int64 {
    storage.first(where: { $0.id == storageID })?.bytes ?? 0
  }
}

struct SimulatorDiskCleanupResult: Decodable, Equatable {
  let udid: String
  let categoryIds: [String]
  let beforeBytes: Int64
  let afterBytes: Int64
  let reclaimedBytes: Int64
  let wasBooted: Bool
  let bootStateRestored: Bool

  var reclaimedText: String {
    ByteCountFormatter.string(fromByteCount: reclaimedBytes, countStyle: .file)
  }
}

struct DerivedDataEntry: Decodable, Identifiable, Equatable {
  let id: String
  let name: String
  let directoryName: String
  let path: String
  let kind: String
  let bytes: Int64
  let modifiedAt: Int64
  let sourcePath: String?
  let sourceExists: Bool?
  let packageName: String?
  let packageVersion: String?
  let packagePath: String?
  let productName: String?
  let productPath: String?
  let bundleIdentifier: String?
  let marketingVersion: String?
  let buildNumber: String?
  let configuration: String?
  let platform: String?
  let sdk: String?
  let minimumOSVersion: String?
  let productModifiedAt: Int64?

  var sizeText: String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  var modifiedDate: Date {
    Date(timeIntervalSince1970: TimeInterval(modifiedAt))
  }

  var latestBuildDate: Date? {
    guard let productModifiedAt, productModifiedAt > 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(productModifiedAt))
  }

  var kindTitle: String {
    switch kind {
    case "project": return "Project"
    case "cache": return "Shared Cache"
    default: return "Generated Data"
    }
  }

  var systemImage: String {
    switch kind {
    case "project": return "hammer"
    case "cache": return "shippingbox"
    default: return "folder"
    }
  }

  var sourceDisplayPath: String? {
    guard let sourcePath, !sourcePath.isEmpty else { return nil }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if sourcePath == home {
      return "~"
    }
    if sourcePath.hasPrefix(home + "/") {
      return "~" + sourcePath.dropFirst(home.count)
    }
    return sourcePath
  }

  var sourceIsMissing: Bool {
    sourcePath != nil && sourceExists != true
  }

  var metadataTitle: String {
    firstPresent(bundleIdentifier, productName, kindTitle) ?? kindTitle
  }

  var versionBuildSummary: String? {
    var parts: [String] = []
    if let marketingVersion = present(marketingVersion) {
      parts.append("App \(marketingVersion)")
    }
    if let buildNumber = present(buildNumber) {
      parts.append("Build \(buildNumber)")
    }
    if let packageVersion = present(packageVersion) {
      parts.append("Package \(packageVersion)")
    }
    return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
  }

  var buildContextSummary: String? {
    var parts: [String] = []
    if let configuration = present(configuration) {
      parts.append(configuration)
    }
    if let platform = present(platform) {
      parts.append(platformTitle(platform))
    }
    if let sdkVersion {
      parts.append("SDK \(sdkVersion)")
    }
    if let minimumOSVersion = present(minimumOSVersion) {
      parts.append("min \(minimumOSVersion)")
    }
    return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
  }

  var metadataSearchText: String {
    [
      name, directoryName, kindTitle, sourcePath, packageName, packageVersion, productName,
      bundleIdentifier, marketingVersion, buildNumber, configuration, platform, sdk,
      minimumOSVersion,
    ]
    .compactMap { $0 }
    .joined(separator: " ")
  }

  private var sdkVersion: String? {
    guard let sdk = present(sdk) else { return nil }
    if let platform = present(platform), sdk.hasPrefix(platform) {
      let version = String(sdk.dropFirst(platform.count))
      return version.isEmpty ? sdk : version
    }
    return sdk
  }

  private func platformTitle(_ value: String) -> String {
    switch value.lowercased() {
    case "iphonesimulator": return "iOS Simulator"
    case "iphoneos": return "iOS Device"
    case "appletvsimulator": return "tvOS Simulator"
    case "appletvos": return "tvOS Device"
    case "watchsimulator": return "watchOS Simulator"
    case "watchos": return "watchOS Device"
    case "xrsimulator": return "visionOS Simulator"
    case "xros": return "visionOS Device"
    case "maccatalyst": return "Mac Catalyst"
    case "macosx": return "macOS"
    default: return value
    }
  }

  private func present(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private func firstPresent(_ values: String?...) -> String? {
    values.compactMap { present($0) }.first
  }
}

struct DerivedDataScan: Decodable, Equatable {
  let rootPath: String
  let totalBytes: Int64
  let entries: [DerivedDataEntry]

  var totalSizeText: String {
    guard totalBytes > 0 else { return "0 B" }
    return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
  }
}

struct DerivedDataCleanupResult: Decodable, Equatable {
  let rootPath: String
  let entryIds: [String]
  let deletedEntryIds: [String]
  let beforeBytes: Int64
  let afterBytes: Int64
  let reclaimedBytes: Int64

  var reclaimedText: String {
    ByteCountFormatter.string(fromByteCount: reclaimedBytes, countStyle: .file)
  }
}

struct SimulatorMutationResult: Decodable, Equatable {
  let action: String
  let udid: String
  let name: String?
  let sourceUdid: String?
}

enum ServiceSlimState: Equatable {
  case stock
  case partial(disabled: Int, total: Int)
  case full(total: Int)
  case unknown

  var title: String {
    switch self {
    case .stock: return "Stock"
    case .partial(let disabled, let total): return "Partial (\(disabled)/\(total))"
    case .full(let total): return "Fully slim (\(total)/\(total))"
    case .unknown: return "Unknown while shutdown"
    }
  }

  var systemImage: String {
    switch self {
    case .stock: return "circle.fill"
    case .partial: return "circle.lefthalf.filled"
    case .full: return "circle"
    case .unknown: return "questionmark.circle"
    }
  }
}

struct BatchProgress: Equatable {
  let completed: Int
  let total: Int
  let currentName: String
  let action: String

  var fraction: Double {
    guard total > 0 else { return 0 }
    return Double(completed) / Double(total)
  }
}

struct ActivityEntry: Identifiable, Equatable {
  enum Level {
    case info
    case success
    case failure
  }

  let id = UUID()
  let date = Date()
  let level: Level
  let message: String
}

struct PresentedError: Identifiable {
  let id = UUID()
  let message: String
}
