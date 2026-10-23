import SwiftUI

/// Engine picker for speech recognition: four cards across the full width, plus a detail
/// panel for the selected engine. Cards stay scannable (icon, name, speed, one-line scope);
/// the panel holds the sentences.
struct EngineChoiceList: View {
    @Binding var selection: String

    private struct Engine: Identifiable {
        let tag: String
        let icon: String
        /// 1...5 segments, purely relative.
        let speed: Int
        /// Short badge, e.g. "Fastest".
        let badge: String
        /// Scope line, e.g. "25 EU languages".
        let scope: String
        var id: String { tag }
    }

    private let engines: [Engine] = [
        Engine(tag: "parakeet", icon: "bolt.fill", speed: 5,
               badge: "settings.asr.chip.fastest", scope: "settings.asr.chip.eu"),
        Engine(tag: "qwen3", icon: "globe.asia.australia.fill", speed: 4,
               badge: "settings.asr.chip.fast", scope: "settings.asr.chip.asia"),
        Engine(tag: "whisper", icon: "waveform.circle.fill", speed: 2,
               badge: "settings.asr.chip.accurate", scope: "settings.asr.chip.langs99"),
        Engine(tag: "whistle", icon: "leaf.fill", speed: 5,
               badge: "settings.asr.chip.tiny", scope: "settings.asr.chip.langs7"),
    ]

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 10, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(engines) { engine in
                    EngineCard(
                        title: L10n.s("settings.asr.\(engine.tag)"),
                        icon: engine.icon,
                        speed: engine.speed,
                        badge: L10n.s(engine.badge),
                        scope: L10n.s(engine.scope),
                        selected: selection == engine.tag
                    ) {
                        withAnimation(.easeOut(duration: 0.16)) { selection = engine.tag }
                    }
                }
            }

            detailPanel(for: engines.first { $0.tag == selection } ?? engines[2])
        }
    }

    // MARK: Detail panel

    private func detailPanel(for engine: Engine) -> some View {
        let t = engine.tag
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: engine.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.violet)
                Text(L10n.s("settings.asr.\(t)"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.bottom, 10)

            Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 10) {
                GridRow {
                    fact("bolt", "settings.asr.facts.speed", "settings.asr.\(t).speed")
                    fact("globe", "settings.asr.facts.languages", "settings.asr.\(t).languages")
                }
                GridRow {
                    fact("internaldrive", "settings.asr.facts.size", "settings.asr.\(t).size")
                    fact("star", "settings.asr.facts.bestFor", "settings.asr.\(t).bestFor")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.violet.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.violet.opacity(0.18))
        )
        .id(t)
        .transition(.opacity)
    }

    private func fact(_ icon: String, _ labelKey: String, _ valueKey: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(L10n.s(labelKey))
                    .font(.system(size: 10.5, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.4)
            } icon: {
                Image(systemName: icon)
                    .font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
            Text(L10n.s(valueKey))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Card

private struct EngineCard: View {
    let title: String
    let icon: String
    let speed: Int
    let badge: String
    let scope: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Theme.violet)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.violet.opacity(0.12)))
                        )
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(selected ? Theme.violet : Color.primary.opacity(0.22))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(scope)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 5) {
                    SpeedMeter(level: speed, active: selected)
                    Text(badge)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(selected ? Theme.violet : .secondary)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Theme.violet.opacity(0.08) : Color.primary.opacity(hovering ? 0.05 : 0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Theme.violet.opacity(0.55) : Theme.stroke, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Five small bars, filled up to `level`. Relative speed only, no numbers.
private struct SpeedMeter: View {
    let level: Int
    let active: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { index in
                Capsule()
                    .fill(index <= level
                          ? (active ? Theme.violet : Color.primary.opacity(0.45))
                          : Color.primary.opacity(0.10))
                    .frame(width: 16, height: 4)
            }
        }
        .accessibilityHidden(true)
    }
}
