import SwiftUI
import ARKit
import Photos

@main
struct LensTrueApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).preferredColorScheme(.dark)
        }
    }
}

enum Phase { case scan, processing, result }

@MainActor
final class AppModel: ObservableObject {
    @Published var phase: Phase = .scan
    @Published var progress = 0.0
    @Published var reticle: CGPoint?
    @Published var distance: Float?
    @Published var thickness: Float?
    @Published var elevation: Float = 0
    @Published var roll: Float = 0
    @Published var pull: Float = 2.0      // 仮想撮影距離 = 実距離 × pull
    @Published var level: Float = 1.0     // 水平補正の強さ
    @Published var procProgress = 0.0
    @Published var procMessage = ""
    @Published var before: UIImage?
    @Published var after: UIImage?
    @Published var infoText = ""
    @Published var toast: String?
    @Published var selfie = false
    let faceSupported = ARFaceTrackingConfiguration.isSupported
    let ar = ARController()

    init() { ar.model = self }

    func toggleSelfie() {
        selfie.toggle(); reticle = nil; distance = nil; thickness = nil
        ar.setMode(selfie: selfie)
    }

    func capture() {
        guard let snap = ar.snapshot() else { toast = "対象を取得できません。もう一度タップしてください"; return }
        let pull = self.pull, level = self.level
        phase = .processing; procProgress = 0
        let steps = ["距離・奥行きを実測中", "撮影角度とカメラ内部パラメータを取得中", "透視投影を逆算中", "肉眼の比率へ再投影中"]
        Task {
            let work = Task.detached(priority: .userInitiated) {
                try? Corrector.shared.run(snap, pull: pull, level: level)
            }
            for (i, msg) in steps.enumerated() {
                procMessage = msg
                procProgress = Double(i) / Double(steps.count)
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
            let r = await work.value
            procProgress = 1
            guard let r else { toast = "補正に失敗しました"; phase = .scan; return }
            before = snap.beforeImage; after = r.0; infoText = r.1.text
            phase = .result
        }
    }

    func retake() {
        phase = .scan; reticle = nil; distance = nil; thickness = nil; ar.targetWorld = nil
    }

    func savePhoto(_ img: UIImage?) {
        guard let img else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else {
                Task { @MainActor in self.toast = "写真への保存が許可されていません" }; return
            }
            PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.creationRequestForAsset(from: img) }) { ok, _ in
                Task { @MainActor in self.toast = ok ? "写真に保存しました" : "保存に失敗しました" }
            }
        }
    }

    func composite() -> UIImage? {
        guard let b = before, let a = after else { return nil }
        let h = max(b.size.height, a.size.height)
        let wb = b.size.width * h / b.size.height, wa = a.size.width * h / a.size.height
        return UIGraphicsImageRenderer(size: CGSize(width: wb + wa, height: h)).image { _ in
            b.draw(in: CGRect(x: 0, y: 0, width: wb, height: h))
            a.draw(in: CGRect(x: wb, y: 0, width: wa, height: h))
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: h / 32), .foregroundColor: UIColor.white,
                                                        .strokeColor: UIColor.black, .strokeWidth: -3]
            "補正前".draw(at: CGPoint(x: 24, y: 24), withAttributes: attrs)
            "補正後".draw(at: CGPoint(x: wb + 24, y: 24), withAttributes: attrs)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        ZStack {
            switch m.phase {
            case .scan: ScanView()
            case .processing: ProcessingView()
            case .result: ResultView()
            }
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .top) {
            if let t = m.toast {
                Text(t).font(.footnote).padding(10).background(.ultraThinMaterial, in: Capsule()).padding(.top, 60)
                    .task { try? await Task.sleep(nanoseconds: 2_500_000_000); m.toast = nil }
            }
        }
    }
}

