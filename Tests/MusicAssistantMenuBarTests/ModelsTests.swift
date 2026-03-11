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
