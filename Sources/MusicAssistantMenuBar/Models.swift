import Foundation

struct MACommandRequest: Sendable, Encodable {
    let message_id: String
    let command: String
    let args: [String: JSONValue]
}

enum MAInboundMessage: Sendable {
    case hello(MAServerHello)
    case result(messageID: String, result: JSONValue?, partial: Bool)
    case error(messageID: String, code: Int, details: String)
    case event(name: String, data: JSONValue?)
}

struct MAServerHello: Sendable, Decodable {
    let serverID: String
    let serverVersion: String
    let schemaVersion: Int

    private enum CodingKeys: String, CodingKey {
        case serverID = "server_id"
        case serverVersion = "server_version"
        case schemaVersion = "schema_version"
    }
}

struct MAPlayer: Sendable, Codable, Identifiable {
    let playerID: String
    let displayName: String?
    let name: String?
    let type: String?
    let available: Bool?
    let playbackState: String?
    let state: String?
    let syncedTo: String?
    let volumeLevel: Int?
    let groupVolume: Int?
    let supportedFeatures: [String]?
    let currentMedia: MACurrentMedia?

    var id: String { playerID }

    var resolvedName: String {
        if let displayName, !displayName.isEmpty {
            return displayName
        }
        if let name, !name.isEmpty {
            return name
        }
        return playerID
    }

    var isAvailable: Bool {
        available ?? false
    }

    var isPlaying: Bool {
        let playback = (playbackState ?? state ?? "").lowercased()
        return playback == "playing"
    }

    var isSyncedMember: Bool {
        guard let syncedTo, !syncedTo.isEmpty else {
            return false
        }
        return syncedTo != playerID
    }

    var supportsPause: Bool {
        supportedFeatures?.contains("pause") ?? false
    }

    var isGroupLike: Bool {
        if (type ?? "").lowercased() == "group" {
            return true
        }
        return volumeLevel == nil && groupVolume != nil
    }

    var effectiveVolume: Int? {
        volumeLevel ?? groupVolume
    }

    var nowPlayingLine: String? {
        currentMedia?.displayLine
    }

    private enum CodingKeys: String, CodingKey {
        case playerID = "player_id"
        case displayName = "display_name"
        case name
        case type
        case available
        case playbackState = "playback_state"
        case state
        case syncedTo = "synced_to"
        case volumeLevel = "volume_level"
        case groupVolume = "group_volume"
        case supportedFeatures = "supported_features"
        case currentMedia = "current_media"
    }
}

struct MACurrentMedia: Sendable, Codable {
    let title: String?
    let name: String?
    let artist: String?

    var displayLine: String? {
        let trackTitle = cleaned(title) ?? cleaned(name)
        let artistName = cleaned(artist)

        if let artistName, let trackTitle {
            return "\(artistName) - \(trackTitle)"
        }
        if let trackTitle {
            return trackTitle
        }
        if let artistName {
            return artistName
        }
        return nil
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum MAConnectionState: Sendable, Equatable {
    case disconnected(reason: String?)
    case connecting
    case authenticating
    case connected
}

struct MAInboundEnvelope: Decodable {
    let serverID: String?
    let serverVersion: String?
    let schemaVersion: Int?
    let messageID: String?
    let result: JSONValue?
    let partial: Bool?
    let errorCode: Int?
    let details: String?
    let event: String?
    let data: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case serverID = "server_id"
        case serverVersion = "server_version"
        case schemaVersion = "schema_version"
        case messageID = "message_id"
        case result
        case partial
        case errorCode = "error_code"
        case details
        case event
        case data
    }
}

enum MAWebSocketError: LocalizedError, Sendable {
    case disconnected
    case invalidMessage
    case authFailed(String)
    case commandError(code: Int, details: String)
    case internalFailure(String)

    var errorDescription: String? {
        switch self {
        case .disconnected:
            "Disconnected from Music Assistant"
        case .invalidMessage:
            "Received invalid message from server"
        case let .authFailed(reason):
            "Authentication failed: \(reason)"
        case let .commandError(code, details):
            "Command failed (\(code)): \(details)"
        case let .internalFailure(message):
            message
        }
    }
}
