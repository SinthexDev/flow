import SwiftUI

struct MainView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 236)
            Divider()
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                detail
                    .id(state.section)
                    .transition(.opacity)
            }
            .animation(.easeOut(duration: 0.15), value: state.section)
        }
        .frame(minWidth: 920, minHeight: 620)
        .tint(Theme.violet)
        .ignoresSafeArea()
        .overlay(alignment: .bottom) { settingToast }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: state.settingToastVisible)
    }

    @ViewBuilder
    private var settingToast: some View {
        if state.settingToastVisible {
            SettingsSavedToast()
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.section {
        case .home: HomeView()
        case .commands: CommandsView()
        case .history: HistoryView()
        case .notes: NotesView()
        case .style: StyleView()
        case .dictionary: DictionaryView()
        case .settings: SettingsView()
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                FlowMark(size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.appName)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text(L10n.s("main.local"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 54)
            .padding(.bottom, 22)

            VStack(spacing: 2) {
                ForEach(MainSection.allCases) { section in
                    SidebarItem(section: section)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            EngineCard()
                .padding(12)
        }
        .frame(maxHeight: .infinity)
        .background(VisualEffect(material: .sidebar))
    }
}

private struct SidebarItem: View {
    let section: MainSection
    @EnvironmentObject var state: AppState
    @State private var hovering = false
    @AppStorage(CommandsView.seenKey) private var commandsSeen = false

    var body: some View {
        let selected = state.section == section
        Button {
            state.section = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
                if section == .history, !state.history.isEmpty {
                    Text("\(state.history.count)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if section == .notes, !state.notes.isEmpty {
                    Text("\(state.notes.count)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if section == .commands, !commandsSeen || SnapshotMode.isActive, !selected {
                    Text(L10n.s("nav.new"))
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.gradient))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? Theme.violet : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Theme.violet.opacity(0.14) : Color.primary.opacity(hovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct EngineCard: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "cpu")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(L10n.s("main.engine"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                StatusPill(state: state.engineState, text: label)
            }
            Text(state.modelDisplayName)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(2)
            Text(stackLabel)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            if state.engineState == .error {
                Text(state.engineStatus)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .lineLimit(3)
                Button(L10n.s("settings.restart")) { state.reloadEngine() }
                    .buttonStyle(SoftButtonStyle())
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var label: String {
        switch state.engineState {
        case .ready: return L10n.s("status.ready")
        case .loading: return L10n.s("status.loading")
        case .error: return L10n.s("status.error")
        }
    }

    private var stackLabel: String {
        if state.config.usesFallbackCorrection { return L10n.s("main.stack.custom") }
        if state.config.usesCustomCorrectionAPI { return L10n.s("main.stack.custom") }
        if state.config.usesClaudeCorrection { return L10n.s("main.stack.claude") }
        if state.config.usesCursorCorrection { return L10n.s("main.stack.cursor") }
        return state.config.correctsWithOpenAI ? L10n.s("main.stack.on") : L10n.s("main.stack.off")
    }
}

struct UpdateBanner: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.violet)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.s("update.banner.title", state.availableRelease?.version ?? ""))
                    .font(.system(size: 14, weight: .semibold))
                Text(L10n.s("update.banner.body"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(L10n.s("update.banner.install"), action: state.installAvailableUpdate)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(state.isDownloadingUpdate)
                    Button(L10n.s("update.banner.later"), action: state.dismissUpdate)
                        .buttonStyle(SoftButtonStyle())
                        .disabled(state.isDownloadingUpdate)
                    if state.isDownloadingUpdate {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.violet.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.violet.opacity(0.25)))
    }
}

struct PermissionBanner: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.s("main.needsPermissions"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(L10n.s("main.needsPermissionsBody"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            PermissionRow(
                title: L10n.s("common.mic"),
                detail: L10n.s("settings.mic.detail"),
                icon: "mic.fill",
                granted: state.micGranted,
                action: state.requestMicrophone
            )
            PermissionRow(
                title: L10n.s("common.accessibility"),
                detail: L10n.s("settings.ax.banner"),
                icon: "accessibility",
                granted: state.axGranted,
                action: state.openAccessibility,
                repairHint: L10n.s("main.ax.repair")
            )
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.orange.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.orange.opacity(0.25)))
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let icon: String
    let granted: Bool
    let action: () -> Void
    var repairHint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(granted ? .green : .secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill((granted ? Color.green : Color.primary).opacity(0.1)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if granted {
                    Label(L10n.s("common.allowed"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                } else {
                    Button(L10n.s("common.allow"), action: action)
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
            if !granted, let repairHint {
                Text(repairHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 42)
            }
        }
    }
}
