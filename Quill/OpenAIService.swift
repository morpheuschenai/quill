import Foundation

class OpenAIService {
  static let shared = OpenAIService()

  private var apiKey: String { PromptStore.shared.apiKey }
  private var endpoint: URL {
    let base = PromptStore.shared.apiEndpoint.trimmingCharacters(in: .init(charactersIn: "/"))
    return URL(string: base + "/chat/completions")
      ?? URL(string: "https://api.openai.com/v1/chat/completions")!
  }
  private var isLocalEndpoint: Bool {
    let ep = PromptStore.shared.apiEndpoint
    return ep.contains("localhost") || ep.contains("127.0.0.1")
  }
  private static let requestTimeout: TimeInterval = 30

  private init() {}

  // MARK: - Response parsing

  static func parseCompletionContent(from data: Data) throws -> String {
    guard
      let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let choices = json["choices"] as? [[String: Any]],
      let first   = choices.first,
      let message = first["message"] as? [String: Any],
      let content = message["content"] as? String
    else {
      throw NSError(domain: "QuillError", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid API response"])
    }

    // 輸出被截斷（max_tokens 不足）
    if let finishReason = first["finish_reason"] as? String, finishReason == "length" {
      throw NSError(domain: "QuillError", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Selected text is too long to process. Try selecting a shorter passage."])
    }

    return content.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 從 OpenAI 錯誤回應抽出可讀訊息，例如 401 的 "Incorrect API key provided"。
  /// 純函式，供 unit test 使用。
  static func parseAPIError(from data: Data?, statusCode: Int) -> NSError {
    var message = "Request failed (HTTP \(statusCode))"
    if let data,
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let error = json["error"] as? [String: Any],
       let apiMessage = error["message"] as? String, !apiMessage.isEmpty {
      message = apiMessage
    } else {
      switch statusCode {
      case 401: message = "Invalid API key. Check it in Preferences (⌘,)."
      case 429: message = "Rate limited by OpenAI. Try again in a moment."
      case 500...599: message = "OpenAI service error (HTTP \(statusCode)). Try again later."
      default: break
      }
    }
    return NSError(domain: "QuillError", code: statusCode,
                   userInfo: [NSLocalizedDescriptionKey: message])
  }

  // MARK: - Shared request handling

  private func missingKeyError() -> NSError {
    NSError(
      domain: "QuillError", code: -3,
      userInfo: [NSLocalizedDescriptionKey: "API key not set. Open Preferences (⌘,) to add your key."]
    )
  }

  private func makeRequest(body: [String: Any]) -> URLRequest {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = Self.requestTimeout
    if !apiKey.isEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    return request
  }

  private func send(body: [String: Any], completion: @escaping (Result<String, Error>) -> Void) {
    URLSession.shared.dataTask(with: makeRequest(body: body)) { data, response, error in
      if let error {
        completion(.failure(error))
        return
      }

      if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        completion(.failure(Self.parseAPIError(from: data, statusCode: http.statusCode)))
        return
      }

      guard let data else {
        completion(.failure(
          NSError(domain: "QuillError", code: -1,
                  userInfo: [NSLocalizedDescriptionKey: "Invalid API response"])
        ))
        return
      }

      do {
        completion(.success(try Self.parseCompletionContent(from: data)))
      } catch {
        completion(.failure(error))
      }
    }.resume()
  }

  // MARK: - Text completion

  func complete(
    prompt systemPrompt: String,
    text: String,
    maxTokens: Int = 500,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    guard !apiKey.isEmpty || isLocalEndpoint else {
      completion(.failure(missingKeyError()))
      return
    }

    // 動態調整：確保輸出上限不低於輸入長度
    // 粗估 1 token ≈ 2 字元（英中混合），加 150 buffer，上限 2000
    let estimatedInputTokens = text.count / 2
    let effectiveMaxTokens   = min(max(maxTokens, estimatedInputTokens + 150), 2000)

    let body: [String: Any] = [
      "model": PromptStore.shared.textModel,
      "messages": [
        ["role": "system", "content": systemPrompt],
        ["role": "user",   "content": text]
      ],
      "max_tokens": effectiveMaxTokens,
      "temperature": 0.3
    ]

    send(body: body, completion: completion)
  }

  // MARK: - Vision

  func analyzeImage(
    _ imageData: Data,
    prompt: String,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    guard !apiKey.isEmpty || isLocalEndpoint else {
      completion(.failure(missingKeyError()))
      return
    }

    let base64 = imageData.base64EncodedString()

    let body: [String: Any] = [
      "model": PromptStore.shared.visionModel,
      "messages": [[
        "role": "user",
        "content": [
          ["type": "text", "text": prompt],
          ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(base64)"]]
        ]
      ]],
      "max_tokens": 1000
    ]

    send(body: body, completion: completion)
  }
}
