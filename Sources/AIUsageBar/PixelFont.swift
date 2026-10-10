import AppKit
import SwiftUI

/// 3×5 도트 매트릭스 글꼴. 메뉴 막대·위젯의 숫자를 점으로 그린다.
enum PixelFont {
    static let rows = 5
    private static let glyphs: [Character: [String]] = [
        "0": ["111", "101", "101", "101", "111"],
        "1": ["010", "110", "010", "010", "111"],
        "2": ["111", "001", "111", "100", "111"],
        "3": ["111", "001", "111", "001", "111"],
        "4": ["101", "101", "111", "001", "001"],
        "5": ["111", "100", "111", "001", "111"],
        "6": ["111", "100", "111", "101", "111"],
        "7": ["111", "001", "010", "010", "010"],
        "8": ["111", "101", "111", "101", "111"],
        "9": ["111", "101", "111", "001", "111"],
        "%": ["101", "001", "010", "100", "101"],
        "-": ["000", "000", "111", "000", "000"],
        "C": ["111", "100", "100", "100", "111"],
        "G": ["111", "100", "101", "101", "111"],
        "X": ["101", "101", "010", "101", "101"],
        "^": ["100", "110", "111", "110", "001"],   // Cursor 화살표
        "*": ["010", "010", "111", "010", "010"],   // Gemini 반짝이
        "d": ["001", "001", "111", "101", "111"],
        "h": ["100", "100", "111", "101", "101"],
        "m": ["000", "000", "111", "111", "101"],
        ":": ["0", "1", "0", "1", "0"],
        " ": ["0", "0", "0", "0", "0"],
    ]

    private static func pattern(_ c: Character) -> [String] { glyphs[c] ?? glyphs[" "]! }

    /// 문자열 폭(도트 열 수). 글자 사이 1열 간격 포함.
    static func columns(_ s: String) -> Int {
        max(0, s.reduce(0) { $0 + pattern($1)[0].count + 1 } - 1)
    }

    /// 켜진 도트 좌표 (x, y). y=0이 맨 위.
    static func dots(_ s: String) -> [(x: Int, y: Int)] {
        var out: [(Int, Int)] = []
        var x = 0
        for c in s {
            let p = pattern(c)
            for (y, row) in p.enumerated() {
                for (dx, bit) in row.enumerated() where bit == "1" { out.append((x + dx, y)) }
            }
            x += p[0].count + 1
        }
        return out
    }

    /// 사용 기간 하나: 위 = 잔여 %, 아래 = 리셋까지 남은 시간
    struct BarColumn {
        let top: String, topColor: NSColor
        let bottom: String, bottomColor: NSColor
    }
    struct BarGroup {
        let label: String, labelColor: NSColor
        let columns: [BarColumn]
    }

    /// 메뉴 막대용 2줄 이미지: [큰 서비스 글자] [기간1 위/아래] [기간2 위/아래] …
    static func menuBarImage(_ groups: [BarGroup]) -> NSImage {
        let height: CGFloat = 22
        let lp: CGFloat = 4.0, ld: CGFloat = 3.2          // 서비스 글자 도트 간격·크기
        let p: CGFloat = 1.9, d: CGFloat = 1.6             // 숫자 도트 간격·크기
        let innerGap: CGFloat = 3, columnGap: CGFloat = 4, groupGap: CGFloat = 8
        func colWidth(_ c: BarColumn) -> CGFloat { CGFloat(max(columns(c.top), columns(c.bottom))) * p }
        func groupWidth(_ g: BarGroup) -> CGFloat {
            CGFloat(columns(g.label)) * lp + innerGap
                + g.columns.map(colWidth).reduce(0, +) + columnGap * CGFloat(max(0, g.columns.count - 1))
        }
        let width = groups.map(groupWidth).reduce(0, +) + groupGap * CGFloat(max(0, groups.count - 1))
        return NSImage(size: NSSize(width: max(width, 1), height: height), flipped: true) { _ in
            func draw(_ text: String, _ color: NSColor, x: CGFloat, y: CGFloat, pitch: CGFloat, dot: CGFloat) {
                color.setFill()
                for c in dots(text) {
                    NSBezierPath(ovalIn: NSRect(x: x + CGFloat(c.x) * pitch, y: y + CGFloat(c.y) * pitch, width: dot, height: dot)).fill()
                }
            }
            var x: CGFloat = 0
            let rowH = CGFloat(rows) * p
            let top = (height - rowH * 2 - 2.2) / 2
            for g in groups {
                draw(g.label, g.labelColor, x: x, y: (height - CGFloat(rows) * lp) / 2 + 0.4, pitch: lp, dot: ld)
                var cx = x + CGFloat(columns(g.label)) * lp + innerGap
                for c in g.columns {
                    draw(c.top, c.topColor, x: cx, y: top, pitch: p, dot: d)
                    draw(c.bottom, c.bottomColor, x: cx, y: top + rowH + 2.2, pitch: p, dot: d)
                    cx += colWidth(c) + columnGap
                }
                x += groupWidth(g) + groupGap
            }
            return true
        }
    }

