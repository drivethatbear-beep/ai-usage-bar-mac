import AppKit
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published var providers: [ProviderUsage] = []
    @Published var now = Date()
}

func levelColor(_ remaining: Double) -> Color {
    remaining < 10 ? .red : remaining < 30 ? .orange : .green
}

func levelNSColor(_ remaining: Double) -> NSColor {
    remaining < 10 ? .systemRed : remaining < 30 ? .systemOrange : .labelColor
}

private let mono = Font.system(size: 10, design: .monospaced)

/// 도트 디자인 사용량 카드. 드롭다운 메뉴 안(embedded)과 떠 있는 위젯에서 같이 쓴다.
struct UsageWidgetView: View {
    @ObservedObject var store: UsageStore
    var embedded = false
    var onRefresh: () -> Void = {}
    var onGrokTimer: () -> Void = {}
    var onGrokLogin: () -> Void = {}
    var onHide: () -> Void = {}

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            ForEach(store.providers, id: \.short) { p in
                ProviderBlock(p: p)
                if p.short != store.providers.last?.short { DottedDivider() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, embedded ? 8 : 12)
        .frame(width: 320, alignment: .leading)
        .id(store.now)   // 30초마다 카운트다운 다시 그림

        if embedded {
            content
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
                .contextMenu {
                    Button("지금 새로고침", action: onRefresh)
                    Button("Grok 로그인…", action: onGrokLogin)
                    Button("Grok 리셋 타이머(수동)…", action: onGrokTimer)
                    Divider()
                    Button("위젯 숨기기", action: onHide)
                }
        }
    }
}

private struct DottedDivider: View {
    var body: some View {
        Line().stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.1, 4]))
            .foregroundStyle(.primary.opacity(0.25)).frame(height: 2)
    }
    struct Line: Shape {
        func path(in r: CGRect) -> Path { Path { $0.move(to: CGPoint(x: 0, y: r.midY)); $0.addLine(to: CGPoint(x: r.maxX, y: r.midY)) } }
    }
}

private struct ProviderBlock: View {
    let p: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 6) {
                Circle().fill(Brand.color(p.short)).frame(width: 8, height: 8)
                Text(p.name.uppercased()).font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Brand.color(p.short))
                if p.stale { Text("· 이전 데이터").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary) }
                Spacer()
                headline
            }
            ForEach(Array(p.windows.enumerated()), id: \.offset) { _, w in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(w.label).font(mono).lineLimit(1).frame(width: 78, alignment: .leading)
                        DotBar(remaining: w.remainingPercent, color: w.remainingPercent < 10 ? .red : Brand.color(p.short))
                        Spacer(minLength: 0)
                        Text("\(Int(w.remainingPercent.rounded()))%").font(mono.monospacedDigit()).frame(width: 34, alignment: .trailing)
                    }
                    if let r = w.resetsAt {
                        (Text("↻ 리셋까지 ") + Text(Fmt.remaining(r)).bold() + Text(" · \(Fmt.clock(r))"))
                            .font(mono).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(p.extras, id: \.self) { Text($0).font(mono).foregroundStyle(.secondary) }
            if let e = p.error {
                Text("⚠︎ \(e)").font(mono).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var headline: some View {
        if let w = p.windows.min(by: { $0.remainingPercent < $1.remainingPercent }) {
            if w.label == "한도 도달", let r = w.resetsAt {
                PixelText(text: Fmt.shortCountdown(r), color: .red)
            } else {
                PixelText(text: "\(Int(w.remainingPercent.rounded()))%", color: w.remainingPercent < 10 ? .red : Brand.color(p.short))
            }
        } else {
            PixelText(text: "--", color: .secondary)
        }
    }
}

/// 모든 데스크톱(스페이스)에 떠 있고, 포커스를 뺏지 않는 테두리 없는 창.
final class UsagePanel: NSPanel {
    init(rootView: some View) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 320),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        let host = NSHostingController(rootView: rootView)
        host.sizingOptions = [.preferredContentSize]
        contentViewController = host

        if !setFrameUsingName("AIUsagePanel"), let screen = NSScreen.main {
            let v = screen.visibleFrame
            setFrameTopLeftPoint(NSPoint(x: v.maxX - 336, y: v.maxY - 12))
        }
        setFrameAutosaveName("AIUsagePanel")
    }

    override var canBecomeKey: Bool { true }
}
