import SwiftUI
import WebKit
import ZCodeMobileCore

/// 登录页:WKWebView 打开官方落地页,让官方页面完成 Z.ai/BigModel OAuth,
/// 轮询收割 localStorage["zcodejwttoken"](Android 实测路径,iOS 同构)。
struct LoginView: View {
    @EnvironmentObject var model: AppModel
    @State private var showManualPaste = false
    @State private var manualJWT = ""

    /// 登录落地页:已配对则带 sid(登录后直接连),否则打开远控首页
    private var landingURL: URL {
        if let device = model.device, let url = URL(string: device.landingUrl) {
            return url
        }
        return URL(string: "https://zcode.z.ai/remote/v4")!
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LoginWebView(url: landingURL) { jwt in
                    model.loginHarvested(jwt: jwt)
                }
                if showManualPaste {
                    manualPasteSection
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Motion.smooth, value: showManualPaste)
            .navigationTitle("登录 ZCode 账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(model.device == nil ? "返回配对" : "重新扫码") {
                        Haptics.light()
                        model.screen = .pairing
                    }
                    .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(showManualPaste ? "收起" : "粘贴 Token") {
                        Haptics.selection()
                        withAnimation(Motion.smooth) { showManualPaste.toggle() }
                    }
                }
            }
        }
    }

    private var manualPasteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("高级：手动粘贴 zcodejwttoken（从桌面端浏览器 localStorage 获取）")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                SecureField("eyJ…", text: $manualJWT)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.inputFill))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 0.8))
                Button {
                    if let clip = UIPasteboard.general.string, !clip.isEmpty {
                        Haptics.light()
                        manualJWT = clip
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 38, height: 38)
                        .liquidGlassChrome(in: Circle(), interactive: true)
                }
                .buttonStyle(bouncy(scale: 0.92))
                Button("使用") {
                    let trimmed = manualJWT.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    Haptics.success()
                    model.loginHarvested(jwt: trimmed)
                }
                .buttonStyle(.glassProminent)
                .disabled(manualJWT.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if TokenStore.isExpired(manualJWT.trimmingCharacters(in: .whitespacesAndNewlines)) && !manualJWT.isEmpty {
                Label("此 token 已过期或无效", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.coral)
            }
        }
        .padding(16)
        .frostedSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous), strong: true, shadowRadius: 14)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }
}

// MARK: - WKWebView 收割器(支持 OAuth 弹窗双窗口)
//
// 「通过浏览器授权登录」= window.open 新开 zchat.z.ai/bigmodel 授权页,回调页靠
// window.opener 交付令牌。必须用真实的第二个 WKWebView 承载弹窗:
// - javaScriptCanOpenWindowsAutomatically = true(否则异步 window.open 被静默吞掉)
// - 弹窗与主窗口共用 WKWebsiteDataStore(localStorage 同源共享,令牌落地主窗口可收割)
// - 弹窗 window.close() / 收割成功 → 自动收起

struct LoginWebView: UIViewRepresentable {
    let url: URL
    let onJWT: (String) -> Void

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // Cookie/localStorage 持久化,二次登录免输
        config.preferences.javaScriptCanOpenWindowsAutomatically = true // ★ window.open 必需
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(context.coordinator, name: "zcmConsole")
        config.userContentController.add(context.coordinator, name: "zcmPopup")
        config.userContentController.addUserScript(WKUserScript(
            source: """
            (function(){
                const send = (level, args) => {
                    try { window.webkit.messageHandlers.zcmConsole.postMessage(level + ' ' + args.map(a => { try { return typeof a === 'string' ? a : JSON.stringify(a); } catch(e){ return String(a); } }).join(' ')); } catch(e){}
                };
                for (const level of ['log','info','warn','error']) {
                    const orig = console[level].bind(console);
                    console[level] = (...args) => { send(level, args); orig(...args); };
                }
                window.addEventListener('unhandledrejection', e => send('unhandledrejection', [String(e.reason && e.reason.message || e.reason)]));
                window.addEventListener('error', e => send('error', [e.message + ' @' + (e.filename||'') + ':' + e.lineno]));
                // window.open shim:WebKit 会吞掉非手势弹窗(官方登录是 async 后开窗 → 拿到 null → 「授权流程未完成」)。
                // 返回代理窗口对象满足官方代码的用法(window.open('about:blank') → e.opener=null → e.location.href=url),
                // 真实导航转交原生侧弹出独立 WebView。
                window.open = function(url, target, features) {
                    const notify = (action, u) => {
                        try { window.webkit.messageHandlers.zcmPopup.postMessage({ action: action, url: u }); } catch(e) {}
                    };
                    let href = (url && url !== 'about:blank') ? url : 'about:blank';
                    const proxy = {
                        opener: window,
                        closed: false,
                        focus() {}, blur() {},
                        close() { proxy.closed = true; notify('close', null); },
                        postMessage() {},
                        location: {}
                    };
                    Object.defineProperty(proxy.location, 'href', {
                        get: () => href,
                        set: (v) => {
                            href = v;
                            if (v && v !== 'about:blank') notify('navigate', v);
                        }
                    });
                    if (href !== 'about:blank') notify('navigate', href);
                    return proxy;
                };
            })();
            """,
            injectionTime: .atDocumentStart, forMainFrameOnly: false))

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        context.coordinator.webView = webView
        context.coordinator.container = container
        webView.load(URLRequest(url: url))
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateUIView(_ webView: UIView, context: Context) {}

