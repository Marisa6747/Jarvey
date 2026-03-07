import Foundation
import Network
import ApplicationServices

/// Lightweight HTTP server that accepts input-action requests from the sidecar
/// and executes them via CGEvent inside JarveyNative's process (which has
/// Accessibility permission). Listens on 127.0.0.1:<port>.
final class InputActionServer: @unchecked Sendable {
  private let listener: NWListener
  private let executor = InputActionExecutor()
  private let screenCaptureController = ScreenCaptureController()
  private let permissionCoordinator: PermissionCoordinator
  let port: UInt16

  init(port: UInt16 = 4819, permissionCoordinator: PermissionCoordinator) throws {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    self.listener = listener
    self.port = port
    self.permissionCoordinator = permissionCoordinator
  }

  func start() {
    listener.newConnectionHandler = { [weak self] connection in
      self?.handleConnection(connection)
    }
    listener.start(queue: .global(qos: .userInteractive))
  }

  func stop() {
    listener.cancel()
  }

  private func handleConnection(_ connection: NWConnection) {
    connection.start(queue: .global(qos: .userInteractive))
    receiveRequest(on: connection, buffer: Data())
  }

  private func receiveRequest(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
      guard let self else {
        connection.cancel()
        return
      }

      if error != nil {
        self.sendResponse(
          connection: connection,
          status: 400,
          body: self.responseJSON(ok: false, error: "Request transport failed"))
        return
      }

      var nextBuffer = buffer
      if let data {
        nextBuffer.append(data)
      }

      do {
        switch try InputActionRequestParser.parse(nextBuffer) {
        case .incomplete:
          if isComplete {
            self.sendResponse(
              connection: connection,
              status: 400,
              body: self.responseJSON(ok: false, error: "Incomplete HTTP request"))
            return
          }
          self.receiveRequest(on: connection, buffer: nextBuffer)
        case .ready(let request):
          self.handle(request, connection: connection)
        }
      } catch let error as InputActionRequestParserError {
        self.sendResponse(
          connection: connection,
          status: 400,
          body: self.responseJSON(ok: false, error: error.message))
      } catch {
        self.sendResponse(
          connection: connection,
          status: 400,
          body: self.responseJSON(ok: false, error: error.localizedDescription))
      }
    }
  }

  private func handle(_ request: InputActionRequest, connection: NWConnection) {
    switch request {
    case .health:
      Task { @MainActor [weak self] in
        guard let self else {
          connection.cancel()
          return
        }

        let snapshot = self.permissionCoordinator.refresh(force: true)
        self.sendResponse(
          connection: connection,
          status: 200,
          body: self.responseJSON(
            ok: true,
            extra: [
              "trusted": snapshot.accessibilityTrusted,
              "accessibilityTrusted": snapshot.accessibilityTrusted,
              "screen": snapshot.screen,
              "microphone": snapshot.microphone,
              "voiceRuntimeSupported": snapshot.voiceRuntimeSupported
            ]))
      }
    case .screenshot:
      Task { @MainActor [weak self] in
        guard let self else {
          connection.cancel()
          return
        }

        let snapshot = self.permissionCoordinator.refresh(force: true)
        guard snapshot.screen == "granted" else {
          self.sendResponse(
            connection: connection,
            status: 403,
            body: self.responseJSON(
              ok: false,
              error: "Screen Recording permission is required. Grant access in Privacy & Security > Screen Recording."))
          return
        }

        do {
          let screenshot = try await self.screenCaptureController.captureBase64PNG()
          self.sendResponse(
            connection: connection,
            status: 200,
            body: self.responseJSON(ok: true, extra: ["data": screenshot]))
        } catch {
          self.sendResponse(
            connection: connection,
            status: 500,
            body: self.responseJSON(ok: false, error: error.localizedDescription))
        }
      }
    case .action(let action):
      Task { @MainActor [weak self] in
        guard let self else {
          connection.cancel()
          return
        }

        let snapshot = self.permissionCoordinator.refresh(force: true)
        self.sendResponse(
          connection: connection,
          status: snapshot.accessibilityTrusted ? 200 : 403,
          body: self.executeAction(action, permissions: snapshot))
      }
    }
  }

  private func executeAction(
    _ action: InputAction,
    permissions snapshot: NativePermissionSnapshot
  ) -> String {
    guard snapshot.accessibilityTrusted else {
      return responseJSON(
        ok: false,
        error: "Accessibility permission is required. Grant access in Privacy & Security > Accessibility.")
    }

    do {
      try executor.execute(action)
      return responseJSON(ok: true)
    } catch let error as InputActionError {
      return responseJSON(ok: false, error: error.message)
    } catch {
      return responseJSON(ok: false, error: error.localizedDescription)
    }
  }

  private func sendResponse(connection: NWConnection, status: Int, body: String) {
    let phrase: String
    switch status {
    case 200:
      phrase = "OK"
    case 403:
      phrase = "Forbidden"
    case 500:
      phrase = "Internal Server Error"
    default:
      phrase = "Bad Request"
    }
    let header = "HTTP/1.1 \(status) \(phrase)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
    let response = Data((header + body).utf8)
    connection.send(content: response, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  private func responseJSON(ok: Bool, error: String? = nil, extra: [String: Any] = [:]) -> String {
    var response = extra
    response["ok"] = ok
    if let error {
      response["error"] = error
    }

    guard let data = try? JSONSerialization.data(withJSONObject: response),
          let json = String(data: data, encoding: .utf8) else {
      return #"{"ok":false,"error":"Failed to encode response"}"#
    }
    return json
  }
}
