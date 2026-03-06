import Foundation

@MainActor
final class PlayerStore: ObservableObject {
    @Published private(set) var connectionState: MAConnectionState = .disconnected(reason: nil)
    @Published private(set) var connectionText = "Disconnected"
    @Published private(set) var statusSymbolName = "bolt.slash"
    @Published private(set) var targetText = "No active target"
    @Published private(set) var nowPlayingText = "Nothing playing"
    @Published private(set) var playPauseTitle = "Play/Pause"
    @Published private(set) var playPauseIconName = "playpause.fill"
    @Published private(set) var canControl = false
    @Published private(set) var errorText: String?
    @Published private(set) var mediaKeyCaptureWarning: String?
    @Published private(set) var isConnected = false
    @Published var sliderVolume: Double = 0

    @Published var apiHostInput: String
    @Published var apiPortInput: String
    @Published var apiTokenInput: String
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
            mediaKeyCaptureWarning = "Enable Accessibility/Input Monitoring for this app to fully capture Play/Pause and prevent Apple Music from opening."
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

    func togglePlayPause() {
        guard let target = resolveCurrentTarget() else {
            errorText = "No active target available"
            return
        }

        guard let client else {
            errorText = "Configure API host and token first"
            return
        }

        let preferredCommand = playbackCommand(for: target)
        let fallbackCommand = "players/cmd/play_pause"
        let commands = preferredCommand == fallbackCommand
            ? [preferredCommand]
            : [preferredCommand, fallbackCommand]

        Task {
            await sendPlaybackCommand(commands: commands, playerID: target.playerID, client: client)
        }
    }

    private func sendPlaybackCommand(commands: [String], playerID: String, client: MAWebSocketClient) async {
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
        let target = resolvePreferredTarget()
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
        return resolvePreferredTarget()
    }

    private func applyTargetPresentation(_ target: MAPlayer?) {
        canControl = target != nil && isConnected
        targetText = target?.resolvedName ?? "No active target"
        nowPlayingText = nowPlayingLine(for: target)

        if let target {
            if target.isPlaying {
                playPauseTitle = "Pause"
                playPauseIconName = "pause.fill"
            } else {
                playPauseTitle = "Play"
                playPauseIconName = "play.fill"
            }
        } else {
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

    private func playbackCommand(for target: MAPlayer) -> String {
        if target.isPlaying {
            return target.supportsPause ? "players/cmd/pause" : "players/cmd/play_pause"
        }
        return "players/cmd/play"
    }

    private func resolvePreferredTarget() -> MAPlayer? {
        let available = playersByID.values.filter { $0.isAvailable }
        let playing = available.filter { $0.isPlaying }

        let groupTarget = sortPlayers(playing.filter { $0.isGroupLike }).first
        if let groupTarget {
            return groupTarget
        }

        let coordinatorTarget = sortPlayers(playing.filter { !$0.isSyncedMember }).first
        if let coordinatorTarget {
            return coordinatorTarget
        }

        if
            let lastSuccessfulTargetID,
            let fallback = available.first(where: { $0.playerID == lastSuccessfulTargetID })
        {
            return fallback
        }

        return nil
    }

    private func sortPlayers(_ players: [MAPlayer]) -> [MAPlayer] {
        players.sorted {
            let lhs = ($0.resolvedName.localizedCaseInsensitiveCompare($1.resolvedName), $0.playerID)
            return lhs.0 == .orderedAscending || (lhs.0 == .orderedSame && lhs.1 < $1.playerID)
        }
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
