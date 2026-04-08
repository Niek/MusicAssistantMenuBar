import Foundation

struct TargetSelectionResolution {
    let target: MAPlayer?
    let selectableTargets: [MAPlayer]
}

struct IndividualVolumeTarget: Identifiable {
    let playerID: String
    let name: String
    let volume: Double
    let isAdjustable: Bool

    var id: String { playerID }

    var volumeText: String {
        isAdjustable ? "\(Int(volume))%" : "--"
    }
}

extension PlayerStore {
    nonisolated static func resolveSelectableTargets(
        players: [MAPlayer],
        lastSuccessfulTargetID: String?
    ) -> TargetSelectionResolution {
        let selectableTargets = players
            .filter(\.isSelectableTarget)
            .sorted(by: arePlayersOrderedForDisplay)

        let playingTargets = selectableTargets.filter(\.isPlaying)
        let preferredTarget = playingTargets.first(where: \.isGroupLike)
            ?? playingTargets.first(where: { !$0.isSyncedMember })
            ?? selectableTargets.first(where: { $0.playerID == lastSuccessfulTargetID })

        return TargetSelectionResolution(
            target: preferredTarget,
            selectableTargets: selectableTargets
        )
    }

    nonisolated static func resolveIndividualVolumeTargets(
        playersByID: [String: MAPlayer],
        target: MAPlayer?
    ) -> [MAPlayer] {
        guard let target else {
            return []
        }

        if !target.groupMemberIDs.isEmpty {
            guard target.groupMemberIDs.count > 1 else {
                return []
            }

            var seen = Set<String>()
            return target.groupMemberIDs.compactMap { memberID in
                guard seen.insert(memberID).inserted else {
                    return nil
                }

                if memberID == target.playerID {
                    return target
                }

                return playersByID[memberID]
            }
        }

        let syncedMembers = playersByID.values
            .filter { $0.syncedTo == target.playerID }
            .sorted(by: arePlayersOrderedForDisplay)

        guard !syncedMembers.isEmpty else {
            return []
        }

        if (target.type ?? "").lowercased() == "group" {
            return syncedMembers.count > 1 ? syncedMembers : []
        }

        return [target] + syncedMembers
    }

    nonisolated static func hasFavoriteMediaItems(
        playlists: [MAFavoriteMediaItem],
        albums: [MAFavoriteMediaItem]
    ) -> Bool {
        !playlists.isEmpty || !albums.isEmpty
    }

    nonisolated static func shouldRefreshFavoriteMedia(
        objectID: String?,
        data: JSONValue?
    ) -> Bool {
        favoriteMediaKind(from: data) != nil || favoriteMediaKind(fromURI: objectID) != nil
    }

    nonisolated private static func arePlayersOrderedForDisplay(_ lhs: MAPlayer, _ rhs: MAPlayer) -> Bool {
        let comparison = lhs.resolvedName.localizedCaseInsensitiveCompare(rhs.resolvedName)
        return comparison == .orderedAscending || (comparison == .orderedSame && lhs.playerID < rhs.playerID)
    }

    nonisolated private static func favoriteMediaKind(from value: JSONValue?) -> MAFavoriteMediaKind? {
        guard let object = value?.objectValue else {
            return nil
        }

        if let mediaKind = favoriteMediaKind(fromMediaType: object["media_type"]?.stringValue) {
            return mediaKind
        }

        return favoriteMediaKind(fromURI: object["uri"]?.stringValue)
    }

    nonisolated private static func favoriteMediaKind(fromMediaType mediaType: String?) -> MAFavoriteMediaKind? {
        switch mediaType?.lowercased() {
        case "playlist":
            return .playlist
        case "album":
            return .album
        default:
            return nil
        }
    }

    nonisolated private static func favoriteMediaKind(fromURI uri: String?) -> MAFavoriteMediaKind? {
        guard let uri else {
            return nil
        }

        let normalized = uri.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return nil
        }

        if normalized.contains("playlist") {
            return .playlist
        }
        if normalized.contains("album") {
            return .album
        }

        return nil
    }
}
