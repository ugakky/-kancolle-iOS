import SwiftUI

struct FleetInfoView: View {
    @ObservedObject private var session: WebGameSession
    @ObservedObject private var store: KCSAPIStore

    init(session: WebGameSession) {
        _session = ObservedObject(wrappedValue: session)
        _store = ObservedObject(wrappedValue: session.store)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("接続状態") {
                    LabeledContent("状態", value: session.statusMessage)
                    LabeledContent("API取得数", value: "\(store.apiCount)")
                    LabeledContent("最後のAPI", value: store.lastPath.isEmpty ? "-" : store.lastPath)
                    LabeledContent("WebKit再起動", value: "\(session.webProcessRestarts)回")

                    if store.uncertain {
                        Label(store.uncertainReason, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                fleetSection(title: "第1 / 出撃艦隊", ships: store.shipsForFleet(1))

                if !store.fleet2IDs.isEmpty {
                    fleetSection(title: "第2艦隊", ships: store.shipsForFleet(2))
                }

                Section("設計メモ") {
                    Text("HPの * は戦闘APIから計算した戦闘後値です。燃料・弾薬・搭載数は最後に艦これAPIから直接取得できた値です。")
                        .font(.footnote)
                    Text("アプリは生のAPIレスポンス履歴を保存せず、表示に必要な情報だけ保持します。")
                        .font(.footnote)
                }
            }
            .navigationTitle("艦隊情報")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        session.reloadGame()
                    } label: {
                        Label("再読み込み", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fleetSection(title: String, ships: [ShipDisplay]) -> some View {
        Section(title) {
            if ships.isEmpty {
                Text("母港データ待ち")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ships) { ship in
                    ShipInfoRow(ship: ship)
                }
            }
        }
    }
}

private struct ShipInfoRow: View {
    let ship: ShipDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(ship.damageState.label)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(stateColor, in: Capsule())

                Text("\(ship.name)  Lv\(ship.level)")
                    .font(.body.bold())

                Spacer()

                Text("HP \(ship.hp.now)/\(ship.hp.max)\(ship.isBattleComputed ? "*" : "")")
                    .font(.subheadline.monospacedDigit())
            }

            HStack(spacing: 14) {
                Label("燃 \(ship.fuel)", systemImage: "fuelpump")
                Label("弾 \(ship.ammo)", systemImage: "shippingbox")
                Label("搭載 \(slotText)", systemImage: "airplane")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var slotText: String {
        ship.onslot.isEmpty ? "-" : ship.onslot.map(String.init).joined(separator: "/")
    }

    private var stateColor: Color {
        switch ship.damageState {
        case .healthy: return .green
        case .minor: return .yellow
        case .medium: return .orange
        case .heavy: return .red
        case .unknown: return .gray
        }
    }
}
