import AppKit
import ApplicationServices
import Foundation

@MainActor
final class PlayerStore: ObservableObject {
    @Published private(set) var connectionState: MAConnectionState = .disconnected(reason: nil)
    @Published private(set) var connectionText = "Disconnected"
    @Published private(set) var statusSymbolName = "bolt.slash"
    @Published private(set) var targetText = "No active target"
    @Published private(set) var nowPlayingText = "Nothing playing"
    @Published private(set) var nowPlayingArtworkURL: URL?
    @Published private(set) var playPauseTitle = "Play/Pause"
    @Published private(set) var playPauseIconName = "playpause.fill"
    @Published private(set) var isTargetPlaying = false
    @Published private(set) var canControl = false
    @Published private(set) var canSkipTrack = false
    @Published private(set) var errorText: String?
    @Published private(set) var mediaKeyCaptureWarning: String?
    @Published private(set) var isConnected = false
    @Published private(set) var isSwitchingPlayer = false
    @Published var sliderVolume: Double = 0

    @Published var apiHostInput: String
    @Published var apiPortInput: String
    @Published var apiTokenInput: String
    @Published private(set) var selectableTargets: [MAPlayer] = []
    @Published private(set) var settingsStatusText: String?
    @Published private(set) var isDiscoveringHost = false
    @Published private(set) var settingsCollapseToken = 0

    private var playersByID: [String: MAPlayer] = [:]
    private var currentTargetID: String?
    private var lastSuccessfulTargetID: String?

    private var volumeSendTask: Task<Void, Never>?
    private var mediaKeyMonitor: MediaKeyMonitor?

    private var discovery = BonjourDiscovery()
    private var client: MAWebSocketClient?
    private var activeConfiguration: APIConnectionConfiguration?
    private var collapseSettingsOnNextConnect = false

    var canSaveSettings: Bool {
        configurationFromInputs != nil
    }

    var canChoosePlayer: Bool {
        isConnected && selectableTargets.count > 1 && !isSwitchingPlayer
    }

    private var mediaKeyPermissionWarningText: String {
        "Enable Accessibility/Input Monitoring for this app to fully capture Play/Pause and prevent Apple Music from opening."
    }

