import Foundation
import SQLite3

private let home = FileManager.default.homeDirectoryForCurrentUser

enum HTTP {
    /// 캐시·쿠키 저장소가 없는 세션. URLSession.shared는 요청 헤더(토큰 포함)를
    /// ~/Library/Caches/AIUsageBar/Cache.db에 평문으로 남기므로 쓰지 않는다.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }()

    static func getJSON(_ url: URL, headers: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 15)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200..<300: break
        case 401, 403: throw FetchError.auth("")
        case 429:
            let retry = http?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? 600
            throw FetchError.rateLimited(until: Date().addingTimeInterval(min(max(retry, 60), 3_600)))
        case let code: throw FetchError.http(code)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FetchError.parse }
        return obj
    }

    static func post(_ url: URL, body: Data, contentType: String, headers: [String: String] = [:]) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200..<300: break
        case 400, 401, 403: throw FetchError.auth("")
        case 429: throw FetchError.rateLimited(until: Date().addingTimeInterval(600))
        case let code: throw FetchError.http(code)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FetchError.parse }
        return obj
    }

    static func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
}

/// 외부 명령을 실행하고 stdout을 반환한다. 토큰이 담길 수 있으므로 절대 로그로 남기지 않는다.
@discardableResult
func runCommand(_ path: String, _ args: [String], env: [String: String]? = nil) -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let env { p.environment = env }
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? data : nil
}

// MARK: - Claude (Claude Code CLI OAuth 토큰 → /api/oauth/usage)

enum ClaudeProvider {
    struct Credential { let token: String; let expiresAt: Date; let plan: String? }

    static let cliPaths = ["\(home.path)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]

    static func loadCredential() -> Credential? {
        var found: [Credential] = []
        if let d = runCommand("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"]),
           let c = parse(d) { found.append(c) }
        if let d = try? Data(contentsOf: home.appendingPathComponent(".claude/.credentials.json")),
           let c = parse(d) { found.append(c) }
        return found.max { $0.expiresAt < $1.expiresAt }
    }

