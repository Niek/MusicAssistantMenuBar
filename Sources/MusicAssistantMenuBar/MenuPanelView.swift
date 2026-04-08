import AppKit
import SwiftUI

struct MenuPanelView: View {
    @ObservedObject var store: PlayerStore
    @State private var showSettings = false
    @State private var showPlayerSelector = false
    @State private var showFavoriteSelector = false
    @State private var showIndividualVolumeTargets = false

    private let accent = Color(red: 0.22, green: 0.70, blue: 0.92)
    private let animation = Animation.easeInOut(duration: 0.18)

    private var statusColor: Color {
        switch store.connectionState {
        case .connected: Color(red: 0.14, green: 0.72, blue: 0.44)
        case .connecting, .authenticating: Color(red: 0.92, green: 0.62, blue: 0.13)
        case .disconnected: Color(red: 0.84, green: 0.33, blue: 0.33)
        }
    }

    private var isControlDisabled: Bool { !store.canControl || store.isSwitchingPlayer }
    private var canSkip: Bool { store.canSkipTrack && !store.isSwitchingPlayer }

    private var transportBarColors: [Color] {
        store.canControl && store.isTargetPlaying
            ? [Color(red: 0.16, green: 0.56, blue: 0.88), Color(red: 0.11, green: 0.42, blue: 0.77)]
            : [Color(red: 0.38, green: 0.42, blue: 0.49), Color(red: 0.30, green: 0.34, blue: 0.40)]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.10, green: 0.14, blue: 0.19), Color(red: 0.07, green: 0.09, blue: 0.13)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .overlay(
                    RadialGradient(
                        colors: [accent.opacity(0.22), .clear],
                        center: .topLeading,
                        startRadius: 10,
                        endRadius: 220
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                )
                .shadow(color: .black.opacity(0.28), radius: 26, y: 16)

            VStack(alignment: .leading, spacing: 14) {
                header
                if showSettings { settingsCard }
                playerCard
                nowPlayingCard
                transportControls
                volumeCard
                warningView
                errorView
                footerActions
            }
            .padding(16)
        }
        .frame(width: 348)
        .padding(10)
        .onAppear {
            if !store.canSaveSettings { showSettings = true }
        }
        .onChange(of: store.settingsCollapseToken) { _ in animate { showSettings = false } }
        .onChange(of: store.canChoosePlayer) { if !$0 { showPlayerSelector = false } }
        .onChange(of: store.hasFavoriteMediaItems) { if !$0 { animate { showFavoriteSelector = false } } }
        .onChange(of: store.canControl) { if !$0 { animate { showFavoriteSelector = false } } }
        .onChange(of: store.hasIndividualVolumeTargets) { if !$0 { animate { showIndividualVolumeTargets = false } } }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.95), accent.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
                    .frame(width: 34, height: 34)
                Image(systemName: "music.note.house.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Music Assistant")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Menu Controller")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
            }

            Spacer()

            Button { animate { showSettings.toggle() } } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)

            Text(store.connectionText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(statusColor.opacity(0.16))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(statusColor.opacity(0.35), lineWidth: 1)
                        )
                )
        }
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Connection Settings")

            labeledField("Host") {
                TextField("homeassistant.local", text: $store.apiHostInput)
                    .textFieldStyle(.roundedBorder)
            }

            labeledField("Port") {
                TextField("8095", text: $store.apiPortInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
            }

            labeledField("Long-lived Token") {
                SecureField("Paste token", text: $store.apiTokenInput)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                Button(store.isDiscoveringHost ? "Discovering..." : "Auto-discover") {
                    store.discoverHost()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.isDiscoveringHost)

                Button("Save & Connect") {
                    store.saveSettingsAndReconnect()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!store.canSaveSettings)
            }

            if let status = store.settingsStatusText, !status.isEmpty {
                Text(status)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.74))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardBackground()
    }

    private var playerCard: some View {
        VStack(alignment: .leading, spacing: showPlayerSelector ? 12 : 10) {
            if store.canChoosePlayer {
                Button { animate { showPlayerSelector.toggle() } } label: { playerCardHeader(showChevron: true) }
                    .buttonStyle(.plain)
            } else {
                playerCardHeader(showChevron: false)
            }

            if store.isSwitchingPlayer {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(accent)
                    Text("Switching...")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.74))
                }
            } else if showPlayerSelector {
                VStack(spacing: 6) {
                    ForEach(store.selectableTargets) { target in
                        let selected = store.isCurrentTarget(id: target.playerID)
                        optionButton(
                            icon: selected ? "checkmark.circle.fill" : "circle",
                            iconColor: selected ? accent : .white.opacity(0.36),
                            title: target.resolvedName,
                            isHighlighted: selected
                        ) {
                            store.selectTarget(id: target.playerID)
                            showPlayerSelector = false
                        }
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .cardBackground()
    }

    private func playerCardHeader(showChevron: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Player")

            HStack(spacing: 10) {
                Text(store.targetText)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity((showChevron || store.isSwitchingPlayer) ? 1 : 0.72))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if showChevron { chevron(showPlayerSelector) }
            }
        }
        .contentShape(Rectangle())
    }

    private var transportControls: some View {
        HStack(spacing: 0) {
            Button {
                store.previousTrack()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 54, height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSkip)
            .opacity(canSkip ? 1 : 0.45)

            dividerStrip

            Button {
                store.togglePlayPause()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: store.playPauseIconName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(store.playPauseTitle)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity, minHeight: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isControlDisabled)
            .opacity(isControlDisabled ? 0.45 : 1)

            dividerStrip

            Button {
                store.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 54, height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSkip)
            .opacity(canSkip ? 1 : 0.45)
        }
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: transportBarColors, startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .shadow(
            color: (store.canControl && store.isTargetPlaying ? accent : .black).opacity(0.18),
            radius: 12,
            y: 8
        )
    }

    private var nowPlayingCard: some View {
        VStack(alignment: .leading, spacing: showFavoriteSelector ? 12 : 7) {
            Group {
                if store.hasFavoriteMediaItems {
                    Button { animate { showFavoriteSelector.toggle() } } label: { nowPlayingCardHeader(showChevron: true) }
                        .buttonStyle(.plain)
                        .disabled(isControlDisabled)
                        .opacity(isControlDisabled ? 0.72 : 1)
                } else {
                    nowPlayingCardHeader(showChevron: false)
                }
            }

            if showFavoriteSelector {
                VStack(alignment: .leading, spacing: 10) {
                    if !store.favoritePlaylists.isEmpty {
                        favoriteMediaSection(title: "Playlists", items: store.favoritePlaylists)
                    }
                    if !store.favoriteAlbums.isEmpty {
                        favoriteMediaSection(title: "Albums", items: store.favoriteAlbums)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .cardBackground()
    }

    private func nowPlayingCardHeader(showChevron: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionLabel("Now Playing")

            HStack(spacing: 10) {
                artworkThumbnail

                MarqueeText(
                    text: store.nowPlayingText,
                    textColor: .white.opacity(store.canControl ? 0.92 : 0.62),
                    fontSize: 18,
                    weight: .semibold
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 24)

                if showChevron { chevron(showFavoriteSelector) }
            }
        }
        .contentShape(Rectangle())
    }

    private func favoriteMediaSection(title: String, items: [MAFavoriteMediaItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.56))
                .textCase(.uppercase)

            ForEach(items) { item in
                optionButton(icon: item.kind.iconName, iconColor: accent, title: item.title) {
                    store.playFavoriteItem(item)
                    showFavoriteSelector = false
                }
                .disabled(isControlDisabled)
                .opacity(isControlDisabled ? 0.45 : 1)
            }
        }
    }

    @ViewBuilder
    private var artworkThumbnail: some View {
        if let artworkURL = store.nowPlayingArtworkURL {
            AsyncImage(url: artworkURL, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
                switch phase {
                case let .success(image): image.resizable().scaledToFill()
                case .failure: artworkPlaceholder
                case .empty: artworkPlaceholder.opacity(0.8)
                @unknown default: artworkPlaceholder
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
        } else {
            artworkPlaceholder
                .frame(width: 34, height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
        }
    }

    private var artworkPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.08))
            Image(systemName: "music.note")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.58))
        }
    }

    private var volumeCard: some View {
        VStack(alignment: .leading, spacing: showIndividualVolumeTargets ? 12 : 9) {
            Group {
                if store.hasIndividualVolumeTargets {
                    Button { animate { showIndividualVolumeTargets.toggle() } } label: { volumeCardHeader(showChevron: true) }
                        .buttonStyle(.plain)
                } else {
                    volumeCardHeader(showChevron: false)
                }
            }

            Slider(value: Binding(get: { store.sliderVolume }, set: { store.setVolume($0) }), in: 0...100, step: 1)
                .disabled(isControlDisabled)
                .tint(accent)

            if showIndividualVolumeTargets {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Targets")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.56))
                        .textCase(.uppercase)

                    ForEach(store.individualVolumeTargets) { target in
                        individualVolumeTargetRow(target)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .cardBackground()
    }

    private func volumeCardHeader(showChevron: Bool) -> some View {
        HStack(spacing: 8) {
            Text("Volume")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.84))

            Spacer(minLength: 0)

            Text("\(Int(store.sliderVolume))%")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)

            if showChevron { chevron(showIndividualVolumeTargets) }
        }
        .contentShape(Rectangle())
    }

    private func individualVolumeTargetRow(_ target: IndividualVolumeTarget) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(target.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(target.volumeText)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(target.isAdjustable ? 0.84 : 0.48))
            }

            Slider(
                value: Binding(
                    get: { target.volume },
                    set: { store.setIndividualVolume($0, for: target.playerID) }
                ),
                in: 0...100,
                step: 1
            )
            .disabled(isControlDisabled || !target.isAdjustable)
            .tint(accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        .opacity(target.isAdjustable ? 1 : 0.7)
    }

    @ViewBuilder
    private var warningView: some View {
        if let warning = store.mediaKeyCaptureWarning, !warning.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                statusMessageCard(
                    text: warning,
                    systemImage: "exclamationmark.triangle.fill",
                    foregroundColor: Color(red: 0.94, green: 0.75, blue: 0.25),
                    backgroundColor: Color(red: 0.47, green: 0.34, blue: 0.07)
                )

                HStack(spacing: 8) {
                    Button("Allow Access") { store.requestMediaKeyPermissions() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                    Button("Open Settings") { store.openMediaKeySettings() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                    Button("Retry") { store.retryMediaKeyCapture() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var errorView: some View {
        if let errorText = store.errorText, !errorText.isEmpty {
            statusMessageCard(
                text: errorText,
                systemImage: "xmark.octagon.fill",
                foregroundColor: Color(red: 0.98, green: 0.48, blue: 0.48),
                backgroundColor: Color(red: 0.46, green: 0.08, blue: 0.12)
            )
        }
    }

    private func statusMessageCard(
        text: String,
        systemImage: String,
        foregroundColor: Color,
        backgroundColor: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .padding(.top, 1)

            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(foregroundColor)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundColor.opacity(0.28))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(backgroundColor.opacity(0.52), lineWidth: 1)
                )
        )
    }

    private var footerActions: some View {
        HStack(spacing: 8) {
            Button("Reconnect") { store.reconnect() }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(Color.white.opacity(0.15))

            Spacer(minLength: 0)

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(Color(red: 0.63, green: 0.20, blue: 0.20))
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.68)).textCase(.uppercase)
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            content()
        }
    }

    private func optionButton(
        icon: String,
        iconColor: Color,
        title: String,
        isHighlighted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconColor)

                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHighlighted ? Color.white.opacity(0.10) : Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isHighlighted ? Color.white.opacity(0.14) : Color.white.opacity(0.06), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    private var dividerStrip: some View { Rectangle().fill(Color.white.opacity(0.22)).frame(width: 1, height: 26) }

    private func chevron(_ isExpanded: Bool) -> some View {
        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(0.74)).rotationEffect(.degrees(isExpanded ? 180 : 0))
    }

    private func animate(_ action: () -> Void) { withAnimation(animation, action) }
}

private extension View {
    func cardBackground() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
    }
}
