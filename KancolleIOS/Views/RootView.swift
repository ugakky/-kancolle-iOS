import SwiftUI
import WebKit

struct RootView: View {
    @EnvironmentObject private var session: WebGameSession

    var body: some View {
        TabView {
            GameView(session: session)
                .tabItem {
                    Label("ゲーム", systemImage: "gamecontroller.fill")
                }

            FleetInfoView(session: session)
                .tabItem {
                    Label("情報", systemImage: "list.bullet.rectangle")
                }
        }
        .onAppear {
            session.loadGameIfNeeded()
            session.requestNotificationPermissionIfNeeded()
        }
    }
}

struct GameView: View {
    @ObservedObject private var session: WebGameSession
    @ObservedObject private var store: KCSAPIStore

    init(session: WebGameSession) {
        _session = ObservedObject(wrappedValue: session)
        _store = ObservedObject(wrappedValue: session.store)
    }

    var body: some View {
        GeometryReader { geometry in
            let gameRect = session.resolvedGameRect(in: geometry.size)

            ZStack(alignment: .topLeading) {
                WebViewContainer(session: session)
                    .ignoresSafeArea(edges: .top)

                if store.shouldBlockProgress && !session.isSafetyUnlocked {
                    SafetyBlockerView(session: session, store: store)
                        .frame(
                            width: gameRect.width * 0.60,
                            height: gameRect.height * 0.84
                        )
                        .position(
                            x: gameRect.minX + gameRect.width * 0.30,
                            y: gameRect.minY + gameRect.height * 0.50
                        )
                        .zIndex(100)
                }

                if session.isSafetyUnlocked && store.choiceActive {
                    Text("⚠️ 進撃ロック一時解除中（5秒）")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.green.opacity(0.88), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(8)
                        .zIndex(101)
                }
            }
        }
    }
}

private struct SafetyBlockerView: View {
    @ObservedObject var session: WebGameSession
    @ObservedObject var store: KCSAPIStore

    var body: some View {
        VStack(spacing: 10) {
            Text(store.heavyShips.isEmpty ? "⚠️ HP判定不明" : "🚨 大破艦あり")
                .font(.title3.bold())

            if !store.heavyShips.isEmpty {
                Text(store.heavyShips.map(\.name).joined(separator: " / "))
                    .font(.caption.bold())
                    .multilineTextAlignment(.center)
            }

            Text("進撃系ボタンをロック中")
                .font(.subheadline.bold())

            Text("進撃する場合だけ、この赤い範囲を3連続タップ")
                .font(.caption)
                .multilineTextAlignment(.center)

            Text("\(session.safetyTapCount) / 3")
                .font(.headline.monospacedDigit())
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(.red.opacity(0.90))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.9), lineWidth: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
        .onTapGesture {
            session.registerSafetyTap()
        }
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let session: WebGameSession

    func makeUIView(context: Context) -> WKWebView {
        session.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
