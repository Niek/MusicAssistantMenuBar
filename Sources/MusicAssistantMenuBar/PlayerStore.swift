import AppKit
import ApplicationServices
import Foundation

@MainActor
final class PlayerStore: ObservableObject {
    @Published private(set) var connectionState: MAConnectionState = .disconnected(reason: nil)
    @Published private(set) var isSetupRequired = false
    @Published private(set) var currentTarget: MAPlayer?
    @Published private(set) var nowPlayingArtworkURL: URL?
    @Published private(set) var errorText: String?
    @Published private(set) var mediaKeyCaptureWarning: String?
    @Published private(set) var isSwitchingPlayer = false
    @Published private(set) var favoritePlaylists: [MAFavoriteMediaItem] = []
    @Published private(set) var favoriteAlbums: [MAFavoriteMediaItem] = []
    @Published private(set) var individualVolumeTargets: [IndividualVolumeTarget] = []
    @Published var sliderVolume: Double = 0

    @Published var apiHostInput: String
    @Published var apiPortInput: String
    @Published var apiTokenInput: String
    @Published private(set) var selectableTargets: [MAPlayer] = []
    @Published private(set) var settingsStatusText: String?
    @Published private(set) var isDiscoveringHost = false
    @Published private(set) var settingsCollapseToken = 0

    private var playersByID: [String: MAPlayer] = [:]
    private var lastSuccessfulTargetID: String?

    private var volumeSendTask: Task<Void, Never>?
    private var individualVolumeSendTasks: [String: Task<Void, Never>] = [:]
    private var pendingIndividualVolumes: [String: Double] = [:]
    private var favoriteMediaRefreshTask: Task<Void, Never>?
    private var favoriteMediaRefreshPending = false
    private var mediaKeyMonitor: MediaKeyMonitor?

    private var discovery = BonjourDiscovery()
    private var client: MAWebSocketClient?
    private var activeConfiguration: APIConnectionConfiguration?
    private var collapseSettingsOnNextConnect = false

    private let favoriteMediaLimit = 10
    private let playNowQueueOption = "replace"
    private let mediaKeyPermissionWarningText =
        "Enable Accessibility/Input Monitoring for this app to fully capture Play/Pause and prevent Apple Music from opening."

    var isConnected: Bool { connectionState == .connected }

    var connectionText: String {
        switch (isSetupRequired, connectionState) {
        case (true, _): "Setup required"
        case (_, .connecting): "Connecting"
        case (_, .authenticating): "Authenticating"
        case (_, .connected): "Connected"
        case (_, .disconnected): "Disconnected"
        }
    }

    var statusSymbolName: String {
        switch (isSetupRequired, connectionState) {
        case (true, _): "slider.horizontal.3"
        case (_, .connecting): "arrow.triangle.2.circlepath"
        case (_, .authenticating): "lock.shield"
        case (_, .connected): "dot.radiowaves.left.and.right"
        case (_, .disconnected): "bolt.slash"
        }
    }

    var canSaveSettings: Bool { configurationFromInputs != nil }
    var canControl: Bool { currentTarget != nil && isConnected }
    var canChoosePlayer: Bool { isConnected && selectableTargets.count > 1 && !isSwitchingPlayer }
    var canSkipTrack: Bool { (currentTarget?.supportsNextPrevious ?? false) && isConnected }
    var hasFavoriteMediaItems: Bool { Self.hasFavoriteMediaItems(playlists: favoritePlaylists, albums: favoriteAlbums) }
    var hasIndividualVolumeTargets: Bool { individualVolumeTargets.count > 1 }
    var targetText: String { currentTarget?.resolvedName ?? "No active target" }
    var nowPlayingText: String { currentTarget?.nowPlayingLine ?? (currentTarget?.isPlaying == true ? "Playing" : "Nothing playing") }
    var isTargetPlaying: Bool { currentTarget?.isPlaying ?? false }
    var playPauseTitle: String { currentTarget.map { $0.isPlaying ? "Pause" : "Play" } ?? "Play/Pause" }
    var playPauseIconName: String { currentTarget.map { $0.isPlaying ? "pause.fill" : "play.fill" } ?? "playpause.fill" }

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

        guard currentTarget?.playerID != id else {
            return
        }

