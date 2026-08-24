import Foundation
import Combine

enum DamageState: String, Equatable {
    case healthy
    case minor
    case medium
    case heavy
    case unknown

    var label: String {
        switch self {
        case .healthy: return "健在"
        case .minor: return "小破"
        case .medium: return "中破"
        case .heavy: return "大破"
        case .unknown: return "不明"
        }
    }
}

struct ShipSnapshot: Identifiable, Equatable {
    let id: Int
    let masterID: Int
    let level: Int
    let nowHP: Int
    let maxHP: Int
    let fuel: Int
    let ammo: Int
    let onslot: [Int]
}

struct BattleHP: Equatable {
    let now: Int
    let max: Int
}

struct ShipDisplay: Identifiable, Equatable {
    let id: Int
    let name: String
    let level: Int
    let hp: BattleHP
    let fuel: Int
    let ammo: Int
    let onslot: [Int]
    let isBattleComputed: Bool

    var damageState: DamageState {
        guard hp.max > 0 else { return .unknown }
        if hp.now <= 0 || hp.now * 4 <= hp.max { return .heavy }
        if hp.now * 2 <= hp.max { return .medium }
        if hp.now * 4 <= hp.max * 3 { return .minor }
        return .healthy
    }
}

@MainActor
final class KCSAPIStore: ObservableObject {
    @Published private(set) var masterNames: [Int: String] = [:]
    @Published private(set) var ships: [Int: ShipSnapshot] = [:]
    @Published private(set) var decks: [Int: [Int]] = [:]
    @Published private(set) var battleHP: [Int: BattleHP] = [:]
    @Published private(set) var combinedFlag = 0
    @Published private(set) var sortieDeckID = 1
    @Published private(set) var apiCount = 0
    @Published private(set) var lastPath = ""
    @Published private(set) var choiceActive = false
    @Published private(set) var uncertain = false
    @Published private(set) var uncertainReason = ""

    var onSafetyWarning: (([ShipDisplay], String?) -> Void)?

    var fleet1IDs: [Int] {
        decks[sortieDeckID] ?? []
    }

    var fleet2IDs: [Int] {
        guard sortieDeckID == 1, combinedFlag > 0 else { return [] }
        return decks[2] ?? []
    }

    var heavyShips: [ShipDisplay] {
        (shipsForFleet(1) + shipsForFleet(2)).filter { $0.damageState == .heavy }
    }

    var shouldBlockProgress: Bool {
        choiceActive && (!heavyShips.isEmpty || uncertain)
    }

    func shipsForFleet(_ fleet: Int) -> [ShipDisplay] {
        let ids = fleet == 2 ? fleet2IDs : fleet1IDs
        return ids.compactMap(displayShip)
    }

    func handleBridgeMessage(_ body: Any) {
        guard let message = body as? [String: Any],
              (message["type"] as? String) == "api",
              let path = message["path"] as? String else { return }

        apiCount += 1
        lastPath = path

        let data = message["data"] as? [String: Any] ?? [:]
        let request = message["request"] as? [String: Any] ?? [:]

        if path.contains("/api_start2/getData") {
            ingestMasterShips(data["masterShips"])
        } else if path.contains("/api_port/port") {
            ingestShips(data["ships"])
            ingestDecks(data["decks"])
            combinedFlag = int(data["combinedFlag"]) ?? combinedFlag
            battleHP.removeAll(keepingCapacity: true)
            choiceActive = false
            uncertain = false
            uncertainReason = ""
        } else if path.contains("/api_get_member/ship_deck") ||
                    path.contains("/api_get_member/ship2") ||
                    path.contains("/api_get_member/ship3") {
            ingestShips(data["ships"])
            ingestDecks(data["decks"])
        } else if path.contains("/api_get_member/deck") {
            ingestDecks(data["decks"])
        } else if path.contains("/api_req_map/start") {
            sortieDeckID = int(request["api_deck_id"]) ?? 1
            battleHP.removeAll(keepingCapacity: true)
            choiceActive = false
            uncertain = false
            uncertainReason = ""
        } else if path.contains("/api_req_map/next") {
            choiceActive = false
        } else if isBattlePath(path) {
            readBattle(data["battle"])
        } else if path.contains("/battleresult") {
            choiceActive = true
            if battleHP.isEmpty {
                uncertain = true
                uncertainReason = "戦闘後HPを取得できませんでした"
            }
            let danger = heavyShips
            if !danger.isEmpty || uncertain {
                onSafetyWarning?(danger, uncertain ? uncertainReason : nil)
            }
        } else if path.contains("/goback_port") {
            choiceActive = false
            battleHP.removeAll(keepingCapacity: true)
            uncertain = false
            uncertainReason = ""
        }
    }

    /// メモリ警告時の軽量化。進撃/撤退の選択中は安全判定に必要な戦闘後HPを保持する。
    @discardableResult
    func trimTransientStateIfSafe() -> Bool {
        guard !choiceActive else { return false }
        battleHP.removeAll(keepingCapacity: false)
        return true
    }

    /// WebKitプロセスが終了した場合、古い戦闘状態を進撃判定へ持ち越さない。
    func resetAfterWebProcessTermination() {
        battleHP.removeAll(keepingCapacity: false)
        choiceActive = false
        uncertain = false
        uncertainReason = ""
    }

