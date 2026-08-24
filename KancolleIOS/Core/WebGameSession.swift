import Foundation
import SwiftUI
import WebKit
import UserNotifications
import UIKit

@MainActor
final class WebGameSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let store = KCSAPIStore()

    @Published private(set) var statusMessage = "準備中"
    @Published private(set) var currentHost = "-"
    @Published private(set) var gameRectNormalized = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published private(set) var webProcessRestarts = 0
    @Published private(set) var memoryWarnings = 0
    @Published private(set) var isSafetyUnlocked = false
    @Published private(set) var safetyTapCount = 0

    private(set) var webView: WKWebView!
    private var messageProxy: WeakScriptMessageHandler?
    private var memoryObserver: NSObjectProtocol?
    private var safetyTapTimes: [Date] = []
    private var unlockTimer: Timer?
    private var didRequestNotifications = false

    private let startURL = URL(string: "https://www.dmm.com/netgame/social/-/gadgets/=/app_id=854854/")!

    override init() {
        super.init()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let controller = WKUserContentController()
        if let bridgeURL = Bundle.main.url(forResource: "kcs-bridge", withExtension: "js"),
           let bridgeSource = try? String(contentsOf: bridgeURL, encoding: .utf8) {
            let script = WKUserScript(
                source: bridgeSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .page
            )
            controller.addUserScript(script)
        }

        let proxy = WeakScriptMessageHandler(target: self)
        messageProxy = proxy
        controller.add(proxy, contentWorld: .page, name: "kcsBridge")
        configuration.userContentController = controller

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.scrollView.bounces = false
        webView.isOpaque = true
#if DEBUG
        webView.isInspectable = true
#endif

        store.onSafetyWarning = { [weak self] ships, reason in
            self?.handleSafetyWarning(ships: ships, reason: reason)
        }

        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.memoryWarnings += 1
                if self.store.trimTransientStateIfSafe() {
                    self.statusMessage = "メモリ警告：不要な戦闘データを解放"
                } else {
                    self.statusMessage = "メモリ警告：進撃判定中のHPは安全のため保持"
                }
            }
        }
    }

    deinit {
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
        unlockTimer?.invalidate()
    }

    func loadGameIfNeeded() {
        guard webView.url == nil else { return }
        statusMessage = "艦これを読み込み中"
        webView.load(URLRequest(url: startURL))
    }

    func reloadGame() {
        statusMessage = "再読み込み中"
        resetSafetyUnlock()
        if webView.url == nil {
            webView.load(URLRequest(url: startURL))
        } else {
            webView.reloadFromOrigin()
        }
    }

    func requestNotificationPermissionIfNeeded() {
        guard !didRequestNotifications else { return }
        didRequestNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func registerSafetyTap() {
        let now = Date()
        safetyTapTimes = safetyTapTimes.filter { now.timeIntervalSince($0) <= 2.4 }
        safetyTapTimes.append(now)
        safetyTapCount = min(3, safetyTapTimes.count)

        guard safetyTapTimes.count >= 3 else { return }

        safetyTapTimes.removeAll(keepingCapacity: true)
        safetyTapCount = 0
        isSafetyUnlocked = true
        unlockTimer?.invalidate()
        unlockTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.resetSafetyUnlock() }
        }
    }

    func resetSafetyUnlock() {
        unlockTimer?.invalidate()
        unlockTimer = nil
        safetyTapTimes.removeAll(keepingCapacity: true)
        safetyTapCount = 0
        isSafetyUnlocked = false
    }

    func resolvedGameRect(in size: CGSize) -> CGRect {
        let r = gameRectNormalized
        guard r.width > 0.2, r.height > 0.15 else {
            return CGRect(origin: .zero, size: size)
        }
        return CGRect(
            x: r.minX * size.width,
            y: r.minY * size.height,
            width: r.width * size.width,
            height: r.height * size.height
        )
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }

        switch type {
        case "bridge":
            statusMessage = "通信Bridge起動"
        case "gameRect":
            if let rect = body["rect"] as? [String: Any],
               let x = number(rect["x"]),
               let y = number(rect["y"]),
               let width = number(rect["width"]),
               let height = number(rect["height"]) {
                gameRectNormalized = CGRect(x: x, y: y, width: width, height: height)
            }
        case "api":
            if let path = body["path"] as? String,
               path.contains("/api_req_map/next") || path.contains("/goback_port") || path.contains("/api_port/port") {
                resetSafetyUnlock()
            }
            store.handleBridgeMessage(body)
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        currentHost = webView.url?.host ?? currentHost
        statusMessage = "ページ読み込み中"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        currentHost = webView.url?.host ?? "-"
        statusMessage = "ページ読み込み完了"
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        currentHost = webView.url?.host ?? currentHost
        statusMessage = "読込エラー: \(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        currentHost = webView.url?.host ?? currentHost
        statusMessage = "接続エラー: \(error.localizedDescription)"
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webProcessRestarts += 1
        statusMessage = "WebKitが終了したため復旧中（\(webProcessRestarts)回）"
        resetSafetyUnlock()
        store.resetAfterWebProcessTermination()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            if self.webView.url == nil {
                self.webView.load(URLRequest(url: self.startURL))
            } else {
                self.webView.reload()
            }
        }
    }

    private func handleSafetyWarning(ships: [ShipDisplay], reason: String?) {
        UINotificationFeedbackGenerator().notificationOccurred(.error)

        let content = UNMutableNotificationContent()
        content.title = ships.isEmpty ? "⚠️ 艦これ HP判定不明" : "🚨 艦これ 大破警告"
        if !ships.isEmpty {
            content.body = ships.map(\.name).joined(separator: "、") + " が大破。進撃ロック中です。"
        } else {
            content.body = reason ?? "HPを安全に判定できません。進撃ロック中です。"
        }
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func number(_ value: Any?) -> CGFloat? {
        if let value = value as? CGFloat { return value }
        if let value = value as? Double { return CGFloat(value) }
        if let value = value as? NSNumber { return CGFloat(value.doubleValue) }
        return nil
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
