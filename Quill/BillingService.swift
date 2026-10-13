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
  var recoveryEnabled: Bool? = nil

  func canRecoverPurchases(localRolloutEnabled: Bool) -> Bool {
    localRolloutEnabled && recoveryEnabled == true
  }

  enum CodingKeys: String, CodingKey {
    case plan, used, limit, remaining, subscription, promotion
    case resetsAt = "resets_at"
    case recoveryEnabled = "recovery_enabled"
  }
}

enum BillingRefreshOutcome {
  case accepted(BillingStatus)
  case failed
  case superseded
}

enum PurchaseRecoveryPresentation {
  static func showsForm(localRolloutEnabled: Bool, serverEnabled: Bool,
                        isPresented: Bool, awaitingStatus: Bool, succeeded: Bool) -> Bool {
    // Verified recovery clears the billing snapshot. Keep retry/cancel (and then
    // success) visible while refreshing it, without bypassing the local rollout.
    localRolloutEnabled && isPresented && (serverEnabled || awaitingStatus || succeeded)
  }
}

@MainActor
final class BillingService: ObservableObject {
  static let shared = BillingService()
  // Email delivery setup is deferred. Enable only after end-to-end rollout verification.
  static let emailRecoveryRolloutEnabled = false
  var canRecoverPurchases: Bool {
    status?.canRecoverPurchases(localRolloutEnabled: Self.emailRecoveryRolloutEnabled) == true
  }

  @Published private(set) var status: BillingStatus?
  @Published private(set) var isLoading = false
  @Published private(set) var isStartingCheckout = false
  @Published private(set) var isOpeningPortal = false
  @Published var errorMessage: String?

  private static let checkoutPendingUntilKey = "quill_checkout_pending_until"
  private var checkoutPollWorkItem: DispatchWorkItem?
  private var refreshRevision = 0
  private let statusRequest: ((@escaping (Result<Data, Error>) -> Void) -> Void)?

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

  init(statusRequest: ((@escaping (Result<Data, Error>) -> Void) -> Void)? = nil) {
    self.statusRequest = statusRequest
  }

