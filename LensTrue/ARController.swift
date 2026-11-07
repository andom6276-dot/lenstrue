import ARKit
import RealityKit
import SwiftUI
import CoreImage

/// 撮影の瞬間に必要なデータをまとめたもの(Metal 側へ渡す)
struct Snapshot: @unchecked Sendable {
    let cg: CGImage
    let Ws: Int, Hs: Int
    let fx: Float, fy: Float, cx: Float, cy: Float   // ARKit 実測の内部パラメータ(px)
    let up: SIMD3<Float>          // 世界の上方向。画像座標系(x右・y下・z前)
    let target: SIMD2<Float>      // 撮影画像上の対象ピクセル
    let zt: Float                 // 対象の z 深度(m)
    let depth: [Float16]?         // LiDAR 深度(nil = 非搭載)
    let dw: Int, dh: Int
    let beforeImage: UIImage
    let depthLabel: String
}

struct DepthMap {
    let v: [Float]; let w: Int; let h: Int   // 無効値は -1

    static func from(_ frame: ARFrame) -> DepthMap? {
        guard let dd = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let db = dd.depthMap
        CVPixelBufferLockBaseAddress(db, .readOnly); defer { CVPixelBufferUnlockBaseAddress(db, .readOnly) }
        let w = CVPixelBufferGetWidth(db), h = CVPixelBufferGetHeight(db)
        guard let dbase = CVPixelBufferGetBaseAddress(db) else { return nil }
        let dbpr = CVPixelBufferGetBytesPerRow(db)
        var cbase: UnsafeMutableRawPointer?; var cbpr = 0
        let cb = dd.confidenceMap
        if let cb { CVPixelBufferLockBaseAddress(cb, .readOnly); cbase = CVPixelBufferGetBaseAddress(cb); cbpr = CVPixelBufferGetBytesPerRow(cb) }
        defer { if let cb { CVPixelBufferUnlockBaseAddress(cb, .readOnly) } }
        var out = [Float](repeating: -1, count: w * h)
        for y in 0..<h {
            let row = (dbase + y * dbpr).assumingMemoryBound(to: Float32.self)
            let crow = cbase.map { ($0 + y * cbpr).assumingMemoryBound(to: UInt8.self) }
            for x in 0..<w {
                let z = row[x]; let c = crow?[x] ?? 2
                if z.isFinite && z > 0.1 && z < 8 && c >= 1 { out[y * w + x] = z }   // 低信頼度は無効扱い
            }
        }
        return DepthMap(v: out, w: w, h: h)
    }

    /// ソース画像の (px,py) 周辺の有効深度を昇順で返す
    func window(_ px: Float, _ py: Float, srcW: Int, srcH: Int, r: Int) -> [Float] {
        let cx = min(w - 1, max(0, Int(px * Float(w) / Float(srcW)))), cy = min(h - 1, max(0, Int(py * Float(h) / Float(srcH))))
        var a: [Float] = []
        for y in max(0, cy - r)...min(h - 1, cy + r) { for x in max(0, cx - r)...min(w - 1, cx + r) {
            let z = v[y * w + x]; if z > 0 { a.append(z) } } }
        return a.sorted()
    }
}

extension simd_float4x4 { var translation: SIMD3<Float> { SIMD3(columns.3.x, columns.3.y, columns.3.z) } }

@MainActor
final class ARController: NSObject, ARSessionDelegate {
    let view = ARView(frame: .zero)
    weak var model: AppModel?
    var targetWorld: SIMD3<Float>?
    let lidar = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    private var started = false
    var selfie = false
    private var lastPos: SIMD3<Float>?
    private var travel: Float = 0
    private var frameCount = 0
    private let ci = CIContext()

