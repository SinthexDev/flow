import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            recordButton
                .padding(.horizontal, 14)

            if !state.hasPermissions {
                permissionHint
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }

            if state.update == .checking {
                updateChecking
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            } else if state.showsUpdateOffer {
                updateHint
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text(L10n.s("menu.correction"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("", isOn: $state.config.autoCorrect)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!state.engineReady)
                }
                .help(state.polishAvailable ? "" : (
                    state.config.usesCustomCorrectionAPI
                        ? L10n.s("menu.correctionUnavailable")
                        : L10n.s("menu.correctionNeedsKey")
                ))
                HStack(spacing: 8) {
                    Text(L10n.s("menu.mute"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $state.config.othersAudio) {
                        Text(L10n.s("audio.off")).tag(OthersAudio.off.rawValue)
                        Text(L10n.s("audio.quiet")).tag(OthersAudio.quiet.rawValue)
                        Text(L10n.s("audio.mute")).tag(OthersAudio.mute.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.s("menu.style"))
                            .font(.system(size: 12, weight: .medium))
                        if let app = state.frontApp {
                            Text(app.name)
                                .font(.system(size: 10.5))
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Picker("", selection: menuStyle) {
                        ForEach(StyleOption.all) { option in
                            Label(option.title, systemImage: option.icon).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .disabled(!state.config.autoCorrect)
                .opacity(state.config.autoCorrect ? 1 : 0.45)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().padding(.horizontal, 14)

            recent
                .padding(.horizontal, 6)
                .padding(.vertical, 8)

            Divider()

            NoteDestinationPicker()
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 2)

            notesLink
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            Divider()

            footer
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(width: 340)
        .tint(Theme.violet)
        .overlay(alignment: .bottom) { settingToast }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: state.settingToastVisible)
    }

    @ViewBuilder
    private var settingToast: some View {
        if state.settingToastVisible {
            SettingsSavedToast()
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var menuStyle: Binding<String> {
        Binding(
            get: {
                if let app = state.frontApp {
                    return state.effectiveStyle(for: app)
                }
                return state.config.style
            },
            set: { style in
                if let app = state.frontApp {
                    state.setAppStyle(bundleID: app.bundleID, name: app.name, style: style)
                } else {
                    state.config.style = style
                }
            }
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            FlowMark(size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.appName).font(.system(size: 14, weight: .semibold))
                Text(state.modelDisplayName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            StatusPill(state: state.engineState, text: shortStatus)
        }
    }

    private var shortStatus: String {
        switch state.engineState {
        case .ready: return L10n.s("status.ready")
        case .loading: return L10n.s("status.loading")
        case .error: return L10n.s("status.error")
        }
    }

    private var recordButton: some View {
        let listening = state.phase == .listening
        return Button {
            state.toggleRecording()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(.white.opacity(0.22)).frame(width: 34, height: 34)
                    Image(systemName: listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(listening ? L10n.s("menu.stop") : L10n.s("menu.speakFree"))
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(listening ? Fmt.clock(state.elapsed) : L10n.s("menu.orHold", state.config.resolvedHotkey.symbol))
                        .font(.system(size: 11).monospacedDigit())
                        .opacity(0.8)
                }
                Spacer()
                if listening {
                    MirroredWaveform(levels: state.levels, bars: 11)
                        .frame(width: 56, height: 22)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(listening
                          ? AnyShapeStyle(Color.red.gradient)
                          : AnyShapeStyle(Theme.gradient))
            )
            .shadow(color: (listening ? Color.red : Theme.violet).opacity(0.3), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(!state.engineReady && !listening)
        .opacity(state.engineReady || listening ? 1 : 0.6)
    }

    private var updateChecking: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L10n.s("update.settings.checking"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private var updateHint: some View {
        Button {
            state.installAvailableUpdate()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.app.fill").foregroundStyle(Theme.violet)
                Text(
                    state.isDownloadingUpdate
                        ? L10n.s("update.settings.downloading")
                        : L10n.s("update.menu", state.availableRelease?.version ?? "")
                )
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if state.isDownloadingUpdate {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.violet.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(state.isDownloadingUpdate)
    }

    private var permissionHint: some View {
        Button {
            state.openMain(.home)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                Text(L10n.s("menu.permissions"))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var recent: some View {
        let items = Array(state.history.prefix(4))
        if items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
                Text(L10n.s("menu.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.s("menu.recent"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                ForEach(items) { entry in
                    HistoryRow(entry: entry, mode: .compact)
                }
            }
        }
    }

    private var notesLink: some View {
        Button {
            state.openNotes()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.violet)
                Text(L10n.s("menu.notes"))
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                if AppleNotesFolder.decode(state.config.noteDestination) == nil, !state.notes.isEmpty {
                    Text("\(state.notes.count)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 6
            ) {
                ForEach(MainSection.allCases) { section in
                    MenuDestinationButton(title: section.title, icon: section.icon) {
                        state.openMain(section)
                    }
                }
                MenuDestinationButton(title: L10n.s("menu.quitShort"), icon: "power", tint: .secondary) {
                    NSApp.terminate(nil)
                }
            }
            Text(L10n.appVersion)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct MenuDestinationButton: View {
    let title: String
    let icon: String
    var tint: Color = Theme.violet
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.1 : 0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
