import AppKit
import ServiceManagement

// `AIUsageBar --enable-login-item`: 로그인 시 자동 실행 등록 후 상태 출력
if CommandLine.arguments.contains("--enable-login-item") {
    do { try SMAppService.mainApp.register() } catch { print("등록 실패: \(error.localizedDescription)") }
    print("login item status:", SMAppService.mainApp.status == .enabled ? "enabled" : "\(SMAppService.mainApp.status.rawValue)")
    exit(0)
}

// `AIUsageBar --dump`: UI 없이 현재 사용량을 터미널에 출력(점검용, 토큰은 출력하지 않음)
if CommandLine.arguments.contains("--dump") {
    Task {
        func show(_ name: String, _ work: () async throws -> ProviderUsage) async {
            do {
                let u = try await work()
                print("[\(u.name)]")
                for w in u.windows {
                    let reset = w.resetsAt.map { "  리셋 \(Fmt.countdown($0)) (\(Fmt.clock($0)))" } ?? ""
                    print("  \(w.label): 잔여 \(Int(w.remainingPercent.rounded()))%\(reset)")
                }
                u.extras.forEach { print("  \($0)") }
            } catch {
                print("[\(name)] 오류: \(error.localizedDescription)")
            }
        }
        await show("Claude") { try await ClaudeProvider.fetch() }
        await show("ChatGPT") { try await CodexProvider.fetch() }
        await show("Cursor") { try await CursorProvider.fetch() }
        await show("Gemini") { try await GeminiProvider.fetch() }
        print("[Grok] 앱 안의 웹 로그인으로 확인(--dump 미지원)")
        exit(0)
    }
    RunLoop.main.run()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
