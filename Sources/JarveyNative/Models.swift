import Foundation

struct ToolRegistryConfig: Codable {
  var enableWebSearch: Bool
  var enableCodeInterpreter: Bool
  var enableImageGeneration: Bool
  var vectorStoreIds: [String]
}

struct SettingsData: Codable {
  var apiKey: String
  var hotkey: String
  var voice: String
  var debugMode: Bool
  var toolRegistry: ToolRegistryConfig

  static let empty = SettingsData(
    apiKey: "",
    hotkey: "Option+Space",
    voice: "marin",
    debugMode: false,
    toolRegistry: ToolRegistryConfig(
      enableWebSearch: true,
      enableCodeInterpreter: true,
      enableImageGeneration: true,
      vectorStoreIds: []
    )
  )
}

struct SettingsPatch: Codable {
  var apiKey: String?
  var hotkey: String?
}

struct HealthSnapshot: Codable {
  var ok: Bool
  var pid: Int
  var inputServerAvailable: Bool
  var inputServerVersion: String?
  var hasApiKey: Bool

  static let offline = HealthSnapshot(
    ok: false,
    pid: 0,
    inputServerAvailable: false,
    inputServerVersion: nil,
    hasApiKey: false
  )
}

struct MemoryRecord: Codable, Identifiable {
  var id: String
  var kind: String
  var subject: String
  var content: String
  var confidence: Double
  var source: String
  var tags: [String]
  var createdAt: String
  var updatedAt: String
}

struct ApprovalRequest: Codable, Identifiable {
  var id: String
  var taskId: String
  var kind: String
  var toolName: String
  var summary: String
  var detail: String?
  var createdAt: String
}

struct BackendTaskResult: Codable {
  var taskId: String
  var summary: String
  var outputText: String
  var agent: String
  var completedAt: String
}

struct BackendEvent: Codable, Identifiable {
  var taskId: String
  var type: String
  var createdAt: String
  var summary: String?
  var detail: String?
  var approvalId: String?
  var approval: ApprovalRequest?
  var result: BackendTaskResult?
  var imageBase64: String?

  var id: String {
    "\(taskId)-\(createdAt)-\(type)"
  }
}

struct StartTaskResponse: Codable {
  var taskId: String
}

struct NativePermissionSnapshot: Equatable {
  var microphone: String
  var screen: String
  var accessibilityTrusted: Bool
  var voiceRuntimeSupported: Bool
}

struct TranscriptEntry: Codable, Identifiable {
  var id: String
  var role: String
  var text: String
  var timestamp: String
  var agent: String?
}

struct VoiceApprovalState: Codable {
  var id: String
  var title: String
  var detail: String?
}

struct VoiceRuntimeState: Codable {
  var connected: Bool
  var muted: Bool
  var phase: String
  var currentAgent: String
  var level: Double
}

struct OverlayActionCallout: Equatable {
  var label: String
  var text: String
}
