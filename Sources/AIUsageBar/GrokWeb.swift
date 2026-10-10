import AppKit
import WebKit

/// Grok 구독 사용량: 앱 안의 웹뷰로 grok.com에 로그인해 두고, 페이지 안에서 사용량 API를 호출한다.
/// 로그인은 사용자가 직접 하며 쿠키는 이 앱의 WebKit 저장소에만 남는다.
@MainActor
final class GrokWeb: NSObject, WKNavigationDelegate, NSWindowDelegate {
    static let shared = GrokWeb()

    private let webView: WKWebView
    private var loginWindow: NSWindow?
    private var windows: [String: UsageWindow] = [:]     // 모델/엔드포인트별
    private var lastData: Date?
    private(set) var needsLogin = false
    var onUpdate: (() -> Void)?

    private static let debugFile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AIUsageBar/grok-last.json")

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 760), configuration: config)
        super.init()
        // 구글 로그인이 내장 웹뷰를 막지 않도록 Safari로 표시
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.navigationDelegate = self
    }

    // MARK: - Public

    func refresh() {
        if webView.url?.host?.hasSuffix("grok.com") == true, !webView.isLoading { probe() }
        else { webView.load(URLRequest(url: URL(string: "https://grok.com/")!)) }
    }

    func showLogin() {
        if loginWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Grok 로그인 — 로그인 후 이 창을 닫으세요"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = webView
            w.center()
            loginWindow = w
        }
        webView.load(URLRequest(url: URL(string: "https://grok.com/")!))
        NSApp.activate(ignoringOtherApps: true)
        loginWindow?.makeKeyAndOrderFront(nil)
    }

    func usage() -> ProviderUsage {
        var u = ProviderUsage(name: "Grok", short: "X")
        let fresh = lastData.map { Date().timeIntervalSince($0) < 3_600 } ?? false
        if fresh, !windows.isEmpty {
            u.windows = windows.keys.sorted().compactMap { windows[$0] }
            u.fetchedAt = lastData
        } else if let r = GrokTimer.resetAt {
            u.windows = [UsageWindow(label: "한도 도달", usedPercent: 100, resetsAt: r)]
            u.extras = ["수동 타이머"]
        } else if needsLogin || lastData == nil {
            u.error = "Grok 연결 필요 — 메뉴/위젯 우클릭 ‘Grok 로그인…’"
        } else {
            u.error = "사용량 응답을 해석하지 못함"
        }
        return u
    }

    // MARK: - Probing
    //
    // /rest/rate-limits는 2026년부터 항상 '전부 남음'을 돌려줘 실제 사용량과 다르다.
    // 실제 구독 사용률은 gRPC-web RPC grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig에서 온다.

    private func probe() {
        let js = """
        const out = [];
        for (const base of ["", "/api"]) {
          try {
            // gRPC-web 프레임: [flag 0][길이 4바이트][GetGrokCreditsConfigRequest{exclude_legacy_monthly_usage: true}]
            const r = await fetch(base + "/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig", {
              method: "POST", credentials: "include",
              headers: {"content-type": "application/grpc-web+proto", "x-grpc-web": "1", "accept": "application/grpc-web+proto"},
              body: new Uint8Array([0, 0, 0, 0, 2, 8, 1])});
            const buf = new Uint8Array(await r.arrayBuffer());
            let bin = ""; for (const b of buf) bin += String.fromCharCode(b);
            out.push({url: base + "/GetGrokCreditsConfig", status: r.status, grpc: r.headers.get("grpc-status"), b64: btoa(bin)});
            if (r.ok && buf.length > 5 && buf[0] === 0) break;
          } catch (e) { out.push({url: base, status: 0, b64: "", err: String(e)}); }
        }
        return JSON.stringify(out);
        """
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self, case .success(let value) = result, let text = value as? String,
                  let arr = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else { return }
            for item in arr {
                let data = Data(base64Encoded: item["b64"] as? String ?? "") ?? Data()
                self.handle(url: item["url"] as? String ?? "?", status: Int(HTTP.number(item["status"]) ?? 0),
                            grpcStatus: item["grpc"] as? String, data: data, err: item["err"] as? String)
            }
        }
    }

    private func handle(url: String, status: Int, grpcStatus: String?, data: Data, err: String?) {
        let parsed = GrokCredits.decode(data)
        saveDebug(url: url, status: status, body: "grpc-status=\(grpcStatus ?? "-") bytes=\(data.count) \(err ?? "") parsed=\(parsed.map { "\($0.usedPercent)% reset=\($0.resetsAt.map { "\($0)" } ?? "-") label=\($0.label)" } ?? "nil")")
        if status == 401 || status == 403 || grpcStatus == "16" { needsLogin = true; onUpdate?(); return }
        guard let w = parsed else { return }
        needsLogin = false
        windows = ["credits": w]
        lastData = Date()
        onUpdate?()
    }

    /// 응답 형식 점검용으로 마지막 응답을 남긴다(쿠키·토큰은 포함되지 않음).
    private func saveDebug(url: String, status: Int, body: String) {
        guard ProcessInfo.processInfo.environment["AIUSAGEBAR_DEBUG"] == "1" else { return }
        let entry = "// \(Date()) \(url) HTTP \(status)\n\(body.prefix(4_000))\n"
        try? FileManager.default.createDirectory(at: Self.debugFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = (try? String(contentsOf: Self.debugFile, encoding: .utf8)) ?? ""
        try? String((old + entry).suffix(20_000)).write(to: Self.debugFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.debugFile.path)
    }

    // MARK: - WebKit delegates

    /// 로그인 창 메인 프레임에서 열 수 있는 주소. 그 밖의 링크는 기본 브라우저로 연다.
    /// xAI 소유 도메인만 하위 도메인까지 허용하고, 외부 로그인 제공자는 로그인 전용 호스트만 정확히 허용한다
    /// (예: sites.google.com 처럼 누구나 페이지를 올릴 수 있는 주소가 🔒와 함께 열리지 않도록).
    private static let ownedDomains = ["grok.com", "x.ai"]
    private static let exactHosts = ["x.com", "twitter.com", "api.x.com", "api.twitter.com",
                                     "accounts.google.com", "appleid.apple.com", "challenges.cloudflare.com"]

    private static func isAllowed(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.absoluteString == "about:blank" { return true }
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return exactHosts.contains(host) || ownedDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        if !(action.targetFrame?.isMainFrame ?? true) || Self.isAllowed(url) { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        if let url, url.scheme == "https" { NSWorkspace.shared.open(url) }
    }

    /// 주소창이 없으므로 지금 보고 있는 도메인을 창 제목에 보여준다(피싱 확인용).
    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor in
            let host = webView.url?.host ?? "?"
            let secure = webView.hasOnlySecureContent ? "🔒" : "⚠︎"
            self.loginWindow?.title = "Grok 로그인 — \(secure) \(host)  (로그인 후 창을 닫으세요)"
        }
    }

    /// 로그인 창을 닫으면 바로 사용량을 다시 읽는다.
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.probe() }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard webView.url?.host?.hasSuffix("grok.com") == true else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.probe()
        }
    }
}

