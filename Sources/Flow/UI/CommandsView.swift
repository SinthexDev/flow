import SwiftUI

struct CommandExample: Identifiable {
    let id: String
    let icon: String

    var title: String { L10n.s("commands.ex.\(id).title") }
    var said: String { L10n.s("commands.ex.\(id).say") }
    var before: String { L10n.s("commands.ex.\(id).before") }
    var after: String { L10n.s("commands.ex.\(id).after") }

    static let all: [CommandExample] = [
        CommandExample(id: "note", icon: "note.text"),
        CommandExample(id: "translate", icon: "globe"),
        CommandExample(id: "summarize", icon: "text.redaction"),
        CommandExample(id: "friendly", icon: "face.smiling"),
        CommandExample(id: "shorter", icon: "scissors"),
        CommandExample(id: "list", icon: "list.bullet"),
        CommandExample(id: "proofread", icon: "checkmark.seal"),
        CommandExample(id: "formal", icon: "briefcase"),
        CommandExample(id: "simpler", icon: "lightbulb"),
        CommandExample(id: "email", icon: "envelope")
    ]
}

struct CommandsView: View {
    static let seenKey = "commandsTabSeen"

    @EnvironmentObject var state: AppState
    @AppStorage(CommandsView.seenKey) private var seen = false

    var body: some View {
        Page(title: L10n.s("commands.title"), subtitle: L10n.s("commands.subtitle")) {
            CommandsHero()

            HStack(alignment: .top, spacing: 14) {
                step(1, icon: "cursorarrow.and.square.on.square.dashed", title: L10n.s("commands.step1.title"), body: L10n.s("commands.step1.body"))
                step(2, icon: "mic.fill", title: L10n.s("commands.step2.title", state.config.resolvedHotkey.title), body: L10n.s("commands.step2.body"))
                step(3, icon: "arrow.2.squarepath", title: L10n.s("commands.step3.title"), body: L10n.s("commands.step3.body"))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.s("commands.examples.title"))
                    .font(.system(size: 14, weight: .semibold))
                Text(L10n.s("commands.examples.body"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 3), spacing: 14) {
                ForEach(CommandExample.all) { example in
                    CommandExampleCard(example: example)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Label(L10n.s("commands.tips.title"), systemImage: "info.circle")
                    .font(.system(size: 14, weight: .semibold))
                tip("character.bubble", L10n.s("commands.tip.language"))
                tip("textformat", L10n.s("commands.tip.style"))
                tip("arrow.uturn.backward", L10n.s("commands.tip.undo"))
                tip("text.cursor", L10n.s("commands.tip.noSelection"))
                tip("macwindow.on.rectangle", L10n.s("commands.tip.noField"))
            }
            .card()
        }
        .onAppear { if !SnapshotMode.isActive { seen = true } }
    }

    private func step(_ number: Int, icon: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.gradient))
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.violet)
            }
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(body)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .card(padding: 16)
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.violet)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CommandsHero: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.s("commands.hero.eyebrow"))
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.7))
                Text(L10n.s("commands.hero.headline"))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(L10n.s("commands.hero.body"))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Image(systemName: statusIcon)
                    Text(statusText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.top, 4)
                if needsModel {
                    Button(L10n.s("nav.settings")) { state.section = .settings }
                        .buttonStyle(SoftButtonStyle())
                }
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $state.config.commandMode)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.large)
                .tint(.white.opacity(0.35))
        }
        .foregroundStyle(.white)
        .padding(26)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.gradient))
        .shadow(color: Theme.violet.opacity(0.3), radius: 18, y: 8)
    }

    private var needsModel: Bool { state.engineReady && !state.polishAvailable }

    private var statusIcon: String {
        if needsModel { return "exclamationmark.triangle.fill" }
        return state.config.commandMode ? "checkmark.circle.fill" : "pause.circle.fill"
    }

    private var statusText: String {
        if needsModel { return L10n.s("commands.status.needsModel") }
        return state.config.commandMode
            ? L10n.s("commands.status.on", state.config.resolvedHotkey.title)
            : L10n.s("commands.status.off")
    }
}

private struct CommandExampleCard: View {
    let example: CommandExample

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: example.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.violet)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.violet.opacity(0.12)))
                Text(example.title)
                    .font(.system(size: 13.5, weight: .semibold))
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.pink)
                Text(example.said)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.violet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                label(L10n.s("commands.label.selected"))
                Text(example.before)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                label(L10n.s("commands.label.result"))
                    .padding(.top, 2)
                Text(example.after)
                    .font(.system(size: 11.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.04)))
            Spacer(minLength: 0)
        }
        .card(padding: 16)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(.tertiary)
    }
}
