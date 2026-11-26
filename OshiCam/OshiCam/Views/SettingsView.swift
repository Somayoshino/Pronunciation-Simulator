import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("追従スピード", selection: $model.speed) {
                        ForEach(FollowSpeed.allCases) { speed in
                            Text(speed.label).tag(speed)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "あそび（デッドゾーン）: \(Int((model.deadZone * 100).rounded()))%")
                        Slider(value: $model.deadZone, in: 0...0.3)
                        Text("大きいほど、推しが少し動いたくらいでは画面が動かず落ち着いた映像になります。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("タップできる人物の枠を表示", isOn: $model.showCandidates)
                } header: {
                    Text("追尾")
                }

                Section {
                    Toggle("露出とピントを推しに合わせる", isOn: $model.followExposure)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("露出補正: \(String(format: "%+.1f", model.exposureBias)) EV")
                        Slider(value: $model.exposureBias, in: -3...3, step: 0.1)
                        Text("スポットライトで顔が白飛びするときはマイナスに。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("手ぶれ補正", isOn: $model.stabilization)
                } header: {
                    Text("露出・画質")
                }

                Section {
                    Text("・3× や 5× の望遠レンズでステージ全体を画面に入れ、そこから推しを切り出させると一番きれいに撮れます。")
                    Text("・スマホは三脚・一脚などで固定するのがおすすめ。手持ちのときは手ぶれ補正をオンに。")
                    Text("・推しが見えなくなっても、また映れば自動で探し直します。違う人を追い始めたら、推しをタップし直してください。")
                    Text("・長時間の撮影では本体が熱くなります。モバイルバッテリーと空き容量の確保を。")
                    Text("・撮影・録音は必ず公演のルールに従ってください。")
                } header: {
                    Text("撮影のコツ")
                }
                .font(.footnote)
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}