    /// (이전 1줄 버전) groups = 프로바이더별 [(글자, 색)] 조각.
    static func menuBarImage(_ groups: [[(String, NSColor)]], pitch: CGFloat = 2.4, dot: CGFloat = 2.0) -> NSImage {
        let groupGap = 4
        let widths = groups.map { $0.reduce(0) { $0 + columns($1.0) + 1 } - 1 }
        let cols = widths.reduce(0, +) + groupGap * max(0, groups.count - 1)
        let height: CGFloat = 18
        let size = NSSize(width: CGFloat(max(cols, 1)) * pitch, height: height)
        // drawingHandler는 그릴 때마다 호출되므로 라이트/다크 모드 색이 자동으로 맞춰진다.
        return NSImage(size: size, flipped: true) { _ in
            let top = ((height - CGFloat(rows) * pitch) / 2).rounded()
            var x0 = 0
            for group in groups {
                for (text, color) in group {
                    color.setFill()
                    for d in dots(text) {
                        NSBezierPath(ovalIn: NSRect(x: CGFloat(x0 + d.x) * pitch, y: top + CGFloat(d.y) * pitch,
                                                    width: dot, height: dot)).fill()
                    }
                    x0 += columns(text) + 1
                }
                x0 += groupGap - 1
            }
            return true
        }
    }
}

/// 서비스별 고유 색.
enum Brand {
    static func nsColor(_ short: String) -> NSColor {
        switch short {
        case "C": return NSColor(srgbRed: 0.93, green: 0.49, blue: 0.33, alpha: 1)   // Claude 주황
        case "G": return NSColor(srgbRed: 0.10, green: 0.75, blue: 0.55, alpha: 1)   // ChatGPT/Codex 초록
        case "X": return NSColor(srgbRed: 0.40, green: 0.60, blue: 1.00, alpha: 1)   // Grok 파랑
        case "^": return NSColor(srgbRed: 0.72, green: 0.50, blue: 1.00, alpha: 1)   // Cursor 보라
        case "*": return NSColor(srgbRed: 0.98, green: 0.78, blue: 0.20, alpha: 1)   // Gemini 노랑
        default: return .labelColor
        }
    }
    static func color(_ short: String) -> Color { Color(nsColor: nsColor(short)) }
}

/// SwiftUI용 도트 글자.
struct PixelText: View {
    let text: String
    var color: Color = .primary
    var pitch: CGFloat = 2.6

    var body: some View {
        Canvas { ctx, _ in
            for d in PixelFont.dots(text) {
                let r = CGRect(x: CGFloat(d.x) * pitch, y: CGFloat(d.y) * pitch, width: pitch * 0.82, height: pitch * 0.82)
                ctx.fill(Path(ellipseIn: r), with: .color(color))
            }
        }
        .frame(width: CGFloat(PixelFont.columns(text)) * pitch, height: CGFloat(PixelFont.rows) * pitch)
    }
}

/// 남은 비율을 점 N개로 표시하는 막대.
struct DotBar: View {
    let remaining: Double
    let color: Color
    var count = 20

    var body: some View {
        let filled = Int((remaining / 100 * Double(count)).rounded())
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { i in
                Circle().fill(i < filled ? color : Color.primary.opacity(0.13)).frame(width: 5, height: 5)
            }
        }
    }
}
