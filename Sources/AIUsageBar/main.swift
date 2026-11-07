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
        await show("Gemini") { try await GeminiProvider.fetch() }
        await show("OpenCode Go") { try await OpenCodeProvider.fetch() }
        let mon = SystemMonitor()
        _ = mon.sample()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let s = mon.sample()
        func pct(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "--" }
        print("[Mac · \(s.chip)]")
        print("  CPU \(pct(s.cpu)) · GPU \(pct(s.gpu))\(s.gpuMemory.map { " (GPU 메모리 \(SystemStats.gb($0)) GB)" } ?? "")")
        print("  메모리 \(SystemStats.gb(s.memUsed)) / \(SystemStats.gb(s.memTotal)) GB (\(pct(s.memPercent))) · 압박 \(s.pressureLabel) · 스왑 \(SystemStats.gb(s.swapUsed)) GB")
        print("  열 상태 \(s.thermalLabel)")
        print("[Grok · Cursor] 앱 안의 grok.com 로그인으로 확인(--dump 미지원)\(CursorPlan.unifiedTier().map { " · Cursor 요금제 \($0)" } ?? "")")
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
