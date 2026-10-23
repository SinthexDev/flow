import AppKit
import SwiftUI

enum LiveStreamLayout {
    static let headerHeight: CGFloat = 30
    static let lineHeight: CGFloat = 22
    static let maxLines = 3
    static let pillGap: CGFloat = 8
    static let pillHeight: CGFloat = 38
    /// Waagerechter Innenabstand je Wort, links plus rechts.
    static let tokenPadding: CGFloat = 5
    static let textTop: CGFloat = 8
    static let textBottom: CGFloat = 8

    static func cardHeight(lines: Int) -> CGFloat {
        let count = min(max(lines, 1), maxLines)
        return headerHeight + 0.5 + textTop + CGFloat(count) * lineHeight + textBottom
    }

    static func panelSize(lines: Int, width: CGFloat) -> NSSize {
        let height = cardHeight(lines: lines) + pillGap + pillHeight + OverlayView.pillBottomInset
        return NSSize(width: width, height: height)
    }
}

private struct LiveHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct LiveStreamCard: View {
    @ObservedObject var model: LiveStreamModel
    var width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rows: [LiveRowToken] {
        var result: [LiveRowToken] = []
        for sentence in model.sentences {
            for id in sentence.tokenIDs {
                guard let token = model.tokens[id] else { continue }
                result.append(LiveRowToken(token: token, state: sentence.state, failed: sentence.failed, index: result.count))
            }
        }
        return result
    }

    private var spoken: String {
        rows.map(\.token.text).joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
                .padding(.horizontal, 14)
            textFlow
                .padding(.horizontal, 14)
                .padding(.top, LiveStreamLayout.textTop)
                .padding(.bottom, LiveStreamLayout.textBottom)
        }
        .frame(width: width, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(white: 0.1).opacity(0.97))
        )
        .softDropShadow(.menu)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken.isEmpty ? L10n.s("overlay.live.title") : spoken)
        .onAppear {
            model.reduceMotion = reduceMotion
            model.noteWidth(width)
        }
        .onChange(of: reduceMotion) { _, value in
            model.reduceMotion = value
        }
        .onChange(of: width) { _, value in
            model.noteWidth(value)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.badge.checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(model.degraded ? Color.orange : Color.white.opacity(0.7))
            Text(L10n.s("overlay.live.title"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            Spacer(minLength: 4)
            statusLabel
            if model.polishingCount > 0 {
                ThinkingWave()
                    .frame(width: 28, height: 12)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: LiveStreamLayout.headerHeight)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if model.degraded {
            Text(L10n.s("overlay.live.degraded"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else if model.polishingCount >= 2 {
            Text(L10n.s("overlay.live.pending", model.polishingCount))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .contentTransition(.numericText())
        } else {
            Text(L10n.s("overlay.live.committed", model.committedCount))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
    }

    private var statusColor: Color {
        if model.copiedFlash { return .orange }
        if model.commitPulse { return .green }
        return .white.opacity(0.55)
    }

    @ViewBuilder
    private var textFlow: some View {
        let tokens = rows
        if tokens.isEmpty {
            HStack(spacing: 4) {
                Text(L10n.s("overlay.live.placeholder"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                LiveCaret()
            }
            .frame(maxWidth: .infinity, minHeight: LiveStreamLayout.lineHeight, alignment: .leading)
            .background(heightReader)
        } else {
            // Das Layout bestimmt seine Höhe selbst (höchstens drei Zeilen, Rest läuft oben raus).
            FlowWrapLayout(lineHeight: LiveStreamLayout.lineHeight) {
                ForEach(tokens) { row in
                    LiveTokenView(row: row, reduceMotion: reduceMotion || model.reduceMotion)
                        .transition(row.token.phase == .entering ? Self.enterTransition : Self.arriveTransition)
                }
                LiveCaret()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .mask(model.overflows ? topFade : nil)
            .background(heightReader)
        }
    }

    private var heightReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: LiveHeightKey.self, value: proxy.size.height)
        }
        .onPreferenceChange(LiveHeightKey.self) { height in
            let lines = Int((height / LiveStreamLayout.lineHeight).rounded())
            model.reportLines(lines)
        }
    }

    /// Neu erkanntes Wort: kommt leicht von rechts herein.
    private static let arriveTransition: AnyTransition = .asymmetric(
        insertion: .tokenShift(x: 6, y: 0, blur: 2),
        removal: .opacity
    )

    /// Korrektur: schwebt von unten ein und schärft sich.
    private static let enterTransition: AnyTransition = .asymmetric(
        insertion: .tokenShift(x: 0, y: 10, blur: 3),
        removal: .opacity
    )

    private var topFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.22),
                .init(color: .black, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct TokenShift: ViewModifier {
    var x: CGFloat
    var y: CGFloat
    var blur: CGFloat
    var opacity: Double

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .blur(radius: blur)
            .offset(x: x, y: y)
    }
}

private extension AnyTransition {
    static func tokenShift(x: CGFloat, y: CGFloat, blur: CGFloat) -> AnyTransition {
        .modifier(
            active: TokenShift(x: x, y: y, blur: blur, opacity: 0),
            identity: TokenShift(x: 0, y: 0, blur: 0, opacity: 1)
        )
    }
}

private struct LiveRowToken: Identifiable {
    var token: LiveToken
    var state: LiveSentence.State
    var failed: Bool
    var index: Int
    var id: UUID { token.id }
}

private struct LiveTokenView: View {
    let row: LiveRowToken
    var reduceMotion: Bool

    private var token: LiveToken { row.token }
    private var committing: Bool { row.state == .committing }
    private var selected: Bool { token.phase == .selected }
    private var leaving: Bool { token.phase == .leaving }

    var body: some View {
        Text(token.text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(textOpacity))
            .padding(.horizontal, LiveStreamLayout.tokenPadding / 2)
            .padding(.vertical, 1)
            .background(highlight)
            .blur(radius: reduceMotion ? 0 : blur)
            .offset(x: reduceMotion ? 0 : offsetX, y: reduceMotion ? 0 : offsetY)
            .opacity(leaving || committing ? 0 : 1)
    }

    private var textOpacity: Double {
        switch token.phase {
        case .tail: return 0.42
        case .raw: return 0.62
        case .entering: return 0.8
        case .selected, .polished: return 0.95
        case .leaving: return 0.95
        }
    }

    private var blur: CGFloat { leaving ? 3 : 0 }
    private var offsetY: CGFloat { leaving ? -9 : 0 }
    private var offsetX: CGFloat { committing ? -30 : 0 }

    @ViewBuilder
    private var highlight: some View {
        ZStack {
            if row.state == .polishing && !selected && !leaving {
                if reduceMotion {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.violet.opacity(0.10))
                } else {
                    PolishWash(delay: Double(row.index % 12) * 0.06)
                }
            }
            if committing {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.green.opacity(0.16))
            }
            if row.failed && row.state == .polishing {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.orange.opacity(0.2))
            }
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.violet.opacity(0.34))
                .scaleEffect(x: selected || leaving ? 1 : 0.15, anchor: .leading)
                .opacity(selected || leaving ? 1 : 0)
        }
    }
}

/// Atmendes Violett über einem Satz, den das Sprachmodell gerade prüft. Läuft als Welle von links.
private struct PolishWash: View {
    let delay: Double
    @State private var on = false

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Theme.violet.opacity(on ? 0.2 : 0.05))
            .onAppear {
                withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true).delay(delay)) {
                    on = true
                }
            }
    }
}