    private static func parse(_ data: Data) -> Credential? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let o = root["claudeAiOauth"] as? [String: Any],
              let token = o["accessToken"] as? String else { return nil }
        let exp = HTTP.number(o["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1_000) } ?? .distantFuture
        return Credential(token: token, expiresAt: exp, plan: o["subscriptionType"] as? String)
    }

    /// 만료된 액세스 토큰을 CLI가 스스로 갱신하도록 `claude auth status`를 실행한다.
    /// (이 앱이 직접 refresh하면 refresh token이 회전돼 CLI 로그인이 깨지므로 하지 않는다.)
    static func nudgeCLI() async {
        guard let cli = cliPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        await Task.detached {
            _ = runCommand(cli, ["auth", "status"], env: ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin"])
        }.value
    }

    static func label(_ key: String) -> String {
        switch key {
        case "five_hour": return "5시간"
        case "seven_day": return "주간"
        case "seven_day_opus": return "주간 Opus"
        case "seven_day_sonnet": return "주간 Sonnet"
        case "extra_usage": return "추가 사용량"
        default: return key.replacingOccurrences(of: "_", with: " ")
        }
    }

    static func fetch() async throws -> ProviderUsage {
        var cred = loadCredential()
        if cred.map({ $0.expiresAt < Date().addingTimeInterval(60) }) ?? true {
            await nudgeCLI()
            cred = loadCredential()
        }
        guard let c = cred, c.expiresAt > Date() else {
            throw FetchError.auth("Claude CLI 로그인 필요 — 메뉴의 ‘Claude CLI 로그인…’")
        }

        let json: [String: Any]
        do {
            json = try await HTTP.getJSON(URL(string: "https://api.anthropic.com/api/oauth/usage")!, headers: [
                "Authorization": "Bearer \(c.token)",
                "anthropic-beta": "oauth-2025-04-20",
                "Accept": "application/json",
            ])
        } catch FetchError.auth {
            throw FetchError.auth("Claude 토큰 거부됨 — ‘Claude CLI 로그인…’ 다시 실행")
        }

        var u = ProviderUsage(name: c.plan.map { "Claude (\($0.capitalized))" } ?? "Claude", short: "C")
        let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
        // 알려진 창과 seven_day_* 모델별 창만 표시(내부 코드명·추가 사용량 등은 제외)
        let keys = order.filter { json[$0] != nil }
            + json.keys.filter { !order.contains($0) && $0.hasPrefix("seven_day_") }.sorted()
        for key in keys {
            guard let w = json[key] as? [String: Any], let util = HTTP.number(w["utilization"]) else { continue }
            u.windows.append(UsageWindow(label: label(key), usedPercent: util,
                                         resetsAt: (w["resets_at"] as? String).flatMap(Fmt.parseISO)))
        }
        guard !u.windows.isEmpty else { throw FetchError.parse }
        return u
    }
}

// MARK: - ChatGPT (Codex 로그인 토큰 → /backend-api/wham/usage)

enum CodexProvider {
    static func label(seconds: Double?) -> String {
        guard let s = seconds else { return "한도" }
        switch Int(s) {
        case 18_000: return "5시간"
        case 86_400: return "일간"
        case 604_800: return "주간"
        default: return s >= 86_400 ? "\(Int(s / 86_400))일" : "\(Int(s / 3_600))시간"
        }
    }

    static func window(_ w: [String: Any]) -> UsageWindow {
        let reset = HTTP.number(w["reset_at"]).map { Date(timeIntervalSince1970: $0) }
            ?? HTTP.number(w["reset_after_seconds"]).map { Date().addingTimeInterval($0) }
        return UsageWindow(label: label(seconds: HTTP.number(w["limit_window_seconds"])),
                           usedPercent: HTTP.number(w["used_percent"]) ?? 0, resetsAt: reset)
    }

    static func fetch() async throws -> ProviderUsage {
        let dir = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("auth.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String else {
            throw FetchError.missing("Codex 로그인 정보 없음 — Codex 앱 또는 `codex login`")
        }
        var headers = ["Authorization": "Bearer \(access)", "User-Agent": "codex_cli_rs", "Accept": "application/json"]
        if let account = tokens["account_id"] as? String { headers["ChatGPT-Account-Id"] = account }

        let json: [String: Any]
        do {
            json = try await HTTP.getJSON(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: headers)
        } catch FetchError.auth {
            throw FetchError.auth("ChatGPT 토큰 만료 — Codex 앱/CLI를 한 번 실행")
        }

        let plan = (json["plan_type"] as? String).map { " (\($0.capitalized))" } ?? ""
        var u = ProviderUsage(name: "ChatGPT · Codex" + plan, short: "G")
        if let rl = json["rate_limit"] as? [String: Any] {
            for key in ["primary_window", "secondary_window"] {
                if let w = rl[key] as? [String: Any] { u.windows.append(window(w)) }
            }
        }
        if let credits = json["credits"] as? [String: Any], credits["has_credits"] as? Bool == true {
            if credits["unlimited"] as? Bool == true {
                u.extras.append("크레딧 무제한")
            } else if let bal = HTTP.number(credits["balance"]) {
                u.extras.append("크레딧 잔액 \(bal.formatted(.number.precision(.fractionLength(0))))")
            }
        }
        guard !u.windows.isEmpty || !u.extras.isEmpty else { throw FetchError.parse }
        return u
    }
}

// MARK: - Cursor (Cursor 앱 로그인 토큰 → cursor.com/api/usage-summary)

enum CursorProvider {
    static let dbPath = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path

    /// Cursor 앱의 로컬 설정 DB에서 액세스 토큰을 읽기 전용으로 꺼낸다.
    static func accessToken() -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    /// JWT 본문에서 사용자 ID(sub)와 만료 시각을 읽는다.
    static func claims(_ jwt: String) -> (user: String, exp: Date?)? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = obj["sub"] as? String else { return nil }
        return (sub.components(separatedBy: "|").last ?? sub, HTTP.number(obj["exp"]).map { Date(timeIntervalSince1970: $0) })
    }

    static func fetch() async throws -> ProviderUsage {
        guard let token = accessToken(), let c = claims(token) else {
            throw FetchError.missing("Cursor 로그인 정보 없음 — Cursor 앱에서 로그인")
        }
        if let exp = c.exp, exp < Date() { throw FetchError.auth("Cursor 토큰 만료 — Cursor 앱을 한 번 실행") }

        let json: [String: Any]
        do {
            json = try await HTTP.getJSON(URL(string: "https://cursor.com/api/usage-summary")!, headers: [
                "Cookie": "WorkosCursorSessionToken=\(c.user)%3A%3A\(token)",
                "Origin": "https://cursor.com",
                "Accept": "application/json",
            ])
        } catch FetchError.auth {
            throw FetchError.auth("Cursor 토큰 거부됨 — Cursor 앱을 한 번 실행")
        }

        let plan = (json["membershipType"] as? String).map { " (\($0.capitalized))" } ?? ""
        var u = ProviderUsage(name: "Cursor" + plan, short: "^")
        let reset = (json["billingCycleEnd"] as? String).flatMap(Fmt.parseISO)
        if json["isUnlimited"] as? Bool == true { u.extras.append("무제한 플랜") }
        if let p = (json["individualUsage"] as? [String: Any])?["plan"] as? [String: Any] {
            // 전체(Auto 포함) 사용률과, 직접 고른 API 모델 사용률이 따로 있다.
            if let total = HTTP.number(p["totalPercentUsed"]) { u.windows.append(UsageWindow(label: "월간 전체", usedPercent: total, resetsAt: reset)) }
            if let api = HTTP.number(p["apiPercentUsed"]) { u.windows.append(UsageWindow(label: "월간 API", usedPercent: api, resetsAt: reset)) }
        }
        if let od = (json["individualUsage"] as? [String: Any])?["onDemand"] as? [String: Any], od["enabled"] as? Bool == true,
           let used = HTTP.number(od["used"]) {
            u.extras.append("온디맨드 사용 $\((used / 100).formatted(.number.precision(.fractionLength(2))))")
        }
        guard !u.windows.isEmpty || !u.extras.isEmpty else { throw FetchError.parse }
        return u
    }
}

// MARK: - Gemini (Antigravity 로그인 토큰 → cloudcode-pa fetchAvailableModels)
//
// Gemini CLI(개인용)는 종료되어 Antigravity로 이전됐다. 구독(Google AI Pro/Ultra) 쿼터는
// Antigravity가 쓰는 cloudcode-pa API에서 모델별 remainingFraction / resetTime으로 온다.

enum GeminiProvider {
    private static let tokenFile = home.appendingPathComponent(".gemini/jetski-standalone-oauth-token")
    /// 만료된 Antigravity 토큰을 갱신할 때 쓰는 OAuth 클라이언트(선택).
    /// 저장소에 비밀값을 넣지 않기 위해 환경 변수나 앱 설정에서 읽는다. 없으면 Antigravity 앱이
    /// 스스로 갱신해 둔 토큰만 사용한다. 설정 방법은 README의 Gemini 항목 참고.
    private static var oauthClient: (id: String, secret: String)? {
        let env = ProcessInfo.processInfo.environment, d = UserDefaults.standard
        guard let id = env["AIUSAGEBAR_GEMINI_CLIENT_ID"] ?? d.string(forKey: "geminiClientID"),
              let secret = env["AIUSAGEBAR_GEMINI_CLIENT_SECRET"] ?? d.string(forKey: "geminiClientSecret"),
              !id.isEmpty, !secret.isEmpty else { return nil }
        return (id, secret)
    }
    private static let api = "https://cloudcode-pa.googleapis.com/v1internal:"

