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

    private var statusColor: Color {
        if store.isConnected {
            return Color(red: 0.14, green: 0.72, blue: 0.44)
        }

        if store.connectionText == "Authenticating" || store.connectionText == "Connecting" {
            return Color(red: 0.92, green: 0.62, blue: 0.13)
        }

        return Color(red: 0.84, green: 0.33, blue: 0.33)
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
                targetCard
                nowPlayingCard
                playPauseButton
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
            if store.connectionText == "Setup required" {
                showSettings = true
            }
        }
        .onChange(of: store.settingsCollapseToken) { _ in
            withAnimation(.easeInOut(duration: 0.18)) {
                showSettings = false
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

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Target")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))
                .textCase(.uppercase)
            Text(store.targetText)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(store.canControl ? 1 : 0.72))
                .lineLimit(1)
        }
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

    private var playPauseButton: some View {
        Button {
            store.togglePlayPause()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: store.playPauseIconName)
                    .font(.system(size: 13, weight: .semibold))
                Text(store.playPauseTitle)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                Image(systemName: "keyboard")
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(0.82)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.16, green: 0.56, blue: 0.88),
                        Color(red: 0.11, green: 0.42, blue: 0.77)
                    ],
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
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .opacity(store.canControl ? 1 : 0.45)
        .disabled(!store.canControl)
    }

    private var nowPlayingCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Now Playing")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))
                .textCase(.uppercase)

            MarqueeText(
                text: store.nowPlayingText,
                textColor: .white.opacity(store.canControl ? 0.92 : 0.62),
                fontSize: 13,
                weight: .medium
            )
            .frame(height: 18)
        }
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
            .disabled(!store.canControl)
            .tint(Color(red: 0.22, green: 0.70, blue: 0.92))
        }
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

    @ViewBuilder
    private var warningView: some View {
        if let warning = store.mediaKeyCaptureWarning, !warning.isEmpty {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.94, green: 0.75, blue: 0.25))
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

private struct MarqueeText: View {
    let text: String
    let textColor: Color
    let fontSize: CGFloat
    let weight: Font.Weight

    private let gap: CGFloat = 30
    private let speed: CGFloat = 36

    var body: some View {
        GeometryReader { geo in
            let availableWidth = max(geo.size.width, 1)
            let contentWidth = measuredTextWidth
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
    }

    private var label: some View {
        Text(text)
            .font(.system(size: fontSize, weight: weight, design: .rounded))
            .foregroundStyle(textColor)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var measuredTextWidth: CGFloat {
        let nsWeight = nsFontWeight(from: weight)
        let font = NSFont.systemFont(ofSize: fontSize, weight: nsWeight)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func nsFontWeight(from weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight:
            return .ultraLight
        case .thin:
            return .thin
        case .light:
            return .light
        case .regular:
            return .regular
        case .medium:
            return .medium
        case .semibold:
            return .semibold
        case .bold:
            return .bold
        case .heavy:
            return .heavy
        case .black:
            return .black
        default:
            return .regular
        }
    }
}