private struct LiveCaret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Theme.violet.opacity(reduceMotion ? 0.7 : (bright ? 0.9 : 0.35)))
            .frame(width: 1.5, height: 15)
            .padding(.leading, 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    bright = true
                }
            }
    }
}

struct FlowWrapLayout: Layout {
    var lineHeight: CGFloat = 22

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let rows = wrap(subviews, width: width)
        let lines = min(max(rows.count, 1), LiveStreamLayout.maxLines)
        return CGSize(width: width, height: CGFloat(lines) * lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = wrap(subviews, width: bounds.width)
        guard !rows.isEmpty else { return }
        // Die letzten Zeilen bleiben sichtbar, ältere laufen oben raus.
        let hidden = max(0, rows.count - LiveStreamLayout.maxLines)
        var y = bounds.minY - CGFloat(hidden) * lineHeight
        for row in rows {
            var x = bounds.minX
            for index in row {
                let size = subviews[index].sizeThatFits(.unspecified)
                let yPos = y + max(0, (lineHeight - size.height) / 2)
                subviews[index].place(
                    at: CGPoint(x: x, y: yPos),
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width
            }
            y += lineHeight
        }
    }

    private func wrap(_ subviews: Subviews, width: CGFloat) -> [[Int]] {
        guard !subviews.isEmpty else { return [] }
        var rows: [[Int]] = [[]]
        var x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append([index])
                x = size.width
            } else {
                rows[rows.count - 1].append(index)
                x += size.width
            }
        }
        return rows
    }
}
