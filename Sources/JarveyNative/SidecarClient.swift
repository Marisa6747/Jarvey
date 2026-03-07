import Foundation

struct SidecarClient: Sendable {
  let baseURL: URL
  private static let requestTimeout: TimeInterval = 8

  init(baseURL: URL = URL(string: "http://127.0.0.1:4818")!) {
    self.baseURL = baseURL
  }

  func health() async throws -> HealthSnapshot {
    try await request(path: "/health", method: "GET")
  }

  func settings() async throws -> SettingsData {
    try await request(path: "/settings", method: "GET")
  }

  func updateSettings(_ patch: SettingsPatch) async throws -> SettingsData {
    try await request(path: "/settings", method: "PUT", body: patch)
  }

  func recentMemories(limit: Int = 8) async throws -> [MemoryRecord] {
    try await request(path: "/memory/recent?limit=\(limit)", method: "GET")
  }

  func startTask(userRequest: String) async throws -> StartTaskResponse {
    struct Payload: Codable {
      var userRequest: String
    }

    return try await request(
      path: "/backend/tasks",
      method: "POST",
      body: Payload(userRequest: userRequest)
    )
  }

  func approve(taskId: String, approvalId: String) async throws {
    struct Payload: Codable {
      var approvalId: String
      var alwaysApply: Bool = false
    }

    _ = try await request(
      path: "/backend/tasks/\(taskId)/approve",
      method: "POST",
      body: Payload(approvalId: approvalId)
    ) as EmptyResponse
  }

  func reject(taskId: String, approvalId: String, message: String) async throws {
    struct Payload: Codable {
      var approvalId: String
      var alwaysApply: Bool = false
      var message: String
    }

    _ = try await request(
      path: "/backend/tasks/\(taskId)/reject",
      method: "POST",
      body: Payload(approvalId: approvalId, message: message)
    ) as EmptyResponse
  }

  func cancel(taskId: String) async throws {
    _ = try await request(
      path: "/backend/tasks/\(taskId)/cancel",
      method: "POST",
      body: EmptyBody()
    ) as EmptyResponse
  }

  func eventBytes() async throws -> URLSession.AsyncBytes {
    guard let url = URL(string: "/backend/events", relativeTo: baseURL) else {
      throw SidecarClientError.invalidResponse
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    let (bytes, _) = try await URLSession.shared.bytes(for: request)
    return bytes
  }

  func recentBackendEvents(limit: Int = 24, taskId: String? = nil) async throws -> [BackendEvent] {
    var path = "/backend/events/recent?limit=\(limit)"
    if let taskId, !taskId.isEmpty {
      path += "&taskId=\(taskId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? taskId)"
    }
    return try await request(path: path, method: "GET")
  }

  private func request<T: Decodable>(
    path: String,
    method: String
  ) async throws -> T {
    guard let url = URL(string: path, relativeTo: baseURL) else {
      throw SidecarClientError.invalidResponse
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = Self.requestTimeout
    let (data, response) = try await URLSession.shared.data(for: request)
    return try decodeResponse(data: data, response: response)
  }

  private func request<T: Decodable, Body: Encodable>(
    path: String,
    method: String,
    body: Body
  ) async throws -> T {
    guard let url = URL(string: path, relativeTo: baseURL) else {
      throw SidecarClientError.invalidResponse
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = Self.requestTimeout
    request.httpBody = try JSONEncoder().encode(body)

    let (data, response) = try await URLSession.shared.data(for: request)
    return try decodeResponse(data: data, response: response)
  }

  private func decodeResponse<T: Decodable>(data: Data, response: URLResponse) throws -> T {
    guard let http = response as? HTTPURLResponse else {
      throw SidecarClientError.invalidResponse
    }

    guard (200 ... 299).contains(http.statusCode) else {
      if let message = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
        throw SidecarClientError.server(message.error)
      }
      throw SidecarClientError.server("HTTP \(http.statusCode)")
    }

    return try JSONDecoder().decode(T.self, from: data)
  }
}

private struct ErrorResponse: Decodable {
  let error: String
}

private struct EmptyBody: Encodable {}

private struct EmptyResponse: Decodable {}

enum SidecarClientError: LocalizedError {
  case invalidResponse
  case server(String)

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "The sidecar returned an invalid response."
    case .server(let message):
      return message
    }
  }
}
