import XCTest
@testable import MusicAssistantMenuBar

final class ModelsTests: XCTestCase {
    func testResolvedNameFallsBackFromDisplayNameToNameToPlayerID() {
        let withDisplayName = makePlayer(id: "office", displayName: "Office Speaker", name: "Office")
        XCTAssertEqual(withDisplayName.resolvedName, "Office Speaker")

        let withName = makePlayer(id: "office", displayName: nil, name: "Office")
        XCTAssertEqual(withName.resolvedName, "Office")

        let withIDOnly = makePlayer(id: "office", displayName: nil, name: nil)
        XCTAssertEqual(withIDOnly.resolvedName, "office")
    }

    func testIsPlayingFallsBackToStateWhenPlaybackStateMissing() {
        let player = makePlayer(id: "office", displayName: "Office", playbackState: nil, state: "playing")
        XCTAssertTrue(player.isPlaying)
    }

    func testIsGroupLikeRecognizesGroupTypeAndGroupVolumeFallback() {
        let typedGroup = makePlayer(
            id: "everywhere",
            displayName: "Everywhere",
            type: "group",
            volumeLevel: 25,
            groupVolume: nil
        )
        XCTAssertTrue(typedGroup.isGroupLike)

        let implicitGroup = makePlayer(
            id: "everywhere",
            displayName: "Everywhere",
            type: nil,
            volumeLevel: nil,
            groupVolume: 35
        )
        XCTAssertTrue(implicitGroup.isGroupLike)

        let normalPlayer = makePlayer(
            id: "office",
            displayName: "Office",
            type: nil,
            volumeLevel: 35,
            groupVolume: nil
        )
        XCTAssertFalse(normalPlayer.isGroupLike)
    }

    func testSelectableTargetRequiresAvailabilityAndTopLevelPlayer() {
        let availablePlayer = makePlayer(id: "office", displayName: "Office", available: true, syncedTo: nil)
        XCTAssertTrue(availablePlayer.isSelectableTarget)

        let syncedMember = makePlayer(
            id: "office",
            displayName: "Office",
            available: true,
            syncedTo: "living-room"
        )
        XCTAssertFalse(syncedMember.isSelectableTarget)

        let unavailablePlayer = makePlayer(id: "office", displayName: "Office", available: false, syncedTo: nil)
        XCTAssertFalse(unavailablePlayer.isSelectableTarget)
    }

    func testCurrentMediaDisplayLineFormatsArtistAndTitle() {
        let full = MACurrentMedia(title: "Track", name: nil, artist: "Artist", artworkURLString: nil)
        XCTAssertEqual(full.displayLine, "Artist - Track")

        let titleOnly = MACurrentMedia(title: nil, name: "Track", artist: nil, artworkURLString: nil)
        XCTAssertEqual(titleOnly.displayLine, "Track")

        let artistOnly = MACurrentMedia(title: nil, name: nil, artist: "Artist", artworkURLString: nil)
        XCTAssertEqual(artistOnly.displayLine, "Artist")
    }

    func testFavoritePlaylistParsingUsesURIForStableID() {
        let payload = JSONValue.object([
            "item_id": .integer(12),
            "name": .string("Road Trip"),
            "uri": .string("library://playlist/12")
        ])

        let item = MAFavoriteMediaItem(kind: .playlist, value: payload)

        XCTAssertEqual(item?.id, "playlist:library://playlist/12")
        XCTAssertEqual(item?.title, "Road Trip")
        XCTAssertEqual(item?.uri, "library://playlist/12")
    }

    func testFavoriteAlbumParsingFallsBackToItemIDAndKeepsRawPayload() {
        let payload = JSONValue.object([
            "item_id": .integer(42),
            "title": .string("Discovery")
        ])

        let item = MAFavoriteMediaItem(kind: .album, value: payload)

        XCTAssertEqual(item?.id, "album:42")
        XCTAssertEqual(item?.title, "Discovery")
        XCTAssertNil(item?.uri)

        guard case let .object(object)? = item?.rawPayload else {
            return XCTFail("Expected raw payload object")
        }

        XCTAssertEqual(object["item_id"]?.intValue, 42)
        XCTAssertEqual(object["title"]?.stringValue, "Discovery")
    }

    func testFavoriteMediaTitleFallbackPrefersNameThenTitleThenPlaceholder() {
        let nameFirst = MAFavoriteMediaItem(
            kind: .playlist,
            value: .object([
                "item_id": .integer(1),
                "name": .string("  Chill Mix  "),
                "title": .string("Ignored")
            ])
        )
        XCTAssertEqual(nameFirst?.title, "Chill Mix")

        let titleFallback = MAFavoriteMediaItem(
            kind: .album,
            value: .object([
                "item_id": .integer(2),
                "title": .string("Album Title")
            ])
        )
        XCTAssertEqual(titleFallback?.title, "Album Title")

        let placeholderFallback = MAFavoriteMediaItem(
            kind: .album,
            value: .object([
                "item_id": .integer(3)
            ])
        )
        XCTAssertEqual(placeholderFallback?.title, "Untitled Album")
    }

    private func makePlayer(
        id: String,
        displayName: String?,
        name: String? = nil,
        type: String? = nil,
        available: Bool = true,
        playbackState: String? = "idle",
        state: String? = nil,
        syncedTo: String? = nil,
        volumeLevel: Int? = 24,
        groupVolume: Int? = nil
    ) -> MAPlayer {
        MAPlayer(
            playerID: id,
            displayName: displayName,
            name: name,
            type: type,
            available: available,
            playbackState: playbackState,
            state: state,
            syncedTo: syncedTo,
            volumeLevel: volumeLevel,
            groupVolume: groupVolume,
            supportedFeatures: nil,
            currentMedia: nil
        )
    }
}