    private func displayShip(_ id: Int) -> ShipDisplay? {
        guard let ship = ships[id] else { return nil }
        let hp = battleHP[id] ?? BattleHP(now: ship.nowHP, max: ship.maxHP)
        return ShipDisplay(
            id: ship.id,
            name: masterNames[ship.masterID] ?? "艦ID \(ship.masterID)",
            level: ship.level,
            hp: hp,
            fuel: ship.fuel,
            ammo: ship.ammo,
            onslot: ship.onslot,
            isBattleComputed: battleHP[id] != nil
        )
    }

    private func ingestMasterShips(_ value: Any?) {
        guard let rows = value as? [[String: Any]] else { return }
        var next = masterNames
        for row in rows {
            guard let id = int(row["id"]), let name = row["name"] as? String else { continue }
            next[id] = name
        }
        masterNames = next
    }

    private func ingestShips(_ value: Any?) {
        guard let rows = value as? [[String: Any]] else { return }
        var next = ships
        for row in rows {
            guard let id = int(row["instanceId"]), let masterID = int(row["masterId"]) else { continue }
            next[id] = ShipSnapshot(
                id: id,
                masterID: masterID,
                level: int(row["level"]) ?? 0,
                nowHP: int(row["nowHP"]) ?? 0,
                maxHP: max(1, int(row["maxHP"]) ?? 1),
                fuel: int(row["fuel"]) ?? 0,
                ammo: int(row["ammo"]) ?? 0,
                onslot: intArray(row["onslot"])
            )
        }
        ships = next
    }

    private func ingestDecks(_ value: Any?) {
        guard let rows = value as? [[String: Any]] else { return }
        var next = decks
        for row in rows {
            guard let id = int(row["id"]) else { continue }
            next[id] = intArray(row["ships"]).filter { $0 > 0 }
        }
        decks = next
    }

    private func isBattlePath(_ path: String) -> Bool {
        guard path.range(of: #"/api_req_(sortie|combined_battle|battle_midnight)/"#, options: .regularExpression) != nil else {
            return false
        }
        return !path.contains("/battleresult") && !path.contains("/goback_port")
    }

    private func readBattle(_ value: Any?) {
        guard let battle = value as? [String: Any] else {
            uncertain = true
            uncertainReason = "戦闘API解析失敗"
            return
        }

        let now1 = hpArray(battle["fNowHPs"])
        let max1 = hpArray(battle["fMaxHPs"])
        let now2 = hpArray(battle["fNowHPsCombined"])
        let max2 = hpArray(battle["fMaxHPsCombined"])

        guard !now1.isEmpty, !max1.isEmpty else {
            uncertain = true
            uncertainReason = "戦闘開始HPがありません"
            return
        }

        var hp = now1 + now2
        let maxHP = max1 + max2
        let order = fleet1IDs + fleet2IDs

        guard order.count >= min(hp.count, 6) else {
            uncertain = true
            uncertainReason = "艦隊とHPの対応に失敗しました"
            return
        }

        applyIndexed(&hp, battle["airFDam"], offset: 0)
        applyIndexed(&hp, battle["airCombinedFDam"], offset: 6)
        applyIndexed(&hp, battle["combinedAirFDam"], offset: 6)
        applyIndexed(&hp, battle["openingFDam"], offset: 0)

        for key in ["openingTaisen", "hougeki1", "hougeki2", "hougeki3", "hougeki", "nightHougeki1", "nightHougeki2"] {
            applyShell(&hp, battle[key])
        }

        applyIndexed(&hp, battle["raigekiFDam"], offset: 0)
        applyIndexed(&hp, battle["raigekiCombinedFDam"], offset: 6)

        var next: [Int: BattleHP] = [:]
        let count = min(order.count, hp.count, maxHP.count)
        for index in 0..<count {
            next[order[index]] = BattleHP(now: max(0, hp[index]), max: max(1, maxHP[index]))
        }
        battleHP = next
        uncertain = false
        uncertainReason = ""
    }

    private func applyIndexed(_ hp: inout [Int], _ value: Any?, offset: Int) {
        let damages = doubleArray(value)
        for (index, damage) in damages.enumerated() where damage > 0 {
            let target = index + offset
            guard hp.indices.contains(target) else { continue }
            hp[target] -= Int(damage.rounded(.down))
        }
    }

    private func applyShell(_ hp: inout [Int], _ value: Any?) {
        guard let phase = value as? [String: Any],
              let rawTargets = phase["dfList"] as? [Any],
              let rawDamages = phase["damage"] as? [Any] else { return }

        let eflags = intArray(phase["atEflag"])
        let count = min(rawTargets.count, rawDamages.count)

        for attackIndex in 0..<count {
            if !eflags.isEmpty, eflags.indices.contains(attackIndex), eflags[attackIndex] != 1 { continue }
            let targets = intArray(rawTargets[attackIndex])
            let damages = doubleArray(rawDamages[attackIndex])

            for index in 0..<min(targets.count, damages.count) {
                var target = targets[index]
                let damage = damages[index]
                guard damage > 0 else { continue }

                if eflags.isEmpty {
                    guard (1...6).contains(target) else { continue }
                    target -= 1
                }

                guard hp.indices.contains(target) else { continue }
                hp[target] -= Int(damage.rounded(.down))
            }
        }
    }

    private func hpArray(_ value: Any?) -> [Int] {
        var values = intArray(value)
        if values.first.map({ $0 < 0 }) == true { values.removeFirst() }
        return values
    }

    private func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func intArray(_ value: Any?) -> [Int] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap(int)
    }

    private func doubleArray(_ value: Any?) -> [Double] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap {
            if let number = $0 as? NSNumber { return number.doubleValue }
            if let double = $0 as? Double { return double }
            if let int = $0 as? Int { return Double(int) }
            return nil
        }
    }
}