    override init() {
        super.init()
        view.automaticallyConfigureSession = false
        view.session.delegate = self
        if lidar { view.debugOptions.insert(.showSceneUnderstanding) }   // 計測アプリ風のメッシュ表示
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    func start() {
        guard !started else { return }
        started = true
        setMode(selfie: false)
    }

    /// 背面(LiDAR/平面近似) と 前面(TrueDepth) の切り替え
    func setMode(selfie on: Bool) {
        selfie = on; targetWorld = nil; travel = 0
        let c: ARConfiguration
        if on {
            c = ARFaceTrackingConfiguration()
        } else {
            let w = ARWorldTrackingConfiguration()
            if lidar { w.sceneReconstruction = .mesh }
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) { w.frameSemantics.insert(.smoothedSceneDepth) }
            else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { w.frameSemantics.insert(.sceneDepth) }
            c = w
        }
        view.debugOptions = (lidar && !on) ? [.showSceneUnderstanding] : []
        view.session.run(c, options: [.resetTracking, .removeExistingAnchors])
    }

    // MARK: 世界の上方向を画像座標系(x右・y下・z前)で返す
    nonisolated static func upImage(_ cam: ARCamera) -> SIMD3<Float> {
        let t = cam.transform
        let r = simd_float3x3(SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z),
                              SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z),
                              SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z))
        let up = r.transpose * SIMD3<Float>(0, 1, 0)
        return SIMD3(up.x, -up.y, -up.z)
    }

    /// (仰角°, 傾き°)。傾きは最寄りの画像軸からのずれ(縦横持ちどちらでも同じ意味)
    nonisolated static func angles(_ cam: ARCamera) -> (Float, Float) {
        let u = upImage(cam)
        let ele = asin(max(-1, min(1, u.z))) * 180 / .pi
        var a = atan2(u.x, -u.y) * 180 / .pi
        a -= (a / 90).rounded() * 90
        return (ele, a)
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let t = frame.camera.transform
        let pos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let mesh = frame.anchors.filter { $0 is ARMeshAnchor }.count
        let a = ARController.angles(frame.camera)
        var face: SIMD3<Float>? = nil; var thick: Float? = nil
        if let fa = frame.anchors.first(where: { $0 is ARFaceAnchor }) as? ARFaceAnchor, fa.isTracked {
            face = fa.transform.translation
            thick = FaceDepth.thickness(frame.camera, fa)
        }
        Task { @MainActor in self.handle(pos: pos, mesh: mesh, ele: a.0, roll: a.1, face: face, thick: thick) }
    }

    private func handle(pos: SIMD3<Float>, mesh: Int, ele: Float, roll: Float, face: SIMD3<Float>?, thick: Float?) {
        guard let m = model else { return }
        if let lp = lastPos { travel += simd_distance(pos, lp) }
        lastPos = pos
        frameCount += 1
        guard frameCount % 2 == 0 else { return }
        if selfie {                                   // 自撮り: 顔を自動で対象にする(スキャン不要)
            targetWorld = face; m.thickness = thick; m.progress = 1
        } else {
            m.progress = Double(max(min(Float(mesh) / 10, 1), min(travel / 1.5, 1)))
        }
        m.elevation = ele; m.roll = roll
        if let w = targetWorld { m.reticle = view.project(w); m.distance = simd_distance(pos, w) }
        else { m.reticle = nil; m.distance = nil }
    }

    // MARK: タップで対象を選ぶ → 世界座標に固定
    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let frame = view.session.currentFrame, let m = model, !selfie else { return }
        let pt = g.location(in: view)
        let orient = view.window?.windowScene?.interfaceOrientation ?? .portrait
        let tr = frame.displayTransform(for: orient, viewportSize: view.bounds.size)
        let n = CGPoint(x: pt.x / view.bounds.width, y: pt.y / view.bounds.height).applying(tr.inverted())
        let res = frame.camera.imageResolution, K = frame.camera.intrinsics
        let px = Float(n.x * res.width), py = Float(n.y * res.height)
        let sw = Int(res.width), sh = Int(res.height)
        let dm = DepthMap.from(frame)

        var world: SIMD3<Float>?
        if let dm {
            let a = dm.window(px, py, srcW: sw, srcH: sh, r: 2)
            if a.count >= 3 {
                let z = a[a.count / 2]
                let pc = SIMD4<Float>((px - K[2][0]) / K[0][0] * z, -((py - K[2][1]) / K[1][1] * z), -z, 1)
                let w4 = frame.camera.transform * pc
                world = SIMD3(w4.x, w4.y, w4.z)
            }
        }
        if world == nil, let hit = view.raycast(from: pt, allowing: .estimatedPlane, alignment: .any).first {
            world = hit.worldTransform.translation      // LiDAR なし/深度欠損時のフォールバック
        }
        guard let w = world else { m.toast = "距離を取得できませんでした。別の場所をタップしてください"; return }
        targetWorld = w

        // 対象まわり 約15cm 半径の深度分布から奥行きを実測
        let pcam = frame.camera.transform.inverse * SIMD4<Float>(w.x, w.y, w.z, 1)
        let zc = max(0.1, -pcam.z)
        m.thickness = nil
        if let dm {
            let r = Int(max(2, K[0][0] * 0.15 / zc * Float(dm.w) / Float(sw)))
            let a = dm.window(px, py, srcW: sw, srcH: sh, r: r)
            if a.count >= 8 { m.thickness = a[Int(Float(a.count - 1) * 0.9)] - a[Int(Float(a.count - 1) * 0.1)] }
        }
    }

    // MARK: 撮影
    func snapshot() -> Snapshot? {
        guard let frame = view.session.currentFrame, let w = targetWorld else { return nil }
        let cam = frame.camera, res = cam.imageResolution, K = cam.intrinsics
        let ciImg = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let cg = ci.createCGImage(ciImg, from: ciImg.extent) else { return nil }
        let p = cam.projectPoint(w, orientation: .landscapeRight, viewportSize: res)
        let pc = cam.transform.inverse * SIMD4<Float>(w.x, w.y, w.z, 1)
        let zt = -pc.z
        guard zt > 0.1 else { return nil }
        let up = ARController.upImage(cam)
        var d16: [Float16]? = nil; var dw = 2, dh = 2; var label = "深度: 平面近似"
        if selfie, let fa = frame.anchors.first(where: { $0 is ARFaceAnchor }) as? ARFaceAnchor, let fd = FaceDepth.render(cam, fa) {
            d16 = fd.0; dw = fd.1; dh = fd.2; label = "深度: TrueDepth 実測(顔)・頭部と背景は仮定"
        } else if let dm = DepthMap.from(frame) {
            dw = dm.w; dh = dm.h; d16 = dm.v.map { $0 > 0 ? Float16($0) : Float16(10) }; label = "深度: LiDAR 実測"
        }
        let orient: UIImage.Orientation = abs(up.x) > abs(up.y) ? (up.x < 0 ? .right : .left) : (up.y < 0 ? .up : .down)
        return Snapshot(cg: cg, Ws: Int(res.width), Hs: Int(res.height), fx: K[0][0], fy: K[1][1], cx: K[2][0], cy: K[2][1],
                        up: up, target: SIMD2(Float(p.x), Float(p.y)), zt: zt, depth: d16, dw: dw, dh: dh,
                        beforeImage: UIImage(cgImage: cg, scale: 1, orientation: orient), depthLabel: label)
    }
}

