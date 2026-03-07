import Foundation

struct InputActionRequestParser {
  static func parse(_ data: Data) throws -> InputActionRequestParseResult {
    guard let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) else {
      return .incomplete
    }

    let headerData = data[..<separatorRange.lowerBound]
    guard let headerString = String(data: headerData, encoding: .utf8) else {
      throw InputActionRequestParserError.invalidEncoding
    }

    let lines = headerString.components(separatedBy: "\r\n")
    guard let requestLine = lines.first, !requestLine.isEmpty else {
      throw InputActionRequestParserError.invalidRequestLine
    }

    let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard requestParts.count >= 2 else {
      throw InputActionRequestParserError.invalidRequestLine
    }

    let method = String(requestParts[0]).uppercased()
    let path = String(requestParts[1])
    let headers = parseHeaders(Array(lines.dropFirst()))

    switch (method, path) {
    case ("GET", "/health"):
      return .ready(.health)
    case ("GET", "/screenshot"):
      return .ready(.screenshot)
    case ("POST", "/action"):
      guard let contentLengthValue = headers["content-length"] else {
        throw InputActionRequestParserError.missingContentLength
      }
      guard let contentLength = Int(contentLengthValue), contentLength >= 0 else {
        throw InputActionRequestParserError.invalidContentLength
      }

      let bodyStart = separatorRange.upperBound
      let expectedBodyEnd = data.index(bodyStart, offsetBy: contentLength, limitedBy: data.endIndex)
      guard let expectedBodyEnd else {
        return .incomplete
      }

      if expectedBodyEnd > data.endIndex {
        return .incomplete
      }

      let body = data[bodyStart..<expectedBodyEnd]
      let decoder = JSONDecoder()
      guard let action = try? decoder.decode(InputAction.self, from: body) else {
        throw InputActionRequestParserError.invalidJSON
      }
      return .ready(.action(action))
    case ("GET", _), ("POST", _):
      throw InputActionRequestParserError.unsupportedPath(path)
    default:
      throw InputActionRequestParserError.unsupportedMethod(method)
    }
  }

  private static func parseHeaders(_ lines: [String]) -> [String: String] {
    var headers: [String: String] = [:]
    for line in lines where !line.isEmpty {
      guard let separatorIndex = line.firstIndex(of: ":") else {
        continue
      }
      let name = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let value = line[line.index(after: separatorIndex)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      headers[name] = value
    }
    return headers
  }
}
