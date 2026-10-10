import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var claude = ProviderUsage(name: "Claude", short: "C", error: "불러오는 중…")
    private var codex = ProviderUsage(name: "ChatGPT · Codex", short: "G", error: "불러오는 중…")
    private var claudeBlockedUntil: Date?
    private var codexBlockedUntil: Date?
    private var cursor = ProviderUsage(name: "Cursor", short: "^", error: "불러오는 중…")
    private var cursorBlockedUntil: Date?
    private var gemini = ProviderUsage(name: "Gemini", short: "*", error: "불러오는 중…")
    private var geminiBlockedUntil: Date?
    private var lastRefresh: Date?
    private var refreshing = false
    private var timers: [Timer] = []
    private let store = UsageStore()
    private var panel: UsagePanel?
    private let showPanelKey = "showPanel"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.purgeLegacyCache()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.autosaveName = "AIUsageBarItem"      // ⌘+드래그로 옮긴 위치 기억
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "AI 사용량 (Claude · ChatGPT/Codex · Grok)"
        GrokWeb.shared.onUpdate = { [weak self] in self?.renderTitle() }

        panel = UsagePanel(rootView: UsageWidgetView(
            store: store,
            onRefresh: { [weak self] in self?.refreshNow() },
            onGrokTimer: { [weak self] in self?.setGrokTimer() },
            onGrokLogin: { GrokWeb.shared.showLogin() },
            onHide: { [weak self] in self?.togglePanel() }))
        if UserDefaults.standard.bool(forKey: showPanelKey) { panel?.orderFrontRegardless() }
        renderTitle()

        Task { await refresh() }
        if CommandLine.arguments.contains("--grok-login") { GrokWeb.shared.showLogin() }
        // 5분마다 데이터 갱신, 30초마다 카운트다운 표시만 갱신
        timers.append(Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renderTitle() }
        })
    }

    /// 이전 버전이 URLSession 기본 캐시에 남긴 요청(토큰 포함)과 점검 로그를 지운다.
    private static func purgeLegacyCache() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AIUsageBar")
        for name in ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData", "grok-last.json"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: - Data

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; lastRefresh = Date(); renderTitle() }

        if claudeBlockedUntil.map({ $0 <= Date() }) ?? true {
            do { claude = try await ClaudeProvider.fetch(); claude.fetchedAt = Date(); claudeBlockedUntil = nil }
            catch { claude = Self.failed(claude, error, blocked: &claudeBlockedUntil) }
        }
        if codexBlockedUntil.map({ $0 <= Date() }) ?? true {
            do { codex = try await CodexProvider.fetch(); codex.fetchedAt = Date(); codexBlockedUntil = nil }
            catch { codex = Self.failed(codex, error, blocked: &codexBlockedUntil) }
        }
        if cursorBlockedUntil.map({ $0 <= Date() }) ?? true {
            do { cursor = try await CursorProvider.fetch(); cursor.fetchedAt = Date(); cursorBlockedUntil = nil }
            catch { cursor = Self.failed(cursor, error, blocked: &cursorBlockedUntil) }
        }
        if geminiBlockedUntil.map({ $0 <= Date() }) ?? true {
            do { gemini = try await GeminiProvider.fetch(); gemini.fetchedAt = Date(); geminiBlockedUntil = nil }
            catch { gemini = Self.failed(gemini, error, blocked: &geminiBlockedUntil) }
        }
        GrokWeb.shared.refresh()   // 결과는 비동기로 도착해 onUpdate로 다시 그림
    }

    /// 실패해도 이전 데이터는 유지하고 '이전 데이터' 표시만 붙인다.
    private static func failed(_ old: ProviderUsage, _ error: Error, blocked: inout Date?) -> ProviderUsage {
        var u = old
        u.error = error.localizedDescription
        u.stale = !old.windows.isEmpty
        if case FetchError.rateLimited(let until) = error { blocked = until }
        return u
    }

    private var providers: [ProviderUsage] { [claude, codex, cursor, gemini, GrokWeb.shared.usage()] }

    // MARK: - Menu bar (도트 글자: C32 G84 X--)

    private func renderTitle() {
        store.providers = providers
        store.now = Date()
        // 이미지 안에서는 시스템 글자색이 메뉴 막대 밝기를 따르지 않으므로 직접 고른다.
        let dark = statusItem.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ink = dark ? NSColor(white: 1, alpha: 0.9) : NSColor(white: 0, alpha: 0.8)
        let faint = ink.withAlphaComponent(0.35)
        let groups: [PixelFont.BarGroup] = providers.map { p in
            let brand = Brand.nsColor(p.short)
            // 앞의 두 기간만 표시(Claude: 5시간 + 7일, 모델별 주간 창은 드롭다운에서)
            let cols = p.windows.prefix(2).map { w -> PixelFont.BarColumn in
                let pct = Int(w.remainingPercent.rounded())
                return .init(top: "\(pct)", topColor: pct < 10 ? .systemRed : brand,
                             bottom: w.resetsAt.map(Fmt.tinyCountdown) ?? "--", bottomColor: ink)
            }
            return .init(label: p.short, labelColor: brand,
                         columns: cols.isEmpty ? [.init(top: "--", topColor: faint, bottom: "--", bottomColor: faint)] : cols)
        }
        statusItem.button?.image = PixelFont.menuBarImage(groups)
    }

    // MARK: - Dropdown menu (열 때마다 새로 그림 → 카운트다운이 항상 최신)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        store.providers = providers
        store.now = Date()

        let card = NSHostingView(rootView: UsageWidgetView(store: store, embedded: true))
        card.frame.size = card.fittingSize
        let cardItem = NSMenuItem()
        cardItem.view = card
        menu.addItem(cardItem)
        menu.addItem(.separator())

        menu.addItem(action("지금 새로고침", #selector(refreshNow), key: "r"))
        menu.addItem(action("Grok 로그인…", #selector(grokLogin)))
        menu.addItem(action("Grok 리셋 타이머(수동)…", #selector(setGrokTimer)))
        if GrokTimer.resetAt != nil { menu.addItem(action("Grok 타이머 해제", #selector(clearGrokTimer))) }
        menu.addItem(action("Claude CLI 로그인…", #selector(claudeLogin)))
        menu.addItem(.separator())
        let widget = action("화면 위젯으로도 표시", #selector(togglePanel), key: "w")
        widget.state = panel?.isVisible == true ? .on : .off
        menu.addItem(widget)
        let login = action("로그인 시 자동 실행", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        if let t = lastRefresh {
            let info = NSMenuItem(title: "마지막 갱신 \(Fmt.clock(t)) · 5분마다 자동", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        let quit = NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func refreshNow() { Task { await refresh() } }

    @objc private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        UserDefaults.standard.set(panel.isVisible, forKey: showPanelKey)
    }

    @objc private func grokLogin() { GrokWeb.shared.showLogin() }

    @objc func setGrokTimer() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Grok 리셋까지 남은 시간"
        alert.informativeText = "Grok에 표시된 대기 시간을 입력하세요.\n예: 2h30m · 90m · 1:45 · 3(시간) · 2시간 30분"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "2h30m"
        alert.accessoryView = field
        alert.addButton(withTitle: "설정")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let secs = Fmt.parseDuration(field.stringValue) else { return showError("시간 형식을 읽을 수 없습니다: \(field.stringValue)") }
        GrokTimer.resetAt = Date().addingTimeInterval(secs)
        renderTitle()
    }

    @objc private func clearGrokTimer() { GrokTimer.resetAt = nil; renderTitle() }

    /// 터미널에서 `claude auth login`을 연다(.command 파일 방식이라 자동화 권한이 필요 없음).
    @objc private func claudeLogin() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AIUsageBar")
        let script = dir.appendingPathComponent("claude-login.command")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "#!/bin/zsh -l\nclaude auth login\necho\necho '완료되면 이 창을 닫고 AI Usage 메뉴에서 새로고침하세요.'\n"
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch { showError(error.localizedDescription) }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { showError("자동 실행 설정 실패: \(error.localizedDescription)") }
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
