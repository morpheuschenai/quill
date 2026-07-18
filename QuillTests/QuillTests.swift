import XCTest
import ApplicationServices
@testable import Quill

final class QuillTests: XCTestCase {

  // MARK: - OpenAIService parsing

  func testOpenAIResponseParsingSucceedsForValidResponse() throws {
    let data = """
      {
        "choices": [
          {
            "message": {
              "content": "  Polished result.\\n"
            }
          }
        ]
      }
      """.data(using: .utf8)!

    let result = try OpenAIService.parseCompletionContent(from: data)

    XCTAssertEqual(result, "Polished result.")
  }

  func testOpenAIResponseParsingFailsGracefullyForMalformedResponse() {
    let data = #"{"choices":[{"message":{}}]}"#.data(using: .utf8)!

    XCTAssertThrowsError(try OpenAIService.parseCompletionContent(from: data)) { error in
      let nsError = error as NSError
      XCTAssertEqual(nsError.domain, "QuillError")
      XCTAssertEqual(nsError.code, -1)
      XCTAssertEqual(nsError.localizedDescription, "Invalid API response")
    }
  }

  func testOpenAIResponseParsingThrowsWhenOutputTruncated() {
    let data = """
      {
        "choices": [
          {
            "message": { "content": "partial" },
            "finish_reason": "length"
          }
        ]
      }
      """.data(using: .utf8)!

    XCTAssertThrowsError(try OpenAIService.parseCompletionContent(from: data)) { error in
      XCTAssertEqual((error as NSError).code, -2)
    }
  }

  // MARK: - OpenAIService error parsing

  func testAPIError401NeverLeaksKeyFromErrorBody() {
    // 401 的 API 原文會含(部分遮蔽的)key,必須一律改用固定訊息
    let data = #"{"error":{"message":"Incorrect API key provided: ask-proj******GuAA","type":"invalid_request_error"}}"#
      .data(using: .utf8)!

    let error = OpenAIService.parseAPIError(from: data, statusCode: 401)

    XCTAssertEqual(error.code, 401)
    XCTAssertFalse(error.localizedDescription.contains("ask-proj"))
    XCTAssertFalse(error.localizedDescription.contains("***"))
    XCTAssertTrue(error.localizedDescription.contains("API key"))
  }

  func testAPIErrorUsesSanitizedMessageForNon401() {
    let data = #"{"error":{"message":"You exceeded your quota for key sk-abc123","type":"insufficient_quota"}}"#
      .data(using: .utf8)!

    let error = OpenAIService.parseAPIError(from: data, statusCode: 429)

    XCTAssertTrue(error.localizedDescription.contains("exceeded your quota"))
    XCTAssertFalse(error.localizedDescription.contains("sk-abc123"))
  }

  func testStripCodeFences() {
    XCTAssertEqual(OpenAIService.stripCodeFences("```\nhello\nworld\n```"), "hello\nworld")
    XCTAssertEqual(OpenAIService.stripCodeFences("```swift\nlet x = 1\n```"), "let x = 1")
    XCTAssertEqual(OpenAIService.stripCodeFences("plain text"), "plain text")
  }

  func testAPIErrorFallsBackToReadableMessagePerStatusCode() {
    XCTAssertTrue(
      OpenAIService.parseAPIError(from: nil, statusCode: 401)
        .localizedDescription.contains("API key")
    )
    XCTAssertTrue(
      OpenAIService.parseAPIError(from: nil, statusCode: 429)
        .localizedDescription.contains("Rate limited")
    )
    XCTAssertTrue(
      OpenAIService.parseAPIError(from: nil, statusCode: 503)
        .localizedDescription.contains("HTTP 503")
    )
    // 不認識的狀態碼也要有泛用訊息
    XCTAssertTrue(
      OpenAIService.parseAPIError(from: nil, statusCode: 418)
        .localizedDescription.contains("HTTP 418")
    )
  }

  func testAPIErrorIgnoresMalformedErrorBody() {
    let data = #"{"unexpected":"shape"}"#.data(using: .utf8)!
    let error = OpenAIService.parseAPIError(from: data, statusCode: 429)
    XCTAssertTrue(error.localizedDescription.contains("Rate limited"))
  }

  // MARK: - Model configuration

  func testModelDefaultsWhenUnset() {
    UserDefaults.standard.removeObject(forKey: "quill_text_model")
    UserDefaults.standard.removeObject(forKey: "quill_vision_model")
    XCTAssertEqual(PromptStore.shared.textModel,   PromptStore.defaultTextModel)
    XCTAssertEqual(PromptStore.shared.visionModel, PromptStore.defaultVisionModel)
  }

  // MARK: - TextCapture editable detection

  func testDetectEditableRecognizesEditableRoles() {
    XCTAssertTrue(TextCapture.detectEditable(role: "AXTextField",   axEditable: nil))
    XCTAssertTrue(TextCapture.detectEditable(role: "AXTextArea",    axEditable: nil))
    XCTAssertTrue(TextCapture.detectEditable(role: "AXComboBox",    axEditable: nil))
    XCTAssertTrue(TextCapture.detectEditable(role: "AXSearchField", axEditable: nil))
  }

  func testDetectEditableFallsBackToAXEditableAttribute() {
    XCTAssertTrue(TextCapture.detectEditable(role: "AXStaticText", axEditable: true))
    XCTAssertFalse(TextCapture.detectEditable(role: "AXStaticText", axEditable: false))
    XCTAssertFalse(TextCapture.detectEditable(role: "AXStaticText", axEditable: nil))
    XCTAssertFalse(TextCapture.detectEditable(role: nil, axEditable: nil))
    XCTAssertTrue(TextCapture.detectEditable(role: nil, axEditable: true))
  }

  // MARK: - PromptStore

  func testPaletteIndexWrapsAround() {
    let store = PromptStore.shared
    let config = PromptConfig(
      title: "t", systemPrompt: "p",
      maxTokens: 100, iconName: "i",
      colorIndex: PromptStore.palette.count + 2  // out of range → 應 wrap 而非 crash
    )
    let prompt = store.toPrompt(config)
    XCTAssertEqual(prompt.title, "t")
  }
}
