import XCTest
@testable import KancolleIOS

@MainActor
final class KCSAPIStoreTests: XCTestCase {
    func testDamageThresholdBoundaries() {
        XCTAssertEqual(ship(now: 40, max: 40).damageState, .healthy)
        XCTAssertEqual(ship(now: 30, max: 40).damageState, .minor)
        XCTAssertEqual(ship(now: 20, max: 40).damageState, .medium)
        XCTAssertEqual(ship(now: 11, max: 40).damageState, .medium)
        XCTAssertEqual(ship(now: 10, max: 40).damageState, .heavy)
        XCTAssertEqual(ship(now: 0, max: 40).damageState, .heavy)
    }

    func testMemoryTrimKeepsHeavyBattleHPWhileChoiceIsActive() {
        let store = KCSAPIStore()
        var warnedHeavy = false
        store.onSafetyWarning = { ships, _ in
            warnedHeavy = ships.contains { $0.damageState == .heavy }
        }

        store.handleBridgeMessage([
            "type": "api",
            "path": "/kcsapi/api_port/port",
            "data": [
                "ships": [[
                    "instanceId": 1,
                    "masterId": 100,
                    "level": 50,
                    "nowHP": 40,
                    "maxHP": 40,
                    "fuel": 20,
                    "ammo": 30,
                    "onslot": [0]
                ]],
                "decks": [["id": 1, "ships": [1]]],
                "combinedFlag": 0
            ]
        ])

        store.handleBridgeMessage([
            "type": "api",
            "path": "/kcsapi/api_req_map/start",
            "request": ["api_deck_id": "1"],
            "data": [:]
        ])

        store.handleBridgeMessage([
            "type": "api",
            "path": "/kcsapi/api_req_sortie/battle",
            "data": [
                "battle": [
                    "fNowHPs": [-1, 40],
                    "fMaxHPs": [-1, 40],
                    "fNowHPsCombined": [],
                    "fMaxHPsCombined": [],
                    "airFDam": [],
                    "airCombinedFDam": [],
                    "combinedAirFDam": [],
                    "openingFDam": [],
                    "hougeki1": [
                        "dfList": [[0]],
                        "damage": [[30.0]],
                        "atEflag": [1]
                    ],
                    "raigekiFDam": [],
                    "raigekiCombinedFDam": []
                ]
            ]
        ])

        XCTAssertEqual(store.shipsForFleet(1).first?.hp.now, 10)
        XCTAssertEqual(store.shipsForFleet(1).first?.damageState, .heavy)

        store.handleBridgeMessage([
            "type": "api",
            "path": "/kcsapi/api_req_sortie/battleresult",
            "data": [:]
        ])

        XCTAssertTrue(store.choiceActive)
        XCTAssertTrue(store.shouldBlockProgress)
        XCTAssertTrue(warnedHeavy)

        XCTAssertFalse(store.trimTransientStateIfSafe())
        XCTAssertEqual(store.shipsForFleet(1).first?.hp.now, 10)
        XCTAssertEqual(store.shipsForFleet(1).first?.damageState, .heavy)

        store.handleBridgeMessage([
            "type": "api",
            "path": "/kcsapi/api_req_map/next",
            "data": [:]
        ])

        XCTAssertFalse(store.choiceActive)
        XCTAssertTrue(store.trimTransientStateIfSafe())
        XCTAssertEqual(store.shipsForFleet(1).first?.hp.now, 40)
    }

    private func ship(now: Int, max: Int) -> ShipDisplay {
        ShipDisplay(
            id: 1,
            name: "test",
            level: 1,
            hp: BattleHP(now: now, max: max),
            fuel: 0,
            ammo: 0,
            onslot: [],
            isBattleComputed: false
        )
    }
}
