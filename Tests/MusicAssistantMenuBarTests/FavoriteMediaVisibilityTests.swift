import XCTest
@testable import MusicAssistantMenuBar

final class FavoriteMediaVisibilityTests: XCTestCase {
    func testHasFavoriteMediaItemsReturnsTrueWhenEitherGroupHasItems() {
        XCTAssertTrue(
            PlayerStore.hasFavoriteMediaItems(
                playlists: [favorite(kind: .playlist, id: 1, title: "Road Trip", uri: "library://playlist/1")],
                albums: []
            )
        )

        XCTAssertTrue(
            PlayerStore.hasFavoriteMediaItems(
                playlists: [],
                albums: [favorite(kind: .album, id: 2, title: "Discovery")]
            )
        )
    }

    func testHasFavoriteMediaItemsReturnsFalseWhenBothGroupsAreEmpty() {
        XCTAssertFalse(
            PlayerStore.hasFavoriteMediaItems(
                playlists: [],
                albums: []
            )
        )
    }

    private func favorite(
        kind: MAFavoriteMediaKind,
        id: Int,
        title: String,
        uri: String? = nil
    ) -> MAFavoriteMediaItem {
        let payload: [String: JSONValue] = {
            var payload: [String: JSONValue] = [
                "item_id": .integer(id),
                "name": .string(title)
            ]
            if let uri {
                payload["uri"] = .string(uri)
            }
            return payload
        }()

        guard let item = MAFavoriteMediaItem(kind: kind, value: .object(payload)) else {
            fatalError("Expected favorite media item to parse")
        }

        return item
    }
}
