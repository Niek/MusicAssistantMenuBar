import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct MusicAssistantMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = PlayerStore()

    var body: some Scene {
        MenuBarExtra("Music Assistant", systemImage: store.statusSymbolName) {
            MenuPanelView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuPanelView: View {
    @ObservedObject var store: PlayerStore
    @State private var showSettings = false
    @State private var showPlayerSelector = false

    private var statusColor: Color {
        switch store.connectionState {
        case .connected:
            return Color(red: 0.14, green: 0.72, blue: 0.44)
        case .connecting, .authenticating:
            return Color(red: 0.92, green: 0.62, blue: 0.13)
        case .disconnected:
            return Color(red: 0.84, green: 0.33, blue: 0.33)
        }
    }

    private var transportBarColors: [Color] {
        if store.canControl && store.isTargetPlaying {
            return [
                Color(red: 0.16, green: 0.56, blue: 0.88),
                Color(red: 0.11, green: 0.42, blue: 0.77)
            ]
        }

        return [
            Color(red: 0.38, green: 0.42, blue: 0.49),
            Color(red: 0.30, green: 0.34, blue: 0.40)
        ]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.10, green: 0.14, blue: 0.19),
                            Color(red: 0.07, green: 0.09, blue: 0.13)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 14) {
                header
                if showSettings {
                    settingsCard
                }
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
            if !store.canSaveSettings {
                showSettings = true
            }
        }
        .onChange(of: store.settingsCollapseToken) { _ in
            withAnimation(.easeInOut(duration: 0.18)) {
                showSettings = false
            }
        }
        .onChange(of: store.canChoosePlayer) { canChoosePlayer in
            if !canChoosePlayer {
                showPlayerSelector = false
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.12))
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

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showSettings.toggle()
                }
            } label: {
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
            Text("Connection Settings")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 6) {
                Text("Host")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                TextField("homeassistant.local", text: $store.apiHostInput)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Port")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                TextField("8095", text: $store.apiPortInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Long-lived Token")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
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
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showPlayerSelector.toggle()
                    }
                } label: {
                    playerCardHeader(showChevron: true)
                }
                .buttonStyle(.plain)
            } else {
                playerCardHeader(showChevron: false)
            }

            if store.isSwitchingPlayer {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color(red: 0.22, green: 0.70, blue: 0.92))
                    Text("Switching...")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.74))
                }
            } else if showPlayerSelector {
                VStack(spacing: 6) {
                    ForEach(store.selectableTargets) { target in
                        playerOptionButton(
                            title: target.resolvedName,
                            isSelected: store.isCurrentTarget(id: target.playerID)
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
            Text("Player")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))
                .textCase(.uppercase)

            HStack(spacing: 10) {
                Text(store.targetText)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity((showChevron || store.isSwitchingPlayer) ? 1 : 0.72))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if showChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.74))
                        .rotationEffect(.degrees(showPlayerSelector ? 180 : 0))
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func playerOptionButton(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? Color(red: 0.22, green: 0.70, blue: 0.92) : .white.opacity(0.36))

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
                    .fill(isSelected ? Color.white.opacity(0.10) : Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.06), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
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
            .disabled(!store.canSkipTrack || store.isSwitchingPlayer)
            .opacity((store.canSkipTrack && !store.isSwitchingPlayer) ? 1 : 0.45)

            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 1, height: 26)

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
            .disabled(!store.canControl || store.isSwitchingPlayer)
            .opacity((store.canControl && !store.isSwitchingPlayer) ? 1 : 0.45)

            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 1, height: 26)

            Button {
                store.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 54, height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!store.canSkipTrack || store.isSwitchingPlayer)
            .opacity((store.canSkipTrack && !store.isSwitchingPlayer) ? 1 : 0.45)
        }
        .foregroundStyle(.white)
        .background(
            LinearGradient(
                colors: transportBarColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }

    private var nowPlayingCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Now Playing")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))
                .textCase(.uppercase)

            HStack(spacing: 10) {
                artworkThumbnail

                MarqueeText(
                    text: store.nowPlayingText,
                    textColor: .white.opacity(store.canControl ? 0.92 : 0.62),
                    fontSize: 18,
                    weight: .semibold
                )
                .frame(height: 24)
            }
        }
        .cardBackground()
    }

    @ViewBuilder
    private var artworkThumbnail: some View {
        if let artworkURL = store.nowPlayingArtworkURL {
            AsyncImage(url: artworkURL, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    artworkPlaceholder
                case .empty:
                    artworkPlaceholder.opacity(0.8)
                @unknown default:
                    artworkPlaceholder
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
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Volume")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.84))
                Spacer()
                Text("\(Int(store.sliderVolume))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }

            Slider(
                value: Binding(
                    get: { store.sliderVolume },
                    set: { store.setVolume($0) }
                ),
                in: 0...100,
                step: 1
            )
            .disabled(!store.canControl || store.isSwitchingPlayer)
            .tint(Color(red: 0.22, green: 0.70, blue: 0.92))
        }
        .cardBackground()
    }

    @ViewBuilder
    private var warningView: some View {
        if let warning = store.mediaKeyCaptureWarning, !warning.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.94, green: 0.75, blue: 0.25))

                HStack(spacing: 8) {
                    Button("Allow Access") {
                        store.requestMediaKeyPermissions()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Open Settings") {
                        store.openMediaKeySettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Retry") {
                        store.retryMediaKeyCapture()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 0.47, green: 0.34, blue: 0.07).opacity(0.3))
            )
        }
    }

    @ViewBuilder
    private var errorView: some View {
        if let errorText = store.errorText, !errorText.isEmpty {
            Label(errorText, systemImage: "xmark.octagon.fill")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.98, green: 0.48, blue: 0.48))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(red: 0.46, green: 0.08, blue: 0.12).opacity(0.28))
                )
        }
    }

    private var footerActions: some View {
        HStack(spacing: 8) {
            Button("Reconnect") {
                store.reconnect()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .tint(Color.white.opacity(0.15))

            Spacer(minLength: 0)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .tint(Color(red: 0.63, green: 0.20, blue: 0.20))
        }
    }
}

// MARK: - Card Background Modifier

private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
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

extension View {
    fileprivate func cardBackground() -> some View {
        modifier(CardBackground())
    }
}

// MARK: - Marquee Text

private struct MarqueeText: View {
    let text: String
    let textColor: Color
    let fontSize: CGFloat
    let weight: Font.Weight

    private let gap: CGFloat = 30
    private let speed: CGFloat = 36

    @State private var cachedTextWidth: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let availableWidth = max(geo.size.width, 1)
            let contentWidth = cachedTextWidth ?? measureTextWidth()
            let shouldScroll = contentWidth > availableWidth

            if shouldScroll {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    let distance = contentWidth + gap
                    let cycleDuration = TimeInterval(distance / speed)
                    let elapsed = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycleDuration)
                    let offset = -CGFloat(elapsed) * speed

                    HStack(spacing: gap) {
                        label
                        label
                    }
                    .offset(x: offset)
                }
            } else {
                label
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .clipped()
        .onChange(of: text) { _ in
            cachedTextWidth = measureTextWidth()
        }
        .onAppear {
            cachedTextWidth = measureTextWidth()
        }
    }

    private var label: some View {
        Text(text)
            .font(.system(size: fontSize, weight: weight, design: .rounded))
            .foregroundStyle(textColor)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func measureTextWidth() -> CGFloat {
        let nsWeight: NSFont.Weight = switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
        let font = NSFont.systemFont(ofSize: fontSize, weight: nsWeight)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}
