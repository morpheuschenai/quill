import AppKit
import Combine
import Foundation

struct BillingStatus: Decodable {
  struct Subscription: Decodable {
    let status: String
    let currentAmount: Int?
    let nextAmount: Int
    let cancelAtPeriodEnd: Bool
    let cancelEffectiveAt: Date?

    enum CodingKeys: String, CodingKey {
      case status
      case currentAmount = "current_amount"
      case nextAmount = "next_amount"
      case cancelAtPeriodEnd = "cancel_at_period_end"
      case cancelEffectiveAt = "cancel_effective_at"
    }
  }

  struct Promotion: Decodable {
    let active: Bool?
    let firstMonthAmount: Int
    let recurringAmount: Int
    let endsAt: Date

    enum CodingKeys: String, CodingKey {
      case active
      case firstMonthAmount = "first_month_amount"
      case recurringAmount = "recurring_amount"
      case endsAt = "ends_at"
    }
  }

  let plan: String
  let used: Int
  let limit: Int
  let remaining: Int
  let resetsAt: Date
  let subscription: Subscription?
  let promotion: Promotion

  enum CodingKeys: String, CodingKey {
    case plan, used, limit, remaining, subscription, promotion
    case resetsAt = "resets_at"
  }
}

@MainActor
final class BillingService: ObservableObject {
  static let shared = BillingService()

  @Published private(set) var status: BillingStatus?
  @Published private(set) var isLoading = false
  @Published private(set) var isStartingCheckout = false
  @Published private(set) var isOpeningPortal = false
  @Published var errorMessage: String?

  private static let checkoutPendingUntilKey = "quill_checkout_pending_until"
  private var checkoutPollWorkItem: DispatchWorkItem?

  private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let value = try decoder.singleValueContainer().decode(String.self)
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let basic = ISO8601DateFormatter()
      guard let date = fractional.date(from: value) ?? basic.date(from: value) else {
        throw DecodingError.dataCorruptedError(
          in: try decoder.singleValueContainer(),
          debugDescription: "Invalid ISO-8601 date"
        )
      }
      return date
    }
    return decoder
  }()

  private init() {}

  /// AI 請求成功後先在本機立即扣一次，再向伺服器校正。
  /// Preferences、首頁若正開著，進度條與剩餘次數會立刻更新。
  func recordSuccessfulUse() {
    if let current = status, current.remaining > 0 {
      status = BillingStatus(
        plan: current.plan,
        used: min(current.limit, current.used + 1),
        limit: current.limit,
        remaining: max(0, current.remaining - 1),
        resetsAt: current.resetsAt,
        subscription: current.subscription,
        promotion: current.promotion
      )
    }
    refresh()
  }

  func refresh(completion: (() -> Void)? = nil) {
    isLoading = true
    errorMessage = nil
    authenticatedRequest(path: "billing/status", method: "GET") { [weak self] result in
      guard let self else {
        completion?()
        return
      }
      self.isLoading = false
      switch result {
      case .success(let data):
        do {
          self.status = try self.decoder.decode(BillingStatus.self, from: data)
          if self.status?.plan == "pro" {
            self.clearPendingCheckout()
          }
        } catch {
          self.errorMessage = L10n.t("billing.error")
        }
      case .failure(let error):
        self.errorMessage = error.localizedDescription
      }
      completion?()
    }
  }

  func startCheckout() {
    isStartingCheckout = true
    errorMessage = nil
    OpenAIService.shared.trackUpgradeClicked {}
    authenticatedRequest(path: "billing/checkout", method: "POST") { [weak self] result in
      guard let self else { return }
      self.isStartingCheckout = false
      switch result {
      case .success(let data):
        guard
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let string = object["checkout_url"] as? String,
          let url = URL(string: string),
          url.scheme == "https"
        else {
          self.errorMessage = L10n.t("billing.error")
          return
        }
        self.markCheckoutPending()
        if !NSWorkspace.shared.open(url) {
          self.clearPendingCheckout()
          self.errorMessage = L10n.t("billing.error")
        }
      case .failure(let error):
        self.errorMessage = error.localizedDescription
      }
    }
  }

  /// Portaly callback and browser redirect can arrive a few seconds apart.
  /// Keep checking briefly so returning users do not have to close and reopen Preferences.
  func resumePendingCheckoutConfirmation() {
    let deadline = Date(
      timeIntervalSince1970: UserDefaults.standard.double(
        forKey: Self.checkoutPendingUntilKey
      )
    )
    guard deadline > Date(), status?.plan != "pro" else {
      if status?.plan == "pro" || deadline <= Date() {
        clearPendingCheckout()
      }
      return
    }
    checkoutPollWorkItem?.cancel()
    pollForPro(until: deadline)
  }

  private func markCheckoutPending() {
    let deadline = Date().addingTimeInterval(2 * 60)
    UserDefaults.standard.set(
      deadline.timeIntervalSince1970,
      forKey: Self.checkoutPendingUntilKey
    )
  }

  private func pollForPro(until deadline: Date) {
    refresh { [weak self] in
      guard let self, self.status?.plan != "pro", Date() < deadline else { return }
      let workItem = DispatchWorkItem { [weak self] in
        self?.pollForPro(until: deadline)
      }
      self.checkoutPollWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }
  }

  private func clearPendingCheckout() {
    checkoutPollWorkItem?.cancel()
    checkoutPollWorkItem = nil
    UserDefaults.standard.removeObject(forKey: Self.checkoutPendingUntilKey)
  }

  func openSubscriptionPortal() {
    isOpeningPortal = true
    errorMessage = nil
    authenticatedRequest(path: "billing/portal", method: "POST") { [weak self] result in
      guard let self else { return }
      self.isOpeningPortal = false
      switch result {
      case .success(let data):
        guard
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let string = object["portal_url"] as? String,
          let url = URL(string: string),
          url.scheme == "https"
        else {
          self.errorMessage = L10n.t("billing.error")
          return
        }
        NSWorkspace.shared.open(url)
      case .failure(let error):
        self.errorMessage = error.localizedDescription
      }
    }
  }

  private func authenticatedRequest(
    path: String,
    method: String,
    completion: @escaping (Result<Data, Error>) -> Void
  ) {
    CloudAuthentication.shared.authorizationToken { result in
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let token):
        let base = PromptStore.shared.cloudEndpoint.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let url = URL(string: "\(base)/\(path)") else {
          completion(.failure(NSError(
            domain: "QuillError",
            code: -10,
            userInfo: [NSLocalizedDescriptionKey: L10n.t("billing.error")]
          )))
          return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if method == "POST" { request.httpBody = Data("{}".utf8) }
        URLSession.shared.dataTask(with: request) { data, response, error in
          let finalResult: Result<Data, Error>
          if let error {
            finalResult = .failure(error)
          } else if
            let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode),
            let data
          {
            finalResult = .success(data)
          } else {
            let http = response as? HTTPURLResponse
            finalResult = .failure(
              OpenAIService.parseAPIError(from: data, statusCode: http?.statusCode ?? 500)
            )
            if http?.statusCode == 401 { CloudAuthentication.shared.invalidateToken() }
          }
          DispatchQueue.main.async { completion(finalResult) }
        }.resume()
      }
    }
  }
}
