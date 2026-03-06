import Foundation

actor MAWebSocketClient {
    typealias MessageHandler = @Sendable (MAInboundMessage) -> Void
    typealias StateHandler = @Sendable (MAConnectionState) -> Void

    private struct QueuedCommand {
        let request: MACommandRequest
        let continuation: CheckedContinuation<JSONValue?, Error>
    }

    private let url: URL
    private let token: String
    private let onMessage: MessageHandler
    private let onStateChange: StateHandler

    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var state: MAConnectionState = .disconnected(reason: nil)
    private var shouldReconnect = false
    private var reconnectDelaySeconds: Double = 1

    private var authMessageID: String?
    private var queuedCommands: [QueuedCommand] = []
    private var pendingResponses: [String: CheckedContinuation<JSONValue?, Error>] = [:]

    init(
        url: URL,
        token: String,
        onMessage: @escaping MessageHandler,
        onStateChange: @escaping StateHandler
    ) {
        self.url = url
        self.token = token
        self.onMessage = onMessage
        self.onStateChange = onStateChange
    }

    func connect() async {
        shouldReconnect = true
        await connectIfNeeded()
    }

    func reconnectNow() async {
        await disconnectInternal(failQueued: false)
        shouldReconnect = true
        await connectIfNeeded()
    }

    func disconnect() async {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        await disconnectInternal(failQueued: true)
    }

    func send(command: String, args: [String: JSONValue]) async throws -> JSONValue? {
        let request = MACommandRequest(
            message_id: UUID().uuidString,
            command: command,
            args: args
        )

        return try await withCheckedThrowingContinuation { continuation in
            queuedCommands.append(QueuedCommand(request: request, continuation: continuation))
            Task {
                await self.ensureConnectedAndFlushed()
            }
        }
    }

    private func ensureConnectedAndFlushed() async {
        if case .disconnected = state {
            await connectIfNeeded()
        }

        if state == .connected {
            await flushQueuedCommands()
        }
    }

    private func connectIfNeeded() async {
        guard case .disconnected = state else {
            return
        }

        setState(.connecting)

        let session = URLSession(configuration: .default)
        self.session = session

        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        setState(.authenticating)

        receiveLoopTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        do {
            try await sendAuth()
        } catch {
            await handleTransportFailure(error)
        }
    }

    private func sendAuth() async throws {
        let authID = "auth-\(UUID().uuidString)"
        authMessageID = authID

        let request = MACommandRequest(
            message_id: authID,
            command: "auth",
            args: ["token": .string(token)]
        )

        try await sendRaw(request)
    }

    private func flushQueuedCommands() async {
        guard state == .connected else {
            return
        }

        while state == .connected, !queuedCommands.isEmpty {
            let queued = queuedCommands.removeFirst()
            pendingResponses[queued.request.message_id] = queued.continuation

            do {
                try await sendRaw(queued.request)
            } catch {
                pendingResponses.removeValue(forKey: queued.request.message_id)
                queued.continuation.resume(throwing: error)
                await handleTransportFailure(error)
                return
            }
        }
    }

    private func sendRaw(_ request: MACommandRequest) async throws {
        guard let webSocketTask else {
            throw MAWebSocketError.disconnected
        }

        let payload = try JSONEncoder().encode(request)
        guard let payloadString = String(data: payload, encoding: .utf8) else {
            throw MAWebSocketError.internalFailure("Failed to encode websocket payload as UTF-8 string")
        }

        try await webSocketTask.send(.string(payloadString))
    }

    private func receiveLoop() async {
        while let webSocketTask {
            do {
                let message = try await webSocketTask.receive()
                try await handle(message: message)
            } catch {
                await handleTransportFailure(error)
                return
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) async throws {
        let data: Data

        switch message {
        case let .data(binary):
            data = binary
        case let .string(text):
            guard let textData = text.data(using: .utf8) else {
                throw MAWebSocketError.invalidMessage
            }
            data = textData
        @unknown default:
            throw MAWebSocketError.invalidMessage
        }

        let envelope = try JSONDecoder().decode(MAInboundEnvelope.self, from: data)
        try await route(envelope: envelope)
    }

    private func route(envelope: MAInboundEnvelope) async throws {
        if
            let serverID = envelope.serverID,
            let serverVersion = envelope.serverVersion,
            let schemaVersion = envelope.schemaVersion
        {
            onMessage(.hello(MAServerHello(serverID: serverID, serverVersion: serverVersion, schemaVersion: schemaVersion)))
            return
        }

        if let messageID = envelope.messageID, let code = envelope.errorCode {
            let details = envelope.details ?? "Unknown error"

            if messageID == authMessageID {
                authMessageID = nil
                shouldReconnect = false
                failPendingResponses(with: MAWebSocketError.authFailed(details))
                failQueuedCommands(with: MAWebSocketError.authFailed(details))
                closeSocket(closeCode: .normalClosure)
                setState(.disconnected(reason: details))
            } else {
                if let continuation = pendingResponses.removeValue(forKey: messageID) {
                    continuation.resume(throwing: MAWebSocketError.commandError(code: code, details: details))
                }
            }

            onMessage(.error(messageID: messageID, code: code, details: details))
            return
        }

        if let messageID = envelope.messageID {
            let partial = envelope.partial ?? false
            let result = envelope.result

            if messageID == authMessageID {
                authMessageID = nil
                let authenticated = result?.objectValue?["authenticated"]?.boolValue ?? false

                if authenticated {
                    reconnectDelaySeconds = 1
                    setState(.connected)
                    await flushQueuedCommands()
                } else {
                    shouldReconnect = false
                    failPendingResponses(with: MAWebSocketError.authFailed("Token rejected"))
                    failQueuedCommands(with: MAWebSocketError.authFailed("Token rejected"))
                    closeSocket(closeCode: .normalClosure)
                    setState(.disconnected(reason: "Token rejected"))
                }
            } else if let continuation = pendingResponses.removeValue(forKey: messageID) {
                continuation.resume(returning: result)
            }

            onMessage(.result(messageID: messageID, result: result, partial: partial))
            return
        }

        if let event = envelope.event {
            onMessage(.event(name: event, data: envelope.data))
        }
    }

    private func handleTransportFailure(_ error: Error) async {
        authMessageID = nil

        failPendingResponses(with: MAWebSocketError.disconnected)

        closeSocket(closeCode: .goingAway)

        if shouldReconnect {
            setState(.disconnected(reason: error.localizedDescription))
            scheduleReconnect()
        } else {
            failQueuedCommands(with: MAWebSocketError.disconnected)
            setState(.disconnected(reason: error.localizedDescription))
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else {
            return
        }

        let delay = reconnectDelaySeconds
        reconnectDelaySeconds = min(reconnectDelaySeconds * 2, 12)

        reconnectTask = Task { [weak self] in
            let nanos = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            await self?.completeReconnectWait()
        }
    }

    private func completeReconnectWait() async {
        reconnectTask = nil

        guard shouldReconnect else {
            return
        }

        await connectIfNeeded()
    }

    private func disconnectInternal(failQueued: Bool) async {
        closeSocket(closeCode: .normalClosure)

        authMessageID = nil

        failPendingResponses(with: MAWebSocketError.disconnected)
        if failQueued {
            failQueuedCommands(with: MAWebSocketError.disconnected)
        }

        setState(.disconnected(reason: nil))
    }

    private func failPendingResponses(with error: Error) {
        let continuations = pendingResponses.values
        pendingResponses.removeAll()

        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func failQueuedCommands(with error: Error) {
        let queued = queuedCommands
        queuedCommands.removeAll()

        for entry in queued {
            entry.continuation.resume(throwing: error)
        }
    }

    private func closeSocket(closeCode: URLSessionWebSocketTask.CloseCode) {
        webSocketTask?.cancel(with: closeCode, reason: nil)
        webSocketTask = nil

        receiveLoopTask?.cancel()
        receiveLoopTask = nil

        session?.invalidateAndCancel()
        session = nil
    }

    private func setState(_ newState: MAConnectionState) {
        state = newState
        onStateChange(newState)
    }
}
