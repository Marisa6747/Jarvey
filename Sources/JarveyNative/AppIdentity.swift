import Foundation

enum AppIdentity {
  static let appName = "Jarvey"
  static let voiceMessageHandlerName = "jarveyVoice"
  static let voiceBridgeObjectName = "jarveyVoiceBridge"

  static func applicationSupportRoot(fileManager: FileManager = .default) -> URL {
    let baseDirectory =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: "Library", directoryHint: .isDirectory)
        .appending(path: "Application Support", directoryHint: .isDirectory)
    return baseDirectory.appending(path: appName, directoryHint: .isDirectory)
  }

  static func logsDirectory(fileManager: FileManager = .default) -> URL {
    let logsDirectory = applicationSupportRoot(fileManager: fileManager)
      .appending(path: "logs", directoryHint: .isDirectory)
    try? fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    return logsDirectory
  }
}