  func makeRecoveryFlow() -> PurchaseRecoveryFlow {
    PurchaseRecoveryFlow(request: { [weak self] path, body, completion in
      self?.authenticatedRequest(path: path, method: "POST", body: body, completion: completion)
    }, refresh: { [weak self] completion in
      guard let self else { completion(.failed); return }
      // A recovered link is not a local entitlement. Discard the old snapshot.
      self.clearPendingCheckout()
      self.status = nil
      self.errorMessage = nil
      self.refresh(statusCompletion: completion)
    })
  }

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
        promotion: current.promotion,
        recoveryEnabled: current.recoveryEnabled
      )
    }
    refresh()
  }

  func refresh(completion: (() -> Void)? = nil, statusCompletion: ((BillingRefreshOutcome) -> Void)? = nil) {
    refreshRevision += 1
    let revision = refreshRevision
    isLoading = true
    errorMessage = nil
    let receive: (Result<Data, Error>) -> Void = { [weak self] result in
      defer { completion?() }
      guard let self else {
        statusCompletion?(.failed)
        return
      }
      guard revision == self.refreshRevision else {
        statusCompletion?(.superseded)
        return
      }
      self.isLoading = false
      switch result {
      case .success(let data):
        do {
          let snapshot = try self.decoder.decode(BillingStatus.self, from: data)
          self.status = snapshot
          if self.status?.plan == "pro" {
            self.clearPendingCheckout()
          }
          statusCompletion?(.accepted(snapshot))
        } catch {
          self.errorMessage = L10n.t("billing.error")
          statusCompletion?(.failed)
        }
      case .failure(let error):
        self.errorMessage = error.localizedDescription
        statusCompletion?(.failed)
      }
    }
    if let statusRequest { statusRequest(receive) }
    else { authenticatedRequest(path: "billing/status", method: "GET", completion: receive) }
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
  func resumePendingCheckoutConfirmation(paymentReturned: Bool = false) {
    let now = Date()
    let deadline = Self.confirmationDeadline(
      savedDeadline: UserDefaults.standard.double(forKey: Self.checkoutPendingUntilKey),
      paymentReturned: paymentReturned,
      now: now
    )
    if paymentReturned {
      UserDefaults.standard.set(deadline.timeIntervalSince1970, forKey: Self.checkoutPendingUntilKey)
    }
    guard deadline > now, status?.plan != "pro" else {
      if status?.plan == "pro" || deadline <= now {
        clearPendingCheckout()
      }
      return
    }
    checkoutPollWorkItem?.cancel()
    pollForPro(until: deadline)
  }

  /// A verified entitlement still comes from the backend, never from the redirect.
  /// The return only gives slow checkout flows a fresh confirmation window.
  static func confirmationDeadline(savedDeadline: TimeInterval, paymentReturned: Bool, now: Date) -> Date {
    paymentReturned ? now.addingTimeInterval(120) : Date(timeIntervalSince1970: savedDeadline)
  }

  private func markCheckoutPending() {
    let deadline = Date().addingTimeInterval(2 * 60)
    UserDefaults.standard.set(
      deadline.timeIntervalSince1970,
      forKey: Self.checkoutPendingUntilKey
    )
  }

  private func pollForPro(until deadline: Date) {
    refresh(completion: { [weak self] in
      guard let self, self.status?.plan != "pro", Date() < deadline else { return }
      let workItem = DispatchWorkItem { [weak self] in
        self?.pollForPro(until: deadline)
      }
      self.checkoutPollWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    })
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
    body: [String: String] = [:],
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
        if method == "POST" { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
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

/// Ephemeral recovery state; injectable transport keeps tests away from credentials and the network.
@MainActor
final class PurchaseRecoveryFlow: ObservableObject {
  typealias Request = (String, [String: String], @escaping (Result<Data, Error>) -> Void) -> Void
  @Published var email = ""
  @Published var code = ""
  @Published private(set) var challengeID: String?
  @Published private(set) var expiresAt: Date?
  @Published private(set) var resendAt: Date?
  @Published private(set) var isBusy = false
  @Published private(set) var succeeded = false
  @Published private(set) var awaitingStatus = false
  @Published private(set) var errorKey: String?
  private var revision = 0
  private let request: Request
  private let refresh: (@escaping (BillingRefreshOutcome) -> Void) -> Void

  init(request: @escaping Request, refresh: @escaping (@escaping (BillingRefreshOutcome) -> Void) -> Void) {
    self.request = request
    self.refresh = refresh
  }

  static func validEmail(_ value: String) -> Bool {
    let email = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return email.count <= 254 && email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
  }

  static func validCode(_ value: String) -> Bool {
    value.utf8.count == 6 && value.utf8.allSatisfy { (48...57).contains($0) }
  }

  func resendSeconds(at now: Date) -> Int { max(0, Int(ceil((resendAt ?? now).timeIntervalSince(now)))) }
  func expirySeconds(at now: Date) -> Int { max(0, Int(ceil((expiresAt ?? now).timeIntervalSince(now)))) }

  func reset() {
    revision += 1
    email = ""; code = ""; challengeID = nil; expiresAt = nil; resendAt = nil
    isBusy = false; succeeded = false; awaitingStatus = false; errorKey = nil
  }

  func sendCode(now: Date = Date()) {
    guard !isBusy, !succeeded, !awaitingStatus, resendSeconds(at: now) == 0 else { return }
    guard Self.validEmail(email) else { errorKey = "recovery.invalidEmail"; return }
    email = email.trimmingCharacters(in: .whitespacesAndNewlines)
    isBusy = true; errorKey = nil; code = ""
    let current = revision
    request("billing/recovery/request", ["email": email, "language": LocaleStore.shared.isZh ? "zh-TW" : "en"]) { [weak self] result in
      guard let self, current == self.revision else { return }
      self.isBusy = false
      switch result {
      case .success(let data):
        struct Challenge: Decodable { let challenge_id: String; let expires_in: Int; let resend_after: Int }
        guard let response = try? JSONDecoder().decode(Challenge.self, from: data),
              !response.challenge_id.isEmpty, response.expires_in > 0, response.resend_after >= 0 else {
          self.errorKey = "recovery.unavailable"; return
        }
        self.challengeID = response.challenge_id
        self.expiresAt = now.addingTimeInterval(TimeInterval(response.expires_in))
        self.resendAt = now.addingTimeInterval(TimeInterval(response.resend_after))
      case .failure(let error): self.errorKey = Self.failureKey(error, verifying: false)
      }
    }
  }

  func verify(now: Date = Date()) {
    guard !isBusy, !succeeded, !awaitingStatus, let challengeID else { return }
    guard expirySeconds(at: now) > 0 else { errorKey = "recovery.expired"; return }
    guard Self.validCode(code) else { errorKey = "recovery.invalidCode"; return }
    isBusy = true; errorKey = nil
    let current = revision
    request("billing/recovery/verify", ["challenge_id": challengeID, "code": code]) { [weak self] result in
      guard let self, current == self.revision else { return }
      switch result {
      case .success(let data):
        struct Verification: Decodable { let restored: Bool }
        guard let response = try? JSONDecoder().decode(Verification.self, from: data), response.restored else {
          self.isBusy = false; self.errorKey = "recovery.unavailable"; return
        }
        self.email = ""; self.code = ""; self.challengeID = nil; self.expiresAt = nil; self.resendAt = nil
        self.awaitingStatus = true
        self.isBusy = false
        self.retryStatus()
      case .failure(let error):
        self.isBusy = false; self.errorKey = Self.failureKey(error, verifying: true)
      }
    }
  }

  func retryStatus() {
    guard awaitingStatus, !isBusy, !succeeded else { return }
    isBusy = true; errorKey = nil
    let current = revision
    refresh { [weak self] outcome in
      guard let self, current == self.revision else { return }
      self.isBusy = false
      if case .accepted(let snapshot) = outcome,
         snapshot.plan == "pro", let subscription = snapshot.subscription,
         ["active", "cancel_requested", "past_due"].contains(subscription.status) {
        self.awaitingStatus = false
        self.succeeded = true
      } else {
        self.errorKey = "recovery.refreshFailed"
      }
    }
  }

  static func failureKey(_ error: Error, verifying: Bool) -> String {
    switch (error as NSError).code {
    case 400: return verifying ? "recovery.invalidCode" : "recovery.invalidEmail"
    case 401: return "recovery.auth"
    case 404: return verifying ? "recovery.expired" : "recovery.notFound"
    case 409: return "recovery.conflict"
    case 429: return "recovery.rateLimited"
    default: return "recovery.unavailable"
    }
  }
}