    init() {
        apiHostInput = AppConfig.loadHost()
        apiPortInput = String(AppConfig.loadPort())
        apiTokenInput = AppConfig.loadToken()

        let monitor = MediaKeyMonitor { [weak self] in
            Task { @MainActor [weak self] in
                self?.togglePlayPause()
            }
        }
        mediaKeyMonitor = monitor

        let captureMode = monitor.start()
        if captureMode == .passive {
            mediaKeyCaptureWarning = mediaKeyPermissionWarningText
        }

        connectUsingCurrentInputs(forceReconnect: false)

        if apiHostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            discoverHost()
        }
    }

    func discoverHost() {
        guard !isDiscoveringHost else {
            return
        }

        isDiscoveringHost = true
        settingsStatusText = "Discovering Home Assistant..."

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let result = await self.discovery.discoverMusicAssistantEndpoint()
            self.isDiscoveringHost = false

            if let result {
                self.apiHostInput = result.host

                let enteredPort = Int(self.apiPortInput.trimmingCharacters(in: .whitespacesAndNewlines))
                if enteredPort == nil || enteredPort == AppConfig.defaultPort {
                    self.apiPortInput = String(result.port)
                }

                self.settingsStatusText = "Discovered \(result.host):\(self.apiPortInput)"

                if !self.apiTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.connectUsingCurrentInputs(forceReconnect: self.client != nil)
                }
            } else {
                self.settingsStatusText = "No server discovered. Enter host manually."
            }
        }
    }

    func saveSettingsAndReconnect() {
        guard let config = configurationFromInputs else {
            settingsStatusText = "Host, port, and token are required"
            return
        }

        AppConfig.saveHost(config.host)
        AppConfig.savePort(config.port)

        guard AppConfig.saveToken(config.token) else {
            settingsStatusText = "Failed to save token to Keychain"
            return
        }

        settingsStatusText = "Settings saved"
        errorText = nil
        collapseSettingsOnNextConnect = true

        connect(with: config, forceReconnect: true)
    }

    func reconnect() {
        connectUsingCurrentInputs(forceReconnect: true)
    }

    func requestMediaKeyPermissions() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestListenEventAccess()

        openMediaKeySettings()
    }

    func openMediaKeySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else {
                continue
            }
            if NSWorkspace.shared.open(url) {
                break
            }
        }
    }

    func retryMediaKeyCapture() {
        guard let mediaKeyMonitor else {
            return
        }

        mediaKeyMonitor.stop()
        let captureMode = mediaKeyMonitor.start()
        mediaKeyCaptureWarning = captureMode == .exclusive ? nil : mediaKeyPermissionWarningText
    }

    func selectTarget(id: String) {
        guard selectableTargets.contains(where: { $0.playerID == id }) else {
            return
        }

        guard currentTargetID != id else {
            return
        }

        Task { [weak self] in
            await self?.transferPlayback(to: id)
        }
    }

    func isCurrentTarget(id: String) -> Bool {
        currentTargetID == id
    }

    func togglePlayPause() {
        guard let target = resolveCurrentTarget() else {
            errorText = "No active target available"
            return
        }

        guard let client else {
            errorText = "Configure API host and token first"
            return
        }

        Task {
            await sendTransportCommand(
                queueCommand: "player_queues/play_pause",
                playerCommands: playbackFallbackCommands(for: target),
                playerID: target.playerID,
                client: client
            )
        }
    }

    func previousTrack() {
        sendTransportCommand(
            queueCommand: "player_queues/previous",
            playerCommands: ["players/cmd/previous"]
        )
    }

    func nextTrack() {
        sendTransportCommand(
            queueCommand: "player_queues/next",
            playerCommands: ["players/cmd/next"]
        )
    }

    private func sendTransportCommand(
        queueCommand: String?,
        playerCommands: [String],
        playerID: String,
        client: MAWebSocketClient
    ) async {
        if let queueCommand {
            do {
                _ = try await client.send(
                    command: queueCommand,
                    args: ["queue_id": .string(playerID)]
                )
                lastSuccessfulTargetID = playerID
                errorText = nil
                return
            } catch {
                if playerCommands.isEmpty {
                    errorText = error.localizedDescription
                    return
                }
            }
        }

        await sendPlayerCommands(commands: playerCommands, playerID: playerID, client: client)
    }

    private func sendPlayerCommands(commands: [String], playerID: String, client: MAWebSocketClient) async {
        for command in commands {
            do {
                _ = try await client.send(
                    command: command,
                    args: ["player_id": .string(playerID)]
                )
                lastSuccessfulTargetID = playerID
                errorText = nil
                return
            } catch {
                // If this was the last command to try, report the error.
                if command == commands.last {
                    errorText = error.localizedDescription
                }
                // Otherwise try the next fallback command.
            }
        }
    }

    private func sendTransportCommand(queueCommand: String?, playerCommands: [String]) {
        guard let target = resolveCurrentTarget() else {
            errorText = "No active target available"
            return
        }

        guard let client else {
            errorText = "Configure API host and token first"
            return
        }

        Task {
            await sendTransportCommand(
                queueCommand: queueCommand,
                playerCommands: playerCommands,
                playerID: target.playerID,
                client: client
            )
        }
    }

    func setVolume(_ newValue: Double) {
        sliderVolume = min(max(newValue.rounded(), 0), 100)

        volumeSendTask?.cancel()
        let level = Int(sliderVolume)
        volumeSendTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            await self?.sendVolume(level)
        }
    }

    private func sendVolume(_ level: Int) async {
        guard let target = resolveCurrentTarget() else {
            errorText = "No active target available"
            return
        }

        guard let client else {
            errorText = "Configure API host and token first"
            return
        }

        let command = target.isGroupLike ? "players/cmd/group_volume" : "players/cmd/volume_set"

        do {
            _ = try await client.send(
                command: command,
                args: [
                    "player_id": .string(target.playerID),
                    "volume_level": .integer(level)
                ]
            )
            lastSuccessfulTargetID = target.playerID
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func connectUsingCurrentInputs(forceReconnect: Bool) {
        guard let config = configurationFromInputs else {
            applySetupRequiredState()
            return
        }

        connect(with: config, forceReconnect: forceReconnect)
    }

    private func connect(with configuration: APIConnectionConfiguration, forceReconnect: Bool) {
        guard let url = configuration.webSocketURL else {
            applySetupRequiredState(message: "Invalid host or port")
            return
        }

        if activeConfiguration != configuration || client == nil {
            let oldClient = client
            client = makeClient(url: url, token: configuration.token)
            activeConfiguration = configuration

            if let oldClient {
                Task {
                    await oldClient.disconnect()
                }
            }
        }

        guard let client else {
            return
        }

        Task {
            if forceReconnect {
                await client.reconnectNow()
            } else {
                await client.connect()
            }
        }
    }

    private func makeClient(url: URL, token: String) -> MAWebSocketClient {
        MAWebSocketClient(
            url: url,
            token: token,
            onMessage: { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.handleInboundMessage(message)
                }
            },
            onStateChange: { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleConnectionState(state)
                }
            }
        )
    }

    private var configurationFromInputs: APIConnectionConfiguration? {
        let host = apiHostInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = apiTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let portText = apiPortInput.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !host.isEmpty,
              !token.isEmpty,
              let port = Int(portText),
              (1...65535).contains(port)
        else {
            return nil
        }

        return APIConnectionConfiguration(host: host, port: port, token: token)
    }

    private func applySetupRequiredState(message: String = "Configure host, port, and token") {
        connectionState = .disconnected(reason: nil)
        connectionText = "Setup required"
        statusSymbolName = "slider.horizontal.3"
        isConnected = false
        canControl = false
        errorText = nil
        settingsStatusText = message
        updateTargetAndUI()
    }

    private func refreshPlayers() async {
        guard let client else {
            return
        }

        do {
            guard let result = try await client.send(command: "players/all", args: [:]) else {
                throw MAWebSocketError.internalFailure("players/all returned no result")
            }

            let snapshot = try JSONValueDecoder.decode([MAPlayer].self, from: result)
            applySnapshot(snapshot)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func applySnapshot(_ players: [MAPlayer]) {
        playersByID = Dictionary(uniqueKeysWithValues: players.map { ($0.playerID, $0) })
        updateTargetAndUI()
    }

    private func updatePlayer(_ player: MAPlayer) {
        playersByID[player.playerID] = player
        updateTargetAndUI()
    }

    private func removePlayer(withID playerID: String) {
        playersByID.removeValue(forKey: playerID)
        if currentTargetID == playerID {
            currentTargetID = nil
        }
        updateTargetAndUI()
    }

    private func updateTargetAndUI() {
        let resolution = Self.resolveSelectableTargets(
            players: Array(playersByID.values),
            lastSuccessfulTargetID: lastSuccessfulTargetID
        )
        let target = resolution.target

        selectableTargets = resolution.selectableTargets
        currentTargetID = target?.playerID

        applyTargetPresentation(target)

        if let volume = target?.effectiveVolume {
            sliderVolume = Double(volume)
        }
    }

    private func resolveCurrentTarget() -> MAPlayer? {
        if let currentTargetID, let existing = playersByID[currentTargetID], existing.isAvailable {
            return existing
        }

        return Self.resolveSelectableTargets(
            players: Array(playersByID.values),
            lastSuccessfulTargetID: lastSuccessfulTargetID
        ).target
    }

    private func applyTargetPresentation(_ target: MAPlayer?) {
        canControl = target != nil && isConnected
        canSkipTrack = (target?.supportsNextPrevious ?? false) && isConnected
        targetText = target?.resolvedName ?? "No active target"
        nowPlayingText = nowPlayingLine(for: target)
        nowPlayingArtworkURL = resolveArtworkURL(for: target)

        if let target {
            isTargetPlaying = target.isPlaying
            if target.isPlaying {
                playPauseTitle = "Pause"
                playPauseIconName = "pause.fill"
            } else {
                playPauseTitle = "Play"
                playPauseIconName = "play.fill"
            }
        } else {
            isTargetPlaying = false
            playPauseTitle = "Play/Pause"
            playPauseIconName = "playpause.fill"
        }
    }

    private func nowPlayingLine(for target: MAPlayer?) -> String {
        guard let target else {
            return "Nothing playing"
        }
        if let line = target.nowPlayingLine {
            return line
        }
        return target.isPlaying ? "Playing" : "Nothing playing"
    }

    private func resolveArtworkURL(for target: MAPlayer?) -> URL? {
        guard let rawArtworkURL = target?.currentMedia?.artworkURLString else {
            return nil
        }

        let trimmed = rawArtworkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }

        guard let baseURL = activeConfiguration?.httpBaseURL else {
            return nil
        }

        if let relative = URL(string: trimmed, relativeTo: baseURL) {
            return relative.absoluteURL
        }

        if
            let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let relative = URL(string: encoded, relativeTo: baseURL)
        {
            return relative.absoluteURL
        }

        return nil
    }

    private func playbackCommand(for target: MAPlayer) -> String {
        if target.isPlaying {
            return target.supportsPause ? "players/cmd/pause" : "players/cmd/play_pause"
        }
        return "players/cmd/play"
    }

    private func playbackFallbackCommands(for target: MAPlayer) -> [String] {
        let preferredCommand = playbackCommand(for: target)
        let fallbackCommand = "players/cmd/play_pause"

        return preferredCommand == fallbackCommand
            ? [preferredCommand]
            : [preferredCommand, fallbackCommand]
    }

    private func transferPlayback(to targetPlayerID: String) async {
        guard let client else {
            return
        }

        isSwitchingPlayer = true
        let switchStartedAt = Date()
        defer {
            let elapsed = Date().timeIntervalSince(switchStartedAt)
            let remaining = max(0, 0.35 - elapsed)

            Task { @MainActor [weak self] in
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                self?.isSwitchingPlayer = false
            }
        }

        guard let sourceTarget = resolveCurrentTarget() else {
            lastSuccessfulTargetID = targetPlayerID
            updateTargetAndUI()
            errorText = nil
            return
        }

        do {
            guard
                let sourceQueueID = try await activeQueueID(for: sourceTarget.playerID, client: client),
                sourceQueueID != targetPlayerID
            else {
                lastSuccessfulTargetID = targetPlayerID
                updateTargetAndUI()
                errorText = nil
                return
            }

            _ = try await client.send(
                command: "player_queues/transfer",
                args: [
                    "source_queue_id": .string(sourceQueueID),
                    "target_queue_id": .string(targetPlayerID)
                ]
            )
            lastSuccessfulTargetID = targetPlayerID
            updateTargetAndUI()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func activeQueueID(for playerID: String, client: MAWebSocketClient) async throws -> String? {
        guard
            let result = try await client.send(
                command: "player_queues/get_active_queue",
                args: ["player_id": .string(playerID)]
            )
        else {
            return nil
        }

        return result.objectValue?["queue_id"]?.stringValue
    }

    nonisolated static func resolveSelectableTargets(
        players: [MAPlayer],
        lastSuccessfulTargetID: String?
    ) -> TargetSelectionResolution {
        let selectableTargets = players
            .filter(\.isSelectableTarget)
            .sorted {
                let lhs = ($0.resolvedName.localizedCaseInsensitiveCompare($1.resolvedName), $0.playerID)
                return lhs.0 == .orderedAscending || (lhs.0 == .orderedSame && lhs.1 < $1.playerID)
            }

        let playingTargets = selectableTargets.filter(\.isPlaying)
        let preferredTarget = playingTargets.first(where: \.isGroupLike)
            ?? playingTargets.first(where: { !$0.isSyncedMember })
            ?? selectableTargets.first(where: { $0.playerID == lastSuccessfulTargetID })

        return TargetSelectionResolution(
            target: preferredTarget,
            selectableTargets: selectableTargets
        )
    }

    private func handleConnectionState(_ state: MAConnectionState) {
        connectionState = state

        switch state {
        case .connecting:
            connectionText = "Connecting"
            statusSymbolName = "arrow.triangle.2.circlepath"
            isConnected = false
        case .authenticating:
            connectionText = "Authenticating"
            statusSymbolName = "lock.shield"
            isConnected = false
        case .connected:
            connectionText = "Connected"
            statusSymbolName = "dot.radiowaves.left.and.right"
            isConnected = true
            settingsStatusText = nil
            if collapseSettingsOnNextConnect {
                collapseSettingsOnNextConnect = false
                settingsCollapseToken &+= 1
            }
            Task {
                await refreshPlayers()
            }
        case let .disconnected(reason):
            connectionText = "Disconnected"
            statusSymbolName = "bolt.slash"
            isConnected = false
            if let reason, !reason.isEmpty {
                errorText = reason
            }
        }

        updateTargetAndUI()
    }

    private func handleInboundMessage(_ message: MAInboundMessage) {
        switch message {
        case .hello:
            return
        case let .event(name, data):
            handleEvent(name: name, data: data)
        case let .error(_, _, details):
            errorText = details
        case .result:
            return
        }
    }

    private func handleEvent(name: String, data: JSONValue?) {
        switch name {
        case "player_added", "player_updated":
            guard let data else {
                return
            }
            do {
                let player = try JSONValueDecoder.decode(MAPlayer.self, from: data)
                updatePlayer(player)
            } catch {
                errorText = "Failed to decode \(name): \(error.localizedDescription)"
            }
        case "player_removed":
            guard let playerID = extractPlayerID(from: data) else {
                return
            }
            removePlayer(withID: playerID)
        default:
            return
        }
    }

    private func extractPlayerID(from value: JSONValue?) -> String? {
        guard let value else {
            return nil
        }

        if let direct = value.stringValue {
            return direct
        }

        if let object = value.objectValue {
            return object["player_id"]?.stringValue
        }

        return nil
    }
}

struct TargetSelectionResolution {
    let target: MAPlayer?
    let selectableTargets: [MAPlayer]
}
