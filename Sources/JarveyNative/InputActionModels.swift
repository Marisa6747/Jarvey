import Foundation
import CoreGraphics
import Carbon.HIToolbox

enum InputActionRequest: Equatable {
  case health
  case screenshot
  case action(InputAction)
}

enum InputActionRequestParseResult: Equatable {
  case incomplete
  case ready(InputActionRequest)
}

enum InputActionRequestParserError: Error, Equatable {
  case invalidEncoding
  case invalidRequestLine
  case unsupportedMethod(String)
  case unsupportedPath(String)
  case missingContentLength
  case invalidContentLength
  case invalidJSON

  var message: String {
    switch self {
    case .invalidEncoding:
      return "Request is not valid UTF-8"
    case .invalidRequestLine:
      return "Malformed HTTP request line"
    case .unsupportedMethod(let method):
      return "Unsupported HTTP method '\(method)'"
    case .unsupportedPath(let path):
      return "Unsupported path '\(path)'"
    case .missingContentLength:
      return "Missing Content-Length header"
    case .invalidContentLength:
      return "Invalid Content-Length header"
    case .invalidJSON:
      return "Request body is not valid JSON"
    }
  }
}

struct InputAction: Codable, Equatable {
  var type: InputActionType
  var x: Double?
  var y: Double?
  var button: MouseButtonName?
  var text: String?
  var keys: [String]?
  var combo: String?
  var scrollX: Double?
  var scrollY: Double?
  var fromX: Double?
  var fromY: Double?
  var toX: Double?
  var toY: Double?
  var path: [InputPoint]?
}

enum InputActionType: String, Codable, Equatable {
  case click
  case doubleClick = "double_click"
  case move
  case scroll
  case type
  case keypress
  case hotkey
  case drag
}

enum MouseButtonName: String, Codable, Equatable {
  case left
  case right
  case wheel
  case back
  case forward
}

struct InputPoint: Codable, Equatable {
  var x: Double
  var y: Double
}

enum InputActionError: Error, Equatable {
  case missingField(String)
  case invalidField(String)

  var message: String {
    switch self {
    case .missingField(let field):
      return "Missing required field '\(field)'"
    case .invalidField(let reason):
      return reason
    }
  }
}

enum KeyboardModifier: Equatable {
  case command
  case shift
  case option
  case control

  var keyCode: CGKeyCode {
    switch self {
    case .command:
      return 55
    case .shift:
      return 56
    case .option:
      return 58
    case .control:
      return 59
    }
  }

  var flag: CGEventFlags {
    switch self {
    case .command:
      return .maskCommand
    case .shift:
      return .maskShift
    case .option:
      return .maskAlternate
    case .control:
      return .maskControl
    }
  }
}

enum ParsedKeyboardAction: Equatable {
  case singleModifier(KeyboardModifier)
  case singleKey(CGKeyCode)
  case combo(ParsedHotkey)
}

struct ParsedHotkey: Equatable {
  let modifiers: [KeyboardModifier]
  let keyCodes: [CGKeyCode]
}

struct MouseEventSpec {
  let mouseButton: CGMouseButton
  let buttonNumber: Int64
  let downType: CGEventType
  let upType: CGEventType
  let dragType: CGEventType
}