/// TrueDepth の顔メッシュから深度マップを作る(顔=実測、頭部まわり=仮定、背景=遠景の仮定)
enum FaceDepth {
    /// 顔メッシュ頂点を画像座標系(x右・y下・z前)のカメラ座標へ
    static func verts(_ cam: ARCamera, _ fa: ARFaceAnchor) -> [SIMD3<Float>] {
        let m = cam.transform.inverse * fa.transform
        return fa.geometry.vertices.map { v in
            let p = m * SIMD4<Float>(v.x, v.y, v.z, 1)
            return SIMD3(p.x, -p.y, -p.z)
        }
    }

    static func thickness(_ cam: ARCamera, _ fa: ARFaceAnchor) -> Float? {
        let zs = verts(cam, fa).map { $0.z }
        guard let lo = zs.min(), let hi = zs.max(), lo > 0 else { return nil }
        return hi - lo
    }

    static func render(_ cam: ARCamera, _ fa: ARFaceAnchor) -> ([Float16], Int, Int)? {
        let res = cam.imageResolution, K = cam.intrinsics
        let W = Float(res.width), H = Float(res.height)
        let dw = 256, dh = max(2, Int(256 * H / W))
        let sx = Float(dw) / W, sy = Float(dh) / H
        let v3 = verts(cam, fa)
        guard !v3.isEmpty, v3.allSatisfy({ $0.z > 0.05 }) else { return nil }
        let pts: [SIMD3<Float>] = v3.map { v in
            SIMD3((K[2][0] + K[0][0] * v.x / v.z) * sx, (K[2][1] + K[1][1] * v.y / v.z) * sy, v.z)
        }
        var buf = [Float](repeating: .infinity, count: dw * dh)
        let idx = fa.geometry.triangleIndices
        var t = 0
        while t + 2 < idx.count {
            let a = pts[Int(idx[t])], b = pts[Int(idx[t + 1])], c = pts[Int(idx[t + 2])]
            t += 3
            let minX = max(0, Int(min(a.x, b.x, c.x).rounded(.down))), maxX = min(dw - 1, Int(max(a.x, b.x, c.x).rounded(.up)))
            let minY = max(0, Int(min(a.y, b.y, c.y).rounded(.down))), maxY = min(dh - 1, Int(max(a.y, b.y, c.y).rounded(.up)))
            if minX > maxX || minY > maxY { continue }
            let den = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
            if abs(den) < 1e-6 { continue }
            for y in minY...maxY { for x in minX...maxX {
                let px = Float(x) + 0.5, py = Float(y) + 0.5
                let l1 = ((b.y - c.y) * (px - c.x) + (c.x - b.x) * (py - c.y)) / den
                let l2 = ((c.y - a.y) * (px - c.x) + (a.x - c.x) * (py - c.y)) / den
                let l3 = 1 - l1 - l2
                if l1 < 0 || l2 < 0 || l3 < 0 { continue }
                let z = l1 * a.z + l2 * b.z + l3 * c.z
                if z < buf[y * dw + x] { buf[y * dw + x] = z }
            } }
        }
        // メッシュの外側: 頭部〜肩は顔の少し後ろ、さらに外は遠景と仮定してなめらかにつなぐ
        let zMean = v3.map { $0.z }.reduce(0, +) / Float(v3.count)
        let xs = pts.map { $0.x }, ys = pts.map { $0.y }
        let cxg = xs.reduce(0, +) / Float(xs.count), cyg = ys.reduce(0, +) / Float(ys.count)
        let rad = max(4, max(xs.max()! - xs.min()!, ys.max()! - ys.min()!) / 2)
        let head = zMean + 0.08, far = zMean + 1.2
        var out = [Float16](repeating: 0, count: dw * dh)
        for y in 0..<dh { for x in 0..<dw {
            var z = buf[y * dw + x]
            if !z.isFinite {
                let r = hypot(Float(x) - cxg, Float(y) - cyg) / rad
                let k = min(1, max(0, (r - 1.8) / 1.4))
                z = head * (1 - k) + far * k
            }
            out[y * dw + x] = Float16(z)
        } }
        return (out, dw, dh)
    }
}

struct ARContainer: UIViewRepresentable {
    let controller: ARController
    func makeUIView(context: Context) -> ARView { controller.start(); return controller.view }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