struct ScanView: View {
    @EnvironmentObject var m: AppModel
    var hud: String {
        guard let d = m.distance else {
            if m.selfie { return "顔をカメラに向けてください" }
            return m.progress < 1 ? "スマホをゆっくり動かして周囲をスキャン" : "補正したい顔・物体をタップ"
        }
        var s = String(format: "距離 %.2f m", d)
        if let t = m.thickness { s += String(format: " ・ 奥行き %.0f cm(実測)", t * 100) } else { s += " ・ 奥行き: 計測不可" }
        return s + String(format: "\n仰角 %.0f° ・ 傾き %.0f°", m.elevation, m.roll)
    }
    var body: some View {
        ZStack {
            ARContainer(controller: m.ar).ignoresSafeArea()
            if let p = m.reticle, let d = m.distance {
                VStack(spacing: 4) {
                    Circle().stroke(Color.yellow, lineWidth: 3).frame(width: 64, height: 64)
                    Text(String(format: "%.2f m", d)).font(.caption.bold()).foregroundColor(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Color.yellow, in: Capsule())
                }
                .position(x: p.x, y: p.y + 20).allowsHitTesting(false)
            }
            VStack(spacing: 10) {
                HStack {
                    Text(m.progress >= 1 ? "スキャン完了" : "スキャン \(Int(m.progress * 100))%").font(.caption)
                        .padding(8).background(.ultraThinMaterial, in: Capsule())
                    ProgressView(value: m.progress).tint(.cyan)
                    if m.faceSupported {
                        Button(m.selfie ? "背面" : "自撮り") { m.toggleSelfie() }
                            .font(.caption).padding(8).background(.ultraThinMaterial, in: Capsule())
                    }
                }.padding(.horizontal)
                Spacer()
                VStack(spacing: 8) {
                    Text(hud).font(.caption).multilineTextAlignment(.center)
                    HStack { Text("視点を引く").font(.caption); Slider(value: $m.pull, in: 1...4)
                        Text(String(format: "×%.1f", m.pull)).font(.caption.monospacedDigit()) }
                    HStack { Text("水平補正").font(.caption); Slider(value: $m.level, in: 0...1)
                        Text("\(Int(m.level * 100))").font(.caption.monospacedDigit()) }
                    Button { m.capture() } label: {
                        Circle().fill(.white).frame(width: 68, height: 68)
                            .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 5).frame(width: 78, height: 78))
                    }
                    .disabled(m.reticle == nil).opacity(m.reticle == nil ? 0.35 : 1)
                }
                .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal).padding(.bottom, 8)
            }
        }
    }
}

struct ProcessingView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(spacing: 18) {
            ProgressView().scaleEffect(2).tint(.cyan)
            Text(m.procMessage).font(.headline)
            ProgressView(value: m.procProgress).frame(width: 260).tint(.cyan)
            Text("補正中…そのままお待ちください").font(.caption).foregroundColor(.secondary)
        }
    }
}

struct ResultView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(spacing: 10) {
            if let b = m.before, let a = m.after { CompareView(before: b, after: a) }
            Text(m.infoText).font(.caption2).foregroundColor(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("補正後を保存") { m.savePhoto(m.after) }.buttonStyle(.borderedProminent)
                Button("比較画像を保存") { m.savePhoto(m.composite()) }.buttonStyle(.bordered)
                Button("撮り直す") { m.retake() }.buttonStyle(.bordered)
            }
        }.padding()
    }
}

struct CompareView: View {
    let before: UIImage, after: UIImage
    @State private var pos: CGFloat = 0.5
    var body: some View {
        GeometryReader { g in
            ZStack {
                Image(uiImage: before).resizable().scaledToFit().frame(width: g.size.width, height: g.size.height)
                Image(uiImage: after).resizable().scaledToFit().frame(width: g.size.width, height: g.size.height)
                    .mask(alignment: .trailing) { Rectangle().frame(width: g.size.width * (1 - pos)) }
                Rectangle().fill(.white).frame(width: 2).position(x: g.size.width * pos, y: g.size.height / 2)
                HStack { label("補正前"); Spacer(); label("補正後") }.frame(maxHeight: .infinity, alignment: .top).padding(8)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { pos = min(1, max(0, $0.location.x / g.size.width)) })
        }
    }
    func label(_ t: String) -> some View {
        Text(t).font(.caption).padding(.horizontal, 8).padding(.vertical, 3).background(.black.opacity(0.6), in: Capsule())
    }
}