        Task { [weak self] in
            await self?.transferPlayback(to: id)
        }
    }

    func isCurrentTarget(id: String) -> Bool {
        currentTarget?.playerID == id
    }

    func togglePlayPause() {
        sendTransportCommand(queueCommand: "player_queues/play_pause") {
            self.playbackFallbackCommands(for: $0)
        }
    }

    func previousTrack() {
        sendTransportCommand(queueCommand: "player_queues/previous") { _ in
            ["players/cmd/previous"]
        }
    }

    func nextTrack() {
        sendTransportCommand(queueCommand: "player_queues/next") { _ in
            ["players/cmd/next"]
        }
    }

    func playFavoriteItem(_ item: MAFavoriteMediaItem) {
        guard let (target, client) = requireTargetAndClient() else { return }

        Task {
            await playFavoriteItem(item, on: target.playerID, client: client)
        }
    }

    private func sendTransportCommand(
        queueCommand: String? = nil,
        playerCommands: @escaping (MAPlayer) -> [String]
    ) {
        guard let (target, client) = requireTargetAndClient() else { return }

        let playerID = target.playerID
        let attempts: [(String, [String: JSONValue])] =
            (queueCommand.map { [($0, ["queue_id": .string(playerID)])] } ?? [])
            + playerCommands(target).map { ($0, ["player_id": .string(playerID)]) }

        Task {
            for (command, args) in attempts {
                do {
                    _ = try await client.send(command: command, args: args)
                    completeCommand(for: playerID)
                    return
                } catch {
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func requireTargetAndClient() -> (MAPlayer, MAWebSocketClient)? {
        guard let target = currentTarget else {
            errorText = "No active target available"
            return nil
        }

        guard let client else {
            errorText = "Configure API host and token first"
            return nil
        }

        return (target, client)
    }

    private func completeCommand(for playerID: String? = nil) {
        if let playerID {
            lastSuccessfulTargetID = playerID
        }
        errorText = nil
    }

    private func clampedVolume(_ value: Double) -> Double {
        min(max(value.rounded(), 0), 100)
    }

    private func resetPendingVolume(for playerID: String) {
        pendingIndividualVolumes.removeValue(forKey: playerID)
        rebuildIndividualVolumeTargets(for: currentTarget)
    }

    func setVolume(_ newValue: Double) {
        guard let target = currentTarget else { return }

        let clamped = clampedVolume(newValue)
        guard sliderVolume != clamped else { return }
        sliderVolume = clamped

        volumeSendTask?.cancel()
        let level = Int(clamped)
        let playerID = target.playerID
        let command = target.isGroupLike ? "players/cmd/group_volume" : "players/cmd/volume_set"
        volumeSendTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await self?.sendVolume(level, playerID: playerID, command: command)
        }
    }

    func setIndividualVolume(_ newValue: Double, for playerID: String) {
        guard let existingTarget = individualVolumeTargets.first(where: { $0.playerID == playerID }) else {
            return
        }

        let clamped = clampedVolume(newValue)
        guard existingTarget.volume != clamped else { return }

        pendingIndividualVolumes[playerID] = clamped
        rebuildIndividualVolumeTargets(for: currentTarget)

        individualVolumeSendTasks[playerID]?.cancel()
        let level = Int(clamped)
        individualVolumeSendTasks[playerID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await self?.sendVolume(level, playerID: playerID, command: "players/cmd/volume_set", resetsPendingVolume: true)
        }
    }

    private func sendVolume(
        _ level: Int,
        playerID: String,
        command: String,
        resetsPendingVolume: Bool = false
    ) async {
        guard let client else {
            if resetsPendingVolume {
                resetPendingVolume(for: playerID)
            }
            errorText = "Configure API host and token first"
            return
        }

        do {
            _ = try await client.send(
                command: command,
                args: [
                    "player_id": .string(playerID),
                    "volume_level": .integer(level)
                ]
            )
            if resetsPendingVolume {
                pendingIndividualVolumes.removeValue(forKey: playerID)
            } else if currentTarget?.playerID == playerID {
                completeCommand(for: playerID)
                return
            }
            errorText = nil
        } catch {
            if resetsPendingVolume {
                resetPendingVolume(for: playerID)
            }
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

        isSetupRequired = false

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
        isSetupRequired = true
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

            playersByID = Dictionary(
                uniqueKeysWithValues: try JSONValueDecoder.decode([MAPlayer].self, from: result).map { ($0.playerID, $0) }
            )
            updateTargetAndUI()
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

    private func removePlayer(withID playerID: String) {
        playersByID.removeValue(forKey: playerID)
        individualVolumeSendTasks[playerID]?.cancel()
        individualVolumeSendTasks.removeValue(forKey: playerID)
        pendingIndividualVolumes.removeValue(forKey: playerID)
        updateTargetAndUI()
    }

    private func updateTargetAndUI() {
        let resolution = Self.resolveSelectableTargets(
            players: Array(playersByID.values),
            lastSuccessfulTargetID: lastSuccessfulTargetID
        )
        let target = resolution.target

        selectableTargets = resolution.selectableTargets
        currentTarget = target

        nowPlayingArtworkURL = resolveArtworkURL(for: target)
        rebuildIndividualVolumeTargets(for: target)

        if let volume = target?.effectiveVolume {
            let newVolume = Double(volume)
            if sliderVolume != newVolume {
                sliderVolume = newVolume
            }
        }
    }

    private func rebuildIndividualVolumeTargets(for target: MAPlayer?) {
        var targets: [IndividualVolumeTarget] = []

        for player in Self.resolveIndividualVolumeTargets(playersByID: playersByID, target: target) {
            let liveVolume = player.effectiveVolume

            if
                let pendingVolume = pendingIndividualVolumes[player.playerID],
                let liveVolume,
                Double(liveVolume) == pendingVolume
            {
                pendingIndividualVolumes.removeValue(forKey: player.playerID)
            }

            let displayVolume = pendingIndividualVolumes[player.playerID] ?? Double(liveVolume ?? 0)
            targets.append(
                IndividualVolumeTarget(
                    playerID: player.playerID,
                    name: player.resolvedName,
                    volume: displayVolume,
                    isAdjustable: player.isAvailable && liveVolume != nil
                )
            )
        }

        individualVolumeTargets = targets
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

    private func playbackFallbackCommands(for target: MAPlayer) -> [String] {
        let preferredCommand =
            target.isPlaying
            ? (target.supportsPause ? "players/cmd/pause" : "players/cmd/play_pause")
            : "players/cmd/play"
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
            let command = switch kind {
            case .playlist: "music/playlists/library_items"
            case .album: "music/albums/library_items"
            }
            guard let result = try await client.send(
                command: command,
                args: [
                    "favorite": .bool(true),
                    "limit": .integer(favoriteMediaLimit)
                ]
            ) else {
                return []
            }

            return (result.arrayValue ?? []).compactMap { MAFavoriteMediaItem(kind: kind, value: $0) }
        } catch {
            return []
        }
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

        guard let sourceTarget = currentTarget else {
            completeTargetSwitch(to: targetPlayerID)
            return
        }

        do {
            guard
                let sourceQueueID = try await activeQueueID(for: sourceTarget.playerID, client: client),
                sourceQueueID != targetPlayerID
            else {
                completeTargetSwitch(to: targetPlayerID)
                return
            }

            _ = try await client.send(
                command: "player_queues/transfer",
                args: [
                    "source_queue_id": .string(sourceQueueID),
                    "target_queue_id": .string(targetPlayerID)
                ]
            )
            completeTargetSwitch(to: targetPlayerID)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func completeTargetSwitch(to playerID: String) {
        lastSuccessfulTargetID = playerID
        updateTargetAndUI()
        errorText = nil
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

    private func handleConnectionState(_ state: MAConnectionState) {
        connectionState = state
        isSetupRequired = false

        switch state {
        case .connecting, .authenticating:
            break
        case .connected:
            settingsStatusText = nil
            if collapseSettingsOnNextConnect {
                collapseSettingsOnNextConnect = false
                settingsCollapseToken &+= 1
            }
            Task {
                async let playersRefresh: Void = refreshPlayers()
                requestFavoriteMediaRefresh()
                _ = await playersRefresh
            }
        case let .disconnected(reason):
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
        case let .event(name, objectID, data):
            handleEvent(name: name, objectID: objectID, data: data)
        case let .error(_, _, details):
            errorText = details
        case .result:
            return
        }
    }

    private func handleEvent(name: String, objectID: String?, data: JSONValue?) {
        switch name {
        case "player_added", "player_updated":
            guard let data else {
                return
            }
            do {
                let player = try JSONValueDecoder.decode(MAPlayer.self, from: data)
                playersByID[player.playerID] = player
                updateTargetAndUI()
            } catch {
                errorText = "Failed to decode \(name): \(error.localizedDescription)"
            }
        case "player_removed":
            guard let playerID = data?.stringValue ?? data?.objectValue?["player_id"]?.stringValue else {
                return
            }
            removePlayer(withID: playerID)
        case "media_item_updated":
            guard Self.shouldRefreshFavoriteMedia(objectID: objectID, data: data) else {
                return
            }
            requestFavoriteMediaRefresh()
        default:
            return
        }
    }

    private func requestFavoriteMediaRefresh() {
        favoriteMediaRefreshPending = true
        guard favoriteMediaRefreshTask == nil else {
            return
        }

        favoriteMediaRefreshTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            defer {
                self.favoriteMediaRefreshTask = nil
            }

            while self.favoriteMediaRefreshPending {
                self.favoriteMediaRefreshPending = false
                await self.refreshFavoriteMedia()
            }
        }
    }
}
