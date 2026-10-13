import XCTest
import ApplicationServices
@testable import Quill

final class QuillTests: XCTestCase {

  @MainActor
  func testRecoveryAvailabilityRequiresExplicitServerAndLocalRolloutFlags() {
    for flag in ["", ",\"recovery_enabled\":null", ",\"recovery_enabled\":false", ",\"recovery_enabled\":true"] {
      let payload = Data((#"{"plan":"free","used":0,"limit":100,"remaining":100,"resets_at":"2026-10-01T00:00:00Z","subscription":null,"promotion":{"active":false,"first_month_amount":150,"recurring_amount":200,"ends_at":"2026-10-01T00:00:00Z"}"# + flag + "}").utf8)
      let billing = BillingService(statusRequest: { $0(.success(payload)) })
      billing.refresh()
      XCTAssertNotNil(billing.status)
      XCTAssertFalse(billing.status?.canRecoverPurchases(localRolloutEnabled: false) ?? true)
      XCTAssertEqual(billing.status?.canRecoverPurchases(localRolloutEnabled: true), flag.hasSuffix("true"))
      XCTAssertFalse(billing.canRecoverPurchases, "Deferred local rollout must keep recovery hidden")
    }
  }

  func testRecoveryFormRetainsStatusRetryWithoutBypassingDeferredRollout() {
    for localEnabled in [false, true] {
      for serverEnabled in [false, true] {
        for presented in [false, true] {
          for phase in [(awaiting: false, succeeded: false),
                        (awaiting: true, succeeded: false),
                        (awaiting: false, succeeded: true)] {
            let visible = PurchaseRecoveryPresentation.showsForm(
              localRolloutEnabled: localEnabled, serverEnabled: serverEnabled,
              isPresented: presented, awaitingStatus: phase.awaiting, succeeded: phase.succeeded)
            if !localEnabled || !presented {
              XCTAssertFalse(visible, "Deferred or dismissed recovery must stay hidden")
            } else if phase.awaiting || phase.succeeded {
              XCTAssertTrue(visible, "Cleared/unavailable billing status must not hide retry/cancel or success")
            } else {
              XCTAssertEqual(visible, serverEnabled, "Initial recovery still requires server availability")
            }
          }
        }
      }
    }
  }

  func testAPIKeyMigrationPreservesLegacyUntilSecureWriteSucceeds() {
    for succeeds in [false, true] {
      var removed = false
      var written: String?
      let value = KeychainStore.loadAPIKey(read: { nil }, legacy: { "fake-legacy" },
        write: { written = $0; return succeeds }, removeLegacy: { removed = true })
      XCTAssertEqual(value, "fake-legacy")
      XCTAssertEqual(written, "fake-legacy")
      XCTAssertEqual(removed, succeeds)
    }
    XCTAssertEqual(KeychainStore.loadAPIKey(read: { "fake-secure" },
      legacy: { XCTFail("Must prefer secure value"); return nil },
      write: { _ in XCTFail(); return false }, removeLegacy: { XCTFail() }), "fake-secure")
    XCTAssertEqual(KeychainStore.loadAPIKey(read: { nil }, legacy: { "" },
      write: { _ in XCTFail(); return false }, removeLegacy: { XCTFail() }), "")
  }

  func testAPIKeySaveAndDeleteFailureNeverEraseLegacyFallback() {
    for value in ["fake-new", ""] {
      for succeeds in [false, true] {
        var writes = 0
        var deletes = 0
        var removals = 0
        let result = KeychainStore.saveAPIKey(value,
          write: { XCTAssertEqual($0, value); writes += 1; return succeeds },
          delete: { deletes += 1; return succeeds }, removeLegacy: { removals += 1 })
        XCTAssertEqual(result, succeeds)
        XCTAssertEqual(writes, value.isEmpty ? 0 : 1)
        XCTAssertEqual(deletes, value.isEmpty ? 1 : 0)
        XCTAssertEqual(removals, succeeds ? 1 : 0)
      }
    }
  }

  func testOnboardingPreparationFailureRequiresExplicitRetryAndSuccessUnlocksReady() {
    var preparation = DirectCapturePreparation()
    preparation.complete(succeeded: true)
    XCTAssertFalse(preparation.ready, "Unsolicited completion must not unlock onboarding")
    XCTAssertTrue(preparation.begin())
    XCTAssertFalse(preparation.begin(), "Polling must not overlap preparation")
    preparation.complete(succeeded: false)
    XCTAssertFalse(preparation.ready)
    XCTAssertTrue(preparation.failed)
    XCTAssertFalse(preparation.inFlight)
    XCTAssertFalse(preparation.begin(), "Polling must not automatically retry failures")
    preparation.allowRetry()
    XCTAssertTrue(preparation.begin())
    preparation.complete(succeeded: true)
    XCTAssertTrue(preparation.ready)
    XCTAssertFalse(preparation.failed)
    XCTAssertFalse(preparation.begin(), "Successful preparation must not repeat")
  }

  func testAccessibilityPromptPreparationRunsOnlyOnceAndNeverWhenGranted() {
    var preparation = AccessibilityPromptPreparation()
    XCTAssertTrue(preparation.begin(isGranted: false))
    XCTAssertTrue(preparation.requested)
    XCTAssertFalse(preparation.begin(isGranted: false), "Polling must not repeat the macOS prompt")

    var alreadyGranted = AccessibilityPromptPreparation()
    XCTAssertFalse(alreadyGranted.begin(isGranted: true))
    XCTAssertFalse(alreadyGranted.requested)
  }

  func testHotkeyConflictRequiresSameKeyAndModifiers() {
    XCTAssertTrue(hotkeysMatch(
      keyCode: 12, modifiers: 6144,
      otherKeyCode: 12, otherModifiers: 6144
    ))
    XCTAssertFalse(hotkeysMatch(
      keyCode: 12, modifiers: 6144,
      otherKeyCode: 0, otherModifiers: 6144
    ))
    XCTAssertFalse(hotkeysMatch(
      keyCode: 12, modifiers: 6144,
      otherKeyCode: 12, otherModifiers: 256
    ))
  }

  func testAccessibilityInstructionsExplainManualAddAndMacOSPasswordHandling() {
    let original = LocaleStore.shared.language
    defer { LocaleStore.shared.language = original }

    LocaleStore.shared.language = .zhHant
    XCTAssertEqual(L10n.t("ob.ax.how"), "開啟設定後，打開 Quill 的開關。")
    XCTAssertTrue(L10n.t("ob.ax.missingHelp").contains("應用程式"))
    XCTAssertTrue(L10n.t("ob.ax.missingHelp").contains("Quill.app"))
    XCTAssertTrue(L10n.t("ob.ax.password").contains("管理員"))
    XCTAssertTrue(L10n.t("ob.ax.password").contains("macOS"))
    XCTAssertTrue(L10n.t("ob.ax.password").contains("不會讀取或儲存"))

    LocaleStore.shared.language = .en
    XCTAssertEqual(L10n.t("ob.ax.how"), "Open Settings and turn on Quill.")
    XCTAssertTrue(L10n.t("ob.ax.missingHelp").contains("Applications"))
    XCTAssertTrue(L10n.t("ob.ax.missingHelp").contains("Quill.app"))
    XCTAssertTrue(L10n.t("ob.ax.password").contains("administrator"))
    XCTAssertTrue(L10n.t("ob.ax.password").contains("only to macOS"))
    XCTAssertTrue(L10n.t("ob.ax.password").contains("never reads or stores"))
  }

  // MARK: - OpenAIService parsing

  @MainActor
  func testRecoveryValidatesInputsWithoutNetworkOrCredentials() {
    for invalid in ["", "  ", "12345", "1234567", "１２３４５６", "123 56", "123456\n"] {
      XCTAssertFalse(PurchaseRecoveryFlow.validCode(invalid))
    }
    XCTAssertTrue(PurchaseRecoveryFlow.validCode("012345"))
    XCTAssertTrue(PurchaseRecoveryFlow.validEmail(" person@example.com \n"))
    for invalid in ["", " ", "person", "person@", "a b@example.com"] {
      XCTAssertFalse(PurchaseRecoveryFlow.validEmail(invalid))
    }
    var calls = 0
    let flow = PurchaseRecoveryFlow(request: { _, _, _ in calls += 1 }, refresh: { _ in XCTFail() })
    flow.sendCode()
    XCTAssertEqual(calls, 0)
    XCTAssertEqual(flow.errorKey, "recovery.invalidEmail")
  }

  @MainActor
  func testRecoveryCooldownVerificationAndAuthoritativeRefresh() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var paths: [String] = []
    var pending: ((Result<Data, Error>) -> Void)?
    var refreshCompletion: ((BillingRefreshOutcome) -> Void)?
    let flow = PurchaseRecoveryFlow(request: { path, body, completion in
      paths.append(path)
      if path.hasSuffix("request") { XCTAssertEqual(body["email"], "person@example.com") }
      else { XCTAssertEqual(body["code"], "012345"); XCTAssertEqual(body["challenge_id"], "test") }
      pending = completion
    }, refresh: { refreshCompletion = $0 })
    flow.email = " person@example.com "
    flow.sendCode(now: now)
    flow.sendCode(now: now)
    XCTAssertEqual(paths.count, 1)
    pending?(.success(Data(#"{"challenge_id":"test","expires_in":600,"resend_after":60}"#.utf8)))
    XCTAssertEqual(flow.resendSeconds(at: now), 60)
    XCTAssertEqual(flow.expirySeconds(at: now), 600)
    flow.sendCode(now: now.addingTimeInterval(59))
    XCTAssertEqual(paths.count, 1)
    flow.code = "   "
    flow.verify(now: now)
    XCTAssertEqual(paths.count, 1)
    flow.code = "012345"
    flow.verify(now: now)
    flow.verify(now: now)
    XCTAssertEqual(paths, ["billing/recovery/request", "billing/recovery/verify"])
    pending?(.success(Data(#"{"restored":true}"#.utf8)))
    XCTAssertNotNil(refreshCompletion)
    XCTAssertTrue(flow.isBusy)
    XCTAssertFalse(flow.succeeded)
    XCTAssertEqual(flow.email, "")
    XCTAssertEqual(flow.code, "")
    XCTAssertNil(flow.challengeID)
    refreshCompletion?(.accepted(recoveryStatus()))
    XCTAssertTrue(flow.succeeded)
    XCTAssertFalse(flow.isBusy)
  }

  @MainActor
  private func recoveryStatus(plan: String = "pro", subscriptionStatus: String = "active") -> BillingStatus {
    BillingStatus(plan: plan, used: 0, limit: 1000, remaining: 1000, resetsAt: Date(),
      subscription: .init(status: subscriptionStatus, currentAmount: 150, nextAmount: 200,
                          cancelAtPeriodEnd: false, cancelEffectiveAt: nil),
      promotion: .init(active: false, firstMonthAmount: 150, recurringAmount: 200, endsAt: Date()))
  }

  @MainActor
  func testRecoveryRefreshFailureAndSupersessionRetryWithoutReusingOTP() {
    let now = Date()
    var requests = 0
    var completions: [(BillingRefreshOutcome) -> Void] = []
    let flow = PurchaseRecoveryFlow(request: { path, _, completion in
      requests += 1
      completion(.success(Data((path.hasSuffix("request")
        ? #"{"challenge_id":"test","expires_in":600,"resend_after":60}"#
        : #"{"restored":true}"#).utf8)))
    }, refresh: { completions.append($0) })
    flow.email = "person@example.com"
    flow.sendCode(now: now)
    flow.code = "123456"
    flow.verify(now: now)
    for outcome: BillingRefreshOutcome in [.failed, .superseded,
        .accepted(recoveryStatus(plan: "free")),
        .accepted(recoveryStatus(subscriptionStatus: "canceled"))] {
      completions.last?(outcome)
      XCTAssertFalse(flow.succeeded)
      XCTAssertTrue(flow.awaitingStatus)
      XCTAssertFalse(flow.isBusy)
      XCTAssertEqual(flow.errorKey, "recovery.refreshFailed")
      flow.sendCode(now: now.addingTimeInterval(700))
      flow.verify(now: now.addingTimeInterval(700))
      XCTAssertEqual(requests, 2)
      flow.retryStatus()
      XCTAssertTrue(flow.isBusy)
    }
    completions.last?(.accepted(recoveryStatus()))
    XCTAssertTrue(flow.succeeded)
    XCTAssertFalse(flow.awaitingStatus)
    XCTAssertNil(flow.errorKey)
    XCTAssertEqual(requests, 2)
  }

  @MainActor
  func testRecoveryResetIgnoresLateStatus() {
    var completion: ((BillingRefreshOutcome) -> Void)?
    let flow = PurchaseRecoveryFlow(request: { path, _, callback in
      callback(.success(Data((path.hasSuffix("request")
        ? #"{"challenge_id":"test","expires_in":600,"resend_after":60}"#
        : #"{"restored":true}"#).utf8)))
    }, refresh: { completion = $0 })
    flow.email = "person@example.com"
    flow.sendCode()
    flow.code = "123456"
    flow.verify()
    flow.reset()
    completion?(.accepted(recoveryStatus()))
    XCTAssertFalse(flow.succeeded)
    XCTAssertFalse(flow.awaitingStatus)
    XCTAssertFalse(flow.isBusy)
  }

  @MainActor
  func testBillingRefreshOnlyReportsAcceptedSnapshotAndRejectsSupersededOrInvalidResponses() {
    var pending: [(Result<Data, Error>) -> Void] = []
    let billing = BillingService(statusRequest: { pending.append($0) })
    var outcomes: [BillingRefreshOutcome] = []
    var legacyCompletions = 0
    billing.refresh(completion: { legacyCompletions += 1 }, statusCompletion: { outcomes.append($0) })
    billing.refresh(statusCompletion: { outcomes.append($0) })
    let valid = Data(#"{"plan":"free","used":0,"limit":100,"remaining":100,"resets_at":"2026-10-01T00:00:00Z","subscription":null,"promotion":{"active":false,"first_month_amount":150,"recurring_amount":200,"ends_at":"2026-10-01T00:00:00Z"}}"#.utf8)
    pending[0](.success(valid))
    guard case .superseded = outcomes[0] else { return XCTFail("Stale refresh must not be accepted") }
    XCTAssertNil(billing.status)
    XCTAssertTrue(billing.isLoading)
    XCTAssertEqual(legacyCompletions, 1)
    pending[1](.success(valid))
    guard case .accepted(let snapshot) = outcomes[1] else { return XCTFail("Latest valid refresh must be accepted") }
    XCTAssertEqual(snapshot.plan, "free")
    XCTAssertEqual(billing.status?.plan, "free")
    for response: Result<Data, Error> in [.success(Data("invalid".utf8)), .failure(NSError(domain: "test", code: 503))] {
      billing.refresh(statusCompletion: { outcomes.append($0) })
      pending.last?(response)
      guard case .failed = outcomes.last! else { return XCTFail("Failure must not return old status as accepted") }
      XCTAssertFalse(billing.isLoading)
      XCTAssertNotNil(billing.errorMessage)
    }
  }

  @MainActor
  func testRecoveryExpiryCancellationAndFailureNeverRefresh() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var pending: ((Result<Data, Error>) -> Void)?
    var calls = 0
    let flow = PurchaseRecoveryFlow(request: { _, _, completion in calls += 1; pending = completion },
                                    refresh: { _ in XCTFail("Must not refresh without verified recovery") })
    flow.email = "person@example.com"
    flow.sendCode(now: now)
    pending?(.success(Data(#"{"challenge_id":"test","expires_in":600,"resend_after":60}"#.utf8)))
    flow.code = "123456"
    flow.verify(now: now.addingTimeInterval(600))
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(flow.errorKey, "recovery.expired")
    flow.sendCode(now: now.addingTimeInterval(601))
    XCTAssertEqual(calls, 2)
    let staleCompletion = pending
    flow.reset()
    staleCompletion?(.success(Data(#"{"challenge_id":"stale","expires_in":600,"resend_after":60}"#.utf8)))
    XCTAssertNil(flow.challengeID)
    XCTAssertEqual(flow.email, "")
    XCTAssertFalse(flow.isBusy)
    for status in [400, 401, 404, 409, 429, 502, 503] {
      XCTAssertTrue(PurchaseRecoveryFlow.failureKey(NSError(domain: "test", code: status), verifying: true).hasPrefix("recovery."))
    }
  }

  func testPaymentReturnRestartsExpiredConfirmationWindow() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let expired = now.addingTimeInterval(-600).timeIntervalSince1970
    XCTAssertEqual(
      BillingService.confirmationDeadline(savedDeadline: expired, paymentReturned: true, now: now),
      now.addingTimeInterval(120)
    )
    XCTAssertEqual(
      BillingService.confirmationDeadline(savedDeadline: expired, paymentReturned: false, now: now),
      Date(timeIntervalSince1970: expired)
    )
    let pending = now.addingTimeInterval(30).timeIntervalSince1970
    XCTAssertEqual(
      BillingService.confirmationDeadline(savedDeadline: pending, paymentReturned: false, now: now),
      Date(timeIntervalSince1970: pending)
    )
  }

  func testStreamingRejectsEmptyResponsesWithoutAccessingCredentials() {
    for payload in ["", "data: [DONE]\n\n", "data: {\"choices\":[{\"delta\":{\"content\":\"   \"}}]}\n\ndata: [DONE]\n\n"] {
      var completions = 0
      let stream = StreamingChatTask(onDelta: { _ in }, onComplete: { result in
        completions += 1
        if case .success = result { XCTFail("An empty answer must not be reported as success") }
      }, recordsUsage: false)
      let session = URLSession(configuration: .ephemeral)
      let task = session.dataTask(with: URL(string: "https://example.invalid")!)
      stream.urlSession(session, dataTask: task, didReceive: Data(payload.utf8))
      stream.urlSession(session, task: task, didCompleteWithError: nil)
      XCTAssertEqual(completions, 1)
      session.invalidateAndCancel()
    }
  }

  func testStreamingPreservesChineseAndEmojiAtEveryByteBoundary() {
    let expected = "繁體中文 👨‍👩‍👧‍👦 café"
    let json: [String: Any] = ["choices": [["delta": ["content": expected]]]]
    let payload = String(data: try! JSONSerialization.data(withJSONObject: json), encoding: .utf8)!
    let bytes = Data("data: \(payload)\n\ndata: [DONE]\n\n".utf8)
    for split in 1..<bytes.count {
      var output = ""
      var completed = false
      let stream = StreamingChatTask(onDelta: { output += $0 }, onComplete: { result in
        XCTAssertEqual(try? result.get(), expected)
        completed = true
      }, recordsUsage: false)
      let session = URLSession(configuration: .ephemeral)
      let task = session.dataTask(with: URL(string: "https://example.invalid")!)
      stream.urlSession(session, dataTask: task, didReceive: Data(bytes.prefix(split)))
      stream.urlSession(session, dataTask: task, didReceive: Data(bytes.dropFirst(split)))
      XCTAssertEqual(output, expected, "Split at byte \(split)")
      XCTAssertTrue(completed)
      session.invalidateAndCancel()
    }
  }

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
    XCTAssertEqual(OpenAIService.parseAPIError(from: nil, statusCode: 401).code, 401)
    XCTAssertEqual(OpenAIService.parseAPIError(from: nil, statusCode: 429).code, 429)
    XCTAssertEqual(OpenAIService.parseAPIError(from: nil, statusCode: 503).code, 503)
    // 不認識的狀態碼也要有泛用訊息
    XCTAssertTrue(
      OpenAIService.parseAPIError(from: nil, statusCode: 418)
        .localizedDescription.contains("HTTP 418")
    )
  }

  func testAPIErrorIgnoresMalformedErrorBody() {
    let data = #"{"unexpected":"shape"}"#.data(using: .utf8)!
    let error = OpenAIService.parseAPIError(from: data, statusCode: 429)
    XCTAssertEqual(error.code, 429)
    XCTAssertFalse(error.localizedDescription.isEmpty)
  }

  // MARK: - Model configuration

  func testModelDefaultsWhenUnset() {
    UserDefaults.standard.removeObject(forKey: "quill_text_model")
    UserDefaults.standard.removeObject(forKey: "quill_vision_model")
    XCTAssertEqual(PromptStore.shared.textModel,   PromptStore.defaultTextModel)
    XCTAssertEqual(PromptStore.shared.visionModel, PromptStore.defaultVisionModel)
  }

  // MARK: - Onboarding

  func testScreenPermissionSetupCanResumeAfterSystemRelaunch() {
    OnboardingWindow.clearScreenPermissionPending()
    OnboardingWindow.clearScreenRelaunchAttempted()
    defer { OnboardingWindow.clearScreenPermissionPending() }
    defer { OnboardingWindow.clearScreenRelaunchAttempted() }

    XCTAssertFalse(OnboardingWindow.screenPermissionPending)
    XCTAssertFalse(OnboardingWindow.screenRelaunchAttempted)
    OnboardingWindow.markScreenPermissionPending()
    XCTAssertTrue(OnboardingWindow.screenPermissionPending)
    OnboardingWindow.markScreenRelaunchAttempted()
    XCTAssertTrue(OnboardingWindow.screenRelaunchAttempted)
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

  func testTraditionalChineseUIAddsTraditionalChineseResponseRule() {
    let original = LocaleStore.shared.language
    defer { LocaleStore.shared.language = original }
    LocaleStore.shared.language = .zhHant

    let prompt = PromptStore.promptRespectingAppLanguage(
      "Summarize the text.", titleKey: "action.summarize"
    )

    XCTAssertTrue(prompt.contains("Traditional Chinese"))
    XCTAssertTrue(prompt.contains("Never use Simplified Chinese"))
  }

  func testTranslationPromptUsesIndependentTranslationLanguage() {
    let originalInterface = LocaleStore.shared.language
    let originalTranslation = TranslationLanguageStore.shared.language
    defer {
      LocaleStore.shared.language = originalInterface
      TranslationLanguageStore.shared.language = originalTranslation
    }
    LocaleStore.shared.language = .en
    TranslationLanguageStore.shared.language = .zhHant

    let traditionalChineseTarget = PromptStore.promptRespectingAppLanguage(
      "Chinese input MUST be translated into natural English.",
      titleKey: "action.translate"
    )

    XCTAssertTrue(traditionalChineseTarget.contains("TARGET_LANGUAGE: Traditional Chinese"))

    LocaleStore.shared.language = .zhHant
    TranslationLanguageStore.shared.language = .en
    let englishTarget = PromptStore.promptRespectingAppLanguage(
      "Chinese input MUST be translated into natural English.",
      titleKey: "action.translate"
    )
    XCTAssertTrue(englishTarget.contains("TARGET_LANGUAGE: English"))
    XCTAssertTrue(PromptStore.defaultEditable
      .first(where: { $0.titleKey == "action.translate" })?
      .systemPrompt.contains("Never return Chinese when the input is Chinese") == true)
  }
}
