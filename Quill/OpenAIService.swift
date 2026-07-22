import Foundation

class OpenAIService {
  static let shared = OpenAIService()

  private var useCloud: Bool { PromptStore.shared.useCloud }
  private var apiKey: String { PromptStore.shared.apiKey }

  /// Cloud 模式用 Cloud endpoint;否則用自帶 endpoint。
  private var baseEndpoint: String {
    useCloud ? PromptStore.shared.cloudEndpoint : PromptStore.shared.apiEndpoint
  }
  private var endpoint: URL {
    let base = baseEndpoint.trimmingCharacters(in: .init(charactersIn: "/"))
    return URL(string: base + "/chat/completions")
      ?? URL(string: "https://api.openai.com/v1/chat/completions")!
  }
  private var isLocalEndpoint: Bool {
    let ep = baseEndpoint
    return ep.contains("localhost") || ep.contains("127.0.0.1")
  }
  /// 能否送出請求:Cloud 模式免 key;自帶模式需 key 或本機端點。
  private var canRequest: Bool {
    useCloud || !apiKey.isEmpty || isLocalEndpoint
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
                    userInfo: [NSLocalizedDescriptionKey: L10n.t("err.tooLong")])
    }

    return content.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 從 OpenAI 錯誤回應抽出可讀訊息。
  /// 401 一律用固定訊息——API 回傳的原文會包含(部分遮蔽的)API key,不可顯示給使用者。
  /// 純函式，供 unit test 使用。
  static func parseAPIError(from data: Data?, statusCode: Int) -> NSError {
    var message: String
    switch statusCode {
    case 401:
      message = L10n.t("err.invalidKey")
    case 429:
      message = L10n.t("err.rateLimited")
    case 500...599:
      message = L10n.t("err.service")
    default:
      message = "Request failed (HTTP \(statusCode))"
    }

    if statusCode != 401,
       let data,
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let error = json["error"] as? [String: Any],
       let apiMessage = error["message"] as? String, !apiMessage.isEmpty {
      message = sanitizeErrorMessage(apiMessage, fallback: message)
    }
    return NSError(domain: "QuillError", code: statusCode,
                   userInfo: [NSLocalizedDescriptionKey: message])
  }

  /// 移除訊息中疑似 API key 的字串(含 * 遮蔽或 sk- 開頭的 token)。
  static func sanitizeErrorMessage(_ raw: String, fallback: String) -> String {
    let words = raw.split(separator: " ")
    let cleaned = words.filter { w in
      !w.contains("***") && !w.hasPrefix("sk-") && !w.hasPrefix("ask-")
    }
    let result = cleaned.joined(separator: " ")
    return result.isEmpty ? fallback : result
  }

  /// 模型輸出偶爾會把純文字包進 markdown 圍欄(```),對 OCR/取代情境是雜訊,拆掉。
  static func stripCodeFences(_ text: String) -> String {
    var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.hasPrefix("```") else { return text }
    guard let firstNewline = t.firstIndex(of: "\n") else { return "" }
    t = String(t[t.index(after: firstNewline)...])
    if t.hasSuffix("```") { t = String(t.dropLast(3)) }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Shared request handling

  private func missingKeyError() -> NSError {
    NSError(
      domain: "QuillError", code: -3,
      userInfo: [NSLocalizedDescriptionKey: L10n.t("err.noKey")]
    )
  }

  private func makeRequest(body: [String: Any]) -> URLRequest {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = Self.requestTimeout
    if useCloud {
      // Cloud 模式:共享密鑰 + 匿名裝置 ID(供每日額度)
      request.setValue("Bearer \(CloudConfig.appSecret)", forHTTPHeaderField: "Authorization")
      request.setValue(CloudConfig.deviceID, forHTTPHeaderField: "X-Quill-Device")
    } else if !apiKey.isEmpty {
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
    guard canRequest else {
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
      "temperature": 0  // 校對/取代情境要求可預期的輸出
    ]

    send(body: body, completion: completion)
  }

  // MARK: - Streaming chat（多輪對話 + 逐字輸出）

  /// 回傳 task 供取消；messages 為 OpenAI chat 格式(可含 image_url content)。
  @discardableResult
  func streamChat(
    messages: [[String: Any]],
    model: String,
    maxTokens: Int = 4000,
    onDelta: @escaping (String) -> Void,
    onComplete: @escaping (Result<String, Error>) -> Void
  ) -> StreamingChatTask? {
    guard canRequest else {
      onComplete(.failure(missingKeyError()))
      return nil
    }
    let body: [String: Any] = [
      "model": model,
      "messages": messages,
      "max_tokens": maxTokens,
      "temperature": 0.3,
      "stream": true
    ]
    return StreamingChatTask(
      request: makeRequest(body: body),
      onDelta: onDelta,
      onComplete: onComplete
    )
  }

  // MARK: - Vision

  func analyzeImage(
    _ imageData: Data,
    prompt: String,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    guard canRequest else {
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

// MARK: - SSE streaming task

/// 解析 OpenAI `stream: true` 的 Server-Sent Events 回應。
/// Delegate callback 跑在 main queue,onDelta/onComplete 可直接更新 UI。
final class StreamingChatTask: NSObject, URLSessionDataDelegate {
  private var urlSession: URLSession!
  private var lineBuffer = ""
  private var fullText = ""
  private var statusCode = 200
  private var errorBody = Data()
  private var finished = false
  private let onDelta: (String) -> Void
  private let onComplete: (Result<String, Error>) -> Void

  init(
    request: URLRequest,
    onDelta: @escaping (String) -> Void,
    onComplete: @escaping (Result<String, Error>) -> Void
  ) {
    self.onDelta = onDelta
    self.onComplete = onComplete
    super.init()
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 60
    urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    urlSession.dataTask(with: request).resume()
  }

  func cancel() {
    finished = true
    urlSession.invalidateAndCancel()
  }

  // MARK: URLSessionDataDelegate

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard !finished else { return }
    // 非 2xx:收集完整 body,結束時丟可讀錯誤
    guard (200...299).contains(statusCode) else {
      errorBody.append(data)
      return
    }
    lineBuffer += String(data: data, encoding: .utf8) ?? ""
    while let newline = lineBuffer.firstIndex(of: "\n") {
      let line = String(lineBuffer[..<newline]).trimmingCharacters(in: .whitespaces)
      lineBuffer.removeSubrange(...newline)
      processLine(line)
    }
  }

  private func processLine(_ line: String) {
    guard line.hasPrefix("data:") else { return }
    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
    if payload == "[DONE]" {
      finish(.success(fullText))
      return
    }
    guard
      let data = payload.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let choices = json["choices"] as? [[String: Any]],
      let first = choices.first
    else { return }

    if let delta = first["delta"] as? [String: Any],
       let content = delta["content"] as? String, !content.isEmpty {
      fullText += content
      onDelta(content)
    }
    if let reason = first["finish_reason"] as? String, !reason.isEmpty, reason != "stop", reason != "null" {
      // e.g. "length" — 內容被截斷,仍回傳已收到的部分,不當成錯誤
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error {
      // 使用者取消不算錯誤
      if (error as NSError).code == NSURLErrorCancelled { return }
      finish(.failure(error))
      return
    }
    guard (200...299).contains(statusCode) else {
      finish(.failure(OpenAIService.parseAPIError(from: errorBody, statusCode: statusCode)))
      return
    }
    finish(.success(fullText))
  }

  private func finish(_ result: Result<String, Error>) {
    guard !finished else { return }
    finished = true
    onComplete(result)
    urlSession.finishTasksAndInvalidate()
  }
}
