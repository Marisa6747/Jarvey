@testable import JarveyNative
import XCTest

final class InputActionRequestParserTests: XCTestCase {
  func testHealthRequestParsesWithoutBody() throws {
    let request = Data("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)

    XCTAssertEqual(try InputActionRequestParser.parse(request), .ready(.health))
  }

  func testScreenshotRequestParsesWithoutBody() throws {
    let request = Data("GET /screenshot HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)

    XCTAssertEqual(try InputActionRequestParser.parse(request), .ready(.screenshot))
  }

  func testActionRequestStaysIncompleteUntilEntireBodyArrives() throws {
    let body = #"{"type":"click","x":10,"y":20,"button":"left"}"#
    let headers = [
      "POST /action HTTP/1.1",
      "Host: localhost",
      "Content-Type: application/json",
      "Content-Length: \(body.utf8.count)",
      "",
      ""
    ].joined(separator: "\r\n")

    let partialRequest = Data((headers + String(body.dropLast(3))).utf8)
    XCTAssertEqual(try InputActionRequestParser.parse(partialRequest), .incomplete)

    let fullRequest = Data((headers + body).utf8)
    XCTAssertEqual(
      try InputActionRequestParser.parse(fullRequest),
      .ready(
        .action(
          InputAction(
            type: .click,
            x: 10,
            y: 20,
            button: .left,
            text: nil,
            keys: nil,
            combo: nil,
            scrollX: nil,
            scrollY: nil,
            fromX: nil,
            fromY: nil,
            toX: nil,
            toY: nil,
            path: nil))))
  }

  func testMissingContentLengthIsRejected() {
    let request = Data(
      [
        "POST /action HTTP/1.1",
        "Host: localhost",
        "Content-Type: application/json",
        "",
        #"{"type":"move","x":1,"y":2}"#
      ].joined(separator: "\r\n").utf8)

    XCTAssertThrowsError(try InputActionRequestParser.parse(request)) { error in
      XCTAssertEqual(error as? InputActionRequestParserError, .missingContentLength)
    }
  }
}
