import XCTest
@testable import MusicAssistantMenuBar

final class TargetSelectionTests: XCTestCase {
    func testSelectionPrefersPlayingGroupThenCoordinatorThenLastSuccessfulTarget() {
        let kitchen = player(id: "kitchen", name: "Kitchen", playbackState: "playing")
        let wholeHome = player(
            id: "whole-home",
            name: "Whole Home",
            type: "group",
            playbackState: "playing",
            volumeLevel: nil,
            groupVolume: 52
        )
        let groupResolution = PlayerStore.resolveSelectableTargets(
            players: [kitchen, wholeHome],
            lastSuccessfulTargetID: nil
        )
        XCTAssertEqual(groupResolution.target?.playerID, "whole-home")

        let office = player(id: "office", name: "Office", playbackState: "playing")
        let bedroom = player(id: "bedroom", name: "Bedroom")
        let coordinatorResolution = PlayerStore.resolveSelectableTargets(
            players: [bedroom, office],
            lastSuccessfulTargetID: nil
        )
        XCTAssertEqual(coordinatorResolution.target?.playerID, "office")

        let idleOffice = player(id: "office", name: "Office")
        let lastSuccessfulResolution = PlayerStore.resolveSelectableTargets(
            players: [bedroom, idleOffice],
            lastSuccessfulTargetID: "bedroom"
        )
        XCTAssertEqual(lastSuccessfulResolution.target?.playerID, "bedroom")
    }

    func testSelectableTargetsExcludeSyncedMembersAndStaySorted() {
        let kitchen = player(id: "kitchen", name: "Kitchen")
        let livingRoom = player(id: "living-room", name: "Living Room")
        let bedroom = player(id: "bedroom", name: "Bedroom", syncedTo: "living-room")
        let attic = player(id: "attic", name: "Attic", available: false)
        let everywhere = player(
            id: "everywhere",
            name: "Everywhere",
            type: "group",
            volumeLevel: nil,
            groupVolume: 40
        )

        let resolution = PlayerStore.resolveSelectableTargets(
            players: [kitchen, livingRoom, bedroom, attic, everywhere],
            lastSuccessfulTargetID: nil
        )

        XCTAssertEqual(
            resolution.selectableTargets.map(\.playerID),
            ["everywhere", "kitchen", "living-room"]
        )
    }

    func testSelectionPrefersPlayingCoordinatorOverIdleGroup() {
        let group = player(
            id: "everywhere",
            name: "Everywhere",
            type: "group",
            playbackState: "idle",
            volumeLevel: nil,
            groupVolume: 40
        )
        let office = player(id: "office", name: "Office", playbackState: "playing")

        let resolution = PlayerStore.resolveSelectableTargets(
            players: [group, office],
            lastSuccessfulTargetID: nil
        )

        XCTAssertEqual(resolution.target?.playerID, "office")
    }

    func testSelectionSortFallsBackToPlayerIDForMatchingNames() {
        let alpha = player(id: "alpha", name: "Living Room")
        let beta = player(id: "beta", name: "Living Room")

        let resolution = PlayerStore.resolveSelectableTargets(
            players: [beta, alpha],
            lastSuccessfulTargetID: nil
        )

        XCTAssertEqual(resolution.selectableTargets.map(\.playerID), ["alpha", "beta"])
    }

    func testMissingLastSuccessfulTargetFallsBackToNoTarget() {
        let kitchen = player(id: "kitchen", name: "Kitchen")
        let bedroom = player(id: "bedroom", name: "Bedroom", available: false)

        let resolution = PlayerStore.resolveSelectableTargets(
            players: [kitchen, bedroom],
            lastSuccessfulTargetID: "bedroom"
        )

        XCTAssertNil(resolution.target)
    }

    func testIndividualVolumeTargetsFollowDeclaredGroupMemberOrder() {
        let leader = player(
            id: "leader",
            name: "Living Room",
            groupMembers: ["leader", "kitchen", "bedroom"]
        )
        let kitchen = player(id: "kitchen", name: "Kitchen")
        let bedroom = player(id: "bedroom", name: "Bedroom")

        let targets = PlayerStore.resolveIndividualVolumeTargets(
            playersByID: [
                leader.playerID: leader,
                kitchen.playerID: kitchen,
                bedroom.playerID: bedroom
            ],
            target: leader
        )

        XCTAssertEqual(targets.map(\.playerID), ["leader", "kitchen", "bedroom"])
    }

    func testIndividualVolumeTargetsFallbackToSyncedMembersWhenGroupMembersMissing() {
        let leader = player(id: "leader", name: "Living Room")
        let kitchen = player(id: "kitchen", name: "Kitchen", syncedTo: "leader")
        let bedroom = player(id: "bedroom", name: "Bedroom", syncedTo: "leader")

        let targets = PlayerStore.resolveIndividualVolumeTargets(
            playersByID: [
                leader.playerID: leader,
                kitchen.playerID: kitchen,
                bedroom.playerID: bedroom
            ],
            target: leader
        )

        XCTAssertEqual(targets.map(\.playerID), ["leader", "bedroom", "kitchen"])
    }

    private func player(
        id: String,
        name: String,
        type: String? = nil,
        available: Bool = true,
        playbackState: String? = "idle",
        syncedTo: String? = nil,
        volumeLevel: Int? = 24,
        groupVolume: Int? = nil,
        groupMembers: [String]? = nil
    ) -> MAPlayer {
        MAPlayer(
            playerID: id,
            displayName: name,
            name: nil,
            type: type,
            available: available,
            playbackState: playbackState,
            state: nil,
            syncedTo: syncedTo,
            volumeLevel: volumeLevel,
            groupVolume: groupVolume,
            groupMembers: groupMembers,
            supportedFeatures: nil,
            currentMedia: nil
        )
    }
}