/// GetGrokCreditsConfig 응답(gRPC-web + protobuf)을 스키마 없이 필요한 필드만 직접 읽는다.
///   GetGrokCreditsConfigResponse { config = 1 }
///   GrokCreditsConfig { credit_usage_percent = 1 (float), current_period = 8, billing_period_end = 5 }
///   UsagePeriod { type = 1, start = 2, end = 3 (Timestamp{seconds = 1}) }
enum GrokCredits {
    static func decode(_ data: Data) -> UsageWindow? {
        let b = [UInt8](data)
        var i = 0
        var message: [UInt8]?
        while i + 5 <= b.count {                       // gRPC-web 프레임 순회
            let flag = b[i]
            let len = Int(b[i + 1]) << 24 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 8 | Int(b[i + 4])
            guard i + 5 + len <= b.count else { break }
            if flag & 0x80 == 0 { message = Array(b[(i + 5)..<(i + 5 + len)]) }
            i += 5 + len
        }
        guard let msg = message, let config = Proto.fields(msg)[1]?.first?.bytes else { return nil }
        let f = Proto.fields(config)
        guard let pct = f[1]?.first?.float else { return nil }
        let used = pct <= 1 && pct > 0 ? Double(pct) * 100 : Double(pct)   // 0~1 비율로 올 경우 대비

        var label = "구독"
        var reset: Date?
        if let period = f[8]?.first?.bytes {
            let p = Proto.fields(period)
            let start = p[2]?.first?.bytes.flatMap(timestamp)
            reset = p[3]?.first?.bytes.flatMap(timestamp)
            if let s = start, let e = reset {
                let days = e.timeIntervalSince(s) / 86_400
                label = days < 2 ? "일간" : days < 10 ? "주간" : "월간"
            }
        }
        if reset == nil { reset = f[5]?.first?.bytes.flatMap(timestamp) }
        return UsageWindow(label: label, usedPercent: used, resetsAt: reset)
    }

    private static func timestamp(_ b: [UInt8]) -> Date? {
        guard let s = Proto.fields(b)[1]?.first?.varint else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(s))
    }
}

/// 최소한의 protobuf 와이어 포맷 리더.
enum Proto {
    enum Value {
        case varint(UInt64), fixed32(UInt32), fixed64(UInt64), bytes([UInt8])
        var bytes: [UInt8]? { if case .bytes(let b) = self { return b }; return nil }
        var varint: UInt64? { if case .varint(let v) = self { return v }; return nil }
        var float: Float? { if case .fixed32(let v) = self { return Float(bitPattern: v) }; return nil }
    }

    static func fields(_ b: [UInt8]) -> [Int: [Value]] {
        var out: [Int: [Value]] = [:]
        var i = 0
        func readVarint() -> UInt64? {
            var r: UInt64 = 0, shift: UInt64 = 0
            while i < b.count {
                let x = b[i]; i += 1
                r |= UInt64(x & 0x7f) << shift
                if x < 0x80 { return r }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < b.count {
            guard let key = readVarint() else { break }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0: guard let v = readVarint() else { return out }; out[field, default: []].append(.varint(v))
            case 1:
                guard i + 8 <= b.count else { return out }
                var v: UInt64 = 0; for k in 0..<8 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
                i += 8; out[field, default: []].append(.fixed64(v))
            case 2:
                guard let l = readVarint(), l <= UInt64(b.count - i) else { return out }
                out[field, default: []].append(.bytes(Array(b[i..<(i + Int(l))]))); i += Int(l)
            case 5:
                guard i + 4 <= b.count else { return out }
                var v: UInt32 = 0; for k in 0..<4 { v |= UInt32(b[i + k]) << (8 * UInt32(k)) }
                i += 4; out[field, default: []].append(.fixed32(v))
            default: return out
            }
        }
        return out
    }
}
