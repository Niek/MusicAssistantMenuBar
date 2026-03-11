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
    @Published private(set) var isSwitchingPlayer = false
    @Published private(set) var favoritePlaylists: [MAFavoriteMediaItem] = []
    @Published private(set) var favoriteAlbums: [MAFavoriteMediaItem] = []
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

    private let favoriteMediaLimit = 10
    private let playNowQueueOption = "replace"

    var isConnected: Bool {
        connectionState == .connected
    }

    var canSaveSettings: Bool {
        configurationFromInputs != nil
    }

    var canChoosePlayer: Bool {
        isConnected && selectableTargets.count > 1 && !isSwitchingPlayer
    }

    var hasFavoriteMediaItems: Bool {
        Self.hasFavoriteMediaItems(
            playlists: favoritePlaylists,
            albums: favoriteAlbums
        )
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
        guard let (target, client) = requireTargetAndClient() else { return }

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
        guard let (target, client) = requireTargetAndClient() else { return }
        Task {
            await sendTransportCommand(
                queueCommand: "player_queues/previous",
                playerCommands: ["players/cmd/previous"],
                playerID: target.playerID,
                client: client
            )
        }
    }

    func nextTrack() {
        guard let (target, client) = requireTargetAndClient() else { return }
        Task {
            await sendTransportCommand(
                queueCommand: "player_queues/next",
                playerCommands: ["players/cmd/next"],
                playerID: target.playerID,
                client: client
            )
        }
    }

    func playFavoriteItem(_ item: MAFavoriteMediaItem) {
        guard let (target, client) = requireTargetAndClient() else { return }

        Task {
            await playFavoriteItem(item, on: target.playerID, client: client)
        }
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

    private func requireTargetAndClient() -> (MAPlayer, MAWebSocketClient)? {
        guard let target = resolveCurrentTarget() else {
            errorText = "No active target available"
            return nil
        }

        guard let client else {
            errorText = "Configure API host and token first"
            return nil
        }

        return (target, client)
    }

    func setVolume(_ newValue: Double) {
        let clamped = min(max(newValue.rounded(), 0), 100)
        guard sliderVolume != clamped else { return }
        sliderVolume = clamped

        volumeSendTask?.cancel()
        let level = Int(sliderVolume)
        volumeSendTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            await self?.sendVolume(level)
        }
    }

    private func sendVolume(_ level: Int) async {
        guard let (target, client) = requireTargetAndClient() else { return }

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
        canControl = false
        errorText = nil
        settingsStatusText = message
        clearFavoriteMedia()
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

    private func refreshFavoriteMedia() async {
        guard let client else {
            clearFavoriteMedia()
            return
        }

        let activeClient = client
        async let playlists = fetchFavoriteMediaItems(kind: .playlist, client: activeClient)
        async let albums = fetchFavoriteMediaItems(kind: .album, client: activeClient)

        let favoritePlaylists = await playlists
        let favoriteAlbums = await albums

        guard isConnected, self.client === activeClient else {
            return
        }

        self.favoritePlaylists = favoritePlaylists
        self.favoriteAlbums = favoriteAlbums
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
            let newVolume = Double(volume)
            if sliderVolume != newVolume {
                sliderVolume = newVolume
            }
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

    private func fetchFavoriteMediaItems(
        kind: MAFavoriteMediaKind,
        client: MAWebSocketClient
    ) async -> [MAFavoriteMediaItem] {
        do {
            guard let result = try await client.send(
                command: favoriteLibraryCommand(for: kind),
                args: [
                    "favorite": .bool(true),
                    "limit": .integer(favoriteMediaLimit)
                ]
            ) else {
                return []
            }

            return favoriteMediaItems(from: result, kind: kind)
        } catch {
            return []
        }
    }

    private func favoriteLibraryCommand(for kind: MAFavoriteMediaKind) -> String {
        switch kind {
        case .playlist:
            return "music/playlists/library_items"
        case .album:
            return "music/albums/library_items"
        }
    }

    private func favoriteMediaItems(from result: JSONValue, kind: MAFavoriteMediaKind) -> [MAFavoriteMediaItem] {
        let values = result.arrayValue ?? []
        return values.compactMap { MAFavoriteMediaItem(kind: kind, value: $0) }
    }

    private func playFavoriteItem(
        _ item: MAFavoriteMediaItem,
        on playerID: String,
        client: MAWebSocketClient
    ) async {
        do {
            let queueID = try await activeQueueID(for: playerID, client: client) ?? playerID
            let mediaArgument = item.uri.map(JSONValue.string) ?? item.rawPayload

            _ = try await client.send(
                command: "player_queues/play_media",
                args: [
                    "queue_id": .string(queueID),
                    "media": mediaArgument,
                    "option": .string(playNowQueueOption)
                ]
            )
            lastSuccessfulTargetID = playerID
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func clearFavoriteMedia() {
        favoritePlaylists = []
        favoriteAlbums = []
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

    nonisolated static func hasFavoriteMediaItems(
        playlists: [MAFavoriteMediaItem],
        albums: [MAFavoriteMediaItem]
    ) -> Bool {
        !playlists.isEmpty || !albums.isEmpty
    }

    private func handleConnectionState(_ state: MAConnectionState) {
        connectionState = state

        switch state {
        case .connecting:
            connectionText = "Connecting"
            statusSymbolName = "arrow.triangle.2.circlepath"
        case .authenticating:
            connectionText = "Authenticating"
            statusSymbolName = "lock.shield"
        case .connected:
            connectionText = "Connected"
            statusSymbolName = "dot.radiowaves.left.and.right"
            settingsStatusText = nil
            if collapseSettingsOnNextConnect {
                collapseSettingsOnNextConnect = false
                settingsCollapseToken &+= 1
            }
            Task {
                async let playersRefresh: Void = refreshPlayers()
                async let favoritesRefresh: Void = refreshFavoriteMedia()
                _ = await (playersRefresh, favoritesRefresh)
            }
        case let .disconnected(reason):
            connectionText = "Disconnected"
            statusSymbolName = "bolt.slash"
            clearFavoriteMedia()
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