    // 갱신한 액세스 토큰은 메모리에만 둔다(파일에 다시 쓰지 않음 → Antigravity 로그인에 영향 없음).
    private static var cachedToken: (value: String, expiry: Date)?
    private static var project: String?
    private static var plan: String?

    private static func accessToken() async throws -> String {
        if let t = cachedToken, t.expiry > Date().addingTimeInterval(120) { return t.value }
        guard let data = try? Data(contentsOf: tokenFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tok = root["token"] as? [String: Any] else {
            throw FetchError.missing("Antigravity 로그인 정보 없음 — Antigravity 앱에서 로그인")
        }
        if let at = tok["access_token"] as? String, let exp = (tok["expiry"] as? String).flatMap(Fmt.parseISO),
           exp > Date().addingTimeInterval(120) {
            cachedToken = (at, exp); return at
        }
        guard let refresh = tok["refresh_token"] as? String else { throw FetchError.auth("Antigravity 재로그인 필요") }
        guard let client = oauthClient else {
            throw FetchError.auth("Antigravity 토큰 만료 — Antigravity 앱을 한 번 실행하세요")
        }
        var form = URLComponents()
        form.queryItems = [.init(name: "client_id", value: client.id), .init(name: "client_secret", value: client.secret),
                           .init(name: "grant_type", value: "refresh_token"), .init(name: "refresh_token", value: refresh)]
        let json: [String: Any]
        do {
            json = try await HTTP.post(URL(string: "https://oauth2.googleapis.com/token")!,
                                       body: Data((form.percentEncodedQuery ?? "").utf8),
                                       contentType: "application/x-www-form-urlencoded")
        } catch FetchError.auth { throw FetchError.auth("Antigravity 로그인 만료 — Antigravity 앱에서 다시 로그인") }
        guard let at = json["access_token"] as? String else { throw FetchError.parse }
        cachedToken = (at, Date().addingTimeInterval(HTTP.number(json["expires_in"]) ?? 3_000))
        return at
    }

    static func fetch() async throws -> ProviderUsage {
        let token = try await accessToken()
        let headers = ["Authorization": "Bearer \(token)", "User-Agent": "antigravity/1.0 darwin/arm64"]
        func call(_ method: String, _ body: [String: Any]) async throws -> [String: Any] {
            do {
                return try await HTTP.post(URL(string: api + method)!, body: try JSONSerialization.data(withJSONObject: body),
                                           contentType: "application/json", headers: headers)
            } catch FetchError.auth {
                cachedToken = nil
                throw FetchError.auth("Gemini 쿼터 조회 거부됨 — Antigravity 앱에서 다시 로그인")
            }
        }
        if project == nil {
            let info = try await call("loadCodeAssist", ["metadata": ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]])
            project = (info["cloudaicompanionProject"] as? String) ?? ((info["cloudaicompanionProject"] as? [String: Any])?["id"] as? String)
            plan = ((info["paidTier"] as? [String: Any]) ?? (info["currentTier"] as? [String: Any]))?["name"] as? String
        }
        let models = try await call("fetchAvailableModels", ["project": project ?? ""])["models"] as? [String: Any] ?? [:]

        // 모델들을 Pro / Flash / Claude 묶음으로 나누고, 묶음 안에서 가장 적게 남은 값을 쓴다.
        var groups: [String: (remaining: Double, reset: Date?)] = [:]
        for (id, value) in models {
            guard let m = value as? [String: Any], let name = m["displayName"] as? String,
                  let q = m["quotaInfo"] as? [String: Any], let frac = HTTP.number(q["remainingFraction"]) else { continue }
            let key: String
            if id.hasPrefix("claude") || name.hasPrefix("Claude") { key = "Claude (AG)" }
            else if name.contains("Image") { continue }
            else if name.contains("Pro") { key = "Gemini Pro" }
            else if name.contains("Flash") { key = "Gemini Flash" }
            else { continue }
            let reset = (q["resetTime"] as? String).flatMap(Fmt.parseISO)
            if let cur = groups[key], cur.remaining <= frac { continue }
            groups[key] = (frac, reset)
        }
        var u = ProviderUsage(name: plan.map { "Gemini (\($0))" } ?? "Gemini", short: "*")
        for key in ["Gemini Pro", "Gemini Flash", "Claude (AG)"] {
            guard let g = groups[key] else { continue }
            u.windows.append(UsageWindow(label: key.replacingOccurrences(of: "Gemini ", with: ""),
                                         usedPercent: (1 - g.remaining) * 100, resetsAt: g.reset))
        }
        guard !u.windows.isEmpty else { throw FetchError.parse }
        return u
    }
}

// MARK: - Grok 수동 리셋 타이머(웹 연결이 안 될 때의 대안)

enum GrokTimer {
    private static let key = "grokResetAt"

    static var resetAt: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: key)
            guard t > 0 else { return nil }
            let d = Date(timeIntervalSince1970: t)
            return d > Date() ? d : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: key) }
    }
}