    func makeCoordinator() -> HarvestCoordinator {
        HarvestCoordinator(onJWT: onJWT)
    }

    final class HarvestCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onJWT: (String) -> Void
        weak var webView: WKWebView?
        weak var container: UIView?
        private(set) var popupWebView: WKWebView?
        private var completed = false
        private var pollTimer: Timer?
        #if DEBUG
        private var fakeInjected = false
        #endif

        init(onJWT: @escaping (String) -> Void) {
            self.onJWT = onJWT
            super.init()
            // SPA 登录完成不一定触发导航,加轮询兜底;主窗口+弹窗都查(localStorage 同源共享)
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
                self?.harvest()
            }
        }

        // MARK: 导航

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            harvest()
            scheduleLoginProbe(webView)
            #if DEBUG
            if let fake = ProcessInfo.processInfo.environment["ZCODEMOBILE_FAKE_JWT"], !fakeInjected {
                fakeInjected = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak webView] in
                    webView?.evaluateJavaScript("localStorage.setItem('oauth:browser_session', JSON.stringify({version:1, provider:'zai_cn', zcodeJwtToken:'\(fake)', userInfo:{id:'test'}, revision:'r1'}))") { _, err in
                        NSLog("[ZCodeMobile][probe] fake session injected err=%@", String(describing: err))
                    }
                }
            }
            #endif
        }

        /// 读取登录凭据:新版写 oauth:browser_session(主),旧版写 zcodejwttoken(回退)
        static let jwtProbeJS = """
        (function(){
            try {
                const raw = localStorage.getItem('oauth:browser_session');
                if (raw) {
                    const s = JSON.parse(raw);
                    if (s && s.version === 1 && typeof s.zcodeJwtToken === 'string' && s.zcodeJwtToken.length > 0) {
                        return s.zcodeJwtToken;
                    }
                }
            } catch(e) {}
            const legacy = localStorage.getItem('zcodejwttoken');
            return legacy || null;
        })()
        """

        private func scheduleLoginProbe(_ webView: WKWebView) {
            #if DEBUG
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self, weak webView] in
                guard let self, let webView, !self.completed, self.popupWebView == nil else { return }
                webView.evaluateJavaScript("window.open('about:blank','_blank') ? 'popup-ok' : 'popup-blocked'") { result, _ in
                    NSLog("[ZCodeMobile][probe] window.open => %@", String(describing: result))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    webView.evaluateJavaScript("document.querySelector('[data-testid=regional-login-submit]')?.click() ?? 'no-button'") { result, _ in
                        NSLog("[ZCodeMobile][probe] click submit => %@", String(describing: result))
                    }
                }
            }
            #endif
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            switch message.name {
            case "zcmConsole":
                if let text = message.body as? String {
                    NSLog("[ZCodeMobile][web] %@", text)
                }
            case "zcmPopup":
                if let body = message.body as? [String: Any],
                   let action = body["action"] as? String {
                    let url = body["url"] as? String
                    DispatchQueue.main.async {
                        switch action {
                        case "navigate":
                            NSLog("[ZCodeMobile][popup] navigate %@", url ?? "?")
                            if let url, let target = URL(string: url) {
                                self.openPopup(with: URLRequest(url: target))
                            }
                        case "close":
                            NSLog("[ZCodeMobile][popup] close")
                            self.dismissPopup()
                        default:
                            break
                        }
                    }
                }
            default:
                break
            }
        }

        /// 原生弹窗(与 createWebViewWith 路径共用的展示逻辑)
        private func openPopup(with request: URLRequest) {
            if let existing = popupWebView {
                existing.load(request)
                return
            }
            guard let container = container else { return }
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            config.preferences.javaScriptCanOpenWindowsAutomatically = true
            let popup = WKWebView(frame: container.bounds, configuration: config)
            popup.navigationDelegate = self
            popup.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            popup.backgroundColor = .systemBackground
            container.addSubview(popup)
            popupWebView = popup

            let close = UIButton(type: .system)
            close.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
            close.tintColor = .secondaryLabel
            close.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.8)
            close.layer.cornerRadius = 14
            close.clipsToBounds = true
            close.addTarget(self, action: #selector(dismissPopup), for: .touchUpInside)
            close.translatesAutoresizingMaskIntoConstraints = false
            popup.addSubview(close)
            NSLayoutConstraint.activate([
                close.topAnchor.constraint(equalTo: popup.safeAreaLayoutGuide.topAnchor, constant: 8),
                close.trailingAnchor.constraint(equalTo: popup.safeAreaLayoutGuide.trailingAnchor, constant: -8),
                close.widthAnchor.constraint(equalToConstant: 28),
                close.heightAnchor.constraint(equalToConstant: 28),
            ])
            popup.load(request)
        }

        /// OAuth 弹窗:返回真实的第二个 WebView(覆盖在主窗口上,共用数据存储)
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            // 已有弹窗则复用
            if let existing = popupWebView {
                existing.load(navigationAction.request)
                return existing
            }
            guard let container = container else { return nil }

            let popup = WKWebView(frame: container.bounds, configuration: configuration)
            popup.navigationDelegate = self
            popup.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            popup.backgroundColor = .systemBackground
            container.addSubview(popup)
            popupWebView = popup

            // 关闭按钮(授权页不想要了可以手动退回)
            let close = UIButton(type: .system)
            close.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
            close.tintColor = .secondaryLabel
            close.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.8)
            close.layer.cornerRadius = 14
            close.clipsToBounds = true
            close.addTarget(self, action: #selector(dismissPopup), for: .touchUpInside)
            close.translatesAutoresizingMaskIntoConstraints = false
            popup.addSubview(close)
            NSLayoutConstraint.activate([
                close.topAnchor.constraint(equalTo: popup.safeAreaLayoutGuide.topAnchor, constant: 8),
                close.trailingAnchor.constraint(equalTo: popup.safeAreaLayoutGuide.trailingAnchor, constant: -8),
                close.widthAnchor.constraint(equalToConstant: 28),
                close.heightAnchor.constraint(equalToConstant: 28),
            ])

            popup.load(navigationAction.request)
            return popup
        }

        /// 弹窗自己 window.close()
        func webViewDidClose(_ webView: WKWebView) {
            dismissPopup()
        }

        /// 试图唤起外部 App 的自定义 scheme → 忽略,留在当前页
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let scheme = navigationAction.request.url?.scheme?.lowercased(),
               scheme != "http", scheme != "https", scheme != "about", scheme != "data" {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        @objc func dismissPopup() {
            popupWebView?.removeFromSuperview()
            popupWebView = nil
        }

        // MARK: 收割

        private func harvest() {
            guard !completed else { return }
            var targets: [WKWebView] = []
            if let webView { targets.append(webView) }
            if let popupWebView { targets.append(popupWebView) }
            guard !targets.isEmpty else { return }
            for target in targets {
                target.evaluateJavaScript(Self.jwtProbeJS) { [weak self] result, error in
                    guard let self, !self.completed else { return }
                    if let error {
                        NSLog("[ZCodeMobile][harvest] evaluate error: %@", String(describing: error))
                        return
                    }
                    if let jwt = result as? String, !jwt.isEmpty {
                        NSLog("[ZCodeMobile][harvest] token found len=%d expired=%@", jwt.count, String(TokenStore.isExpired(jwt)))
                        if !TokenStore.isExpired(jwt) {
                            self.completed = true
                            self.pollTimer?.invalidate()
                            self.dismissPopup()
                            NSLog("[ZCodeMobile][harvest] delivering JWT -> session")
                            self.onJWT(jwt)
                        }
                    }
                }
            }
        }
    }
}
