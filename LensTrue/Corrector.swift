import Metal
import MetalKit
import simd
import UIKit

struct CorrectionInfo { let text: String }

/// LiDAR 深度を使った再投影:
///  1. 重力方向から「水平な仮想カメラ」の姿勢を作る(撮影角度の逆算)
///  2. 仮想カメラを対象から遠ざけ(dolly)、焦点距離を上げて対象の大きさを保つ(透視の圧縮)
///  3. 出力画素ごとにレイを深度マップ上でレイマーチし、元画像の色を引く
final class Corrector {
    static let shared = Corrector()
    enum Err: Error { case metal }

    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var queue = device.makeCommandQueue()!
    private lazy var pso: MTLComputePipelineState = {
        let lib = try! device.makeLibrary(source: Corrector.msl, options: nil)
        return try! device.makeComputePipelineState(function: lib.makeFunction(name: "remap")!)
    }()

    func run(_ s: Snapshot, pull: Float, level: Float) throws -> (UIImage, CorrectionInfo) {
        // --- 1. 仮想カメラの基底(仮想→元カメラ座標) ---
        let U0 = simd_normalize(s.up)
        let axis: SIMD3<Float> = abs(U0.x) > abs(U0.y) ? SIMD3(U0.x < 0 ? -1 : 1, 0, 0) : SIMD3(0, U0.y < 0 ? -1 : 1, 0)
        var U = simd_normalize(axis * (1 - level) + U0 * level)
        let F0 = SIMD3<Float>(0, 0, 1)
        var fwd = F0 - simd_dot(F0, U) * U
        if simd_length(fwd) < 0.2 { U = axis; fwd = F0 }        // ほぼ真上/真下向き
        fwd = simd_normalize(fwd)
        let down = -U
        let right = simd_normalize(simd_cross(down, fwd))

        // --- 2. 出力サイズ(縦持ちなら縦画像)と dolly ---
        let portrait = abs(U0.x) > abs(U0.y)
        let Wo = portrait ? s.Hs : s.Ws, Ho = portrait ? s.Ws : s.Hs
        let f0 = (s.fx + s.fy) / 2
        let T = SIMD3<Float>((s.target.x - s.cx) / s.fx, (s.target.y - s.cy) / s.fy, 1) * s.zt
        let tz = max(0.1, simd_dot(fwd, T))
        let sf = max(1, pull)
        let dolly = tz * (sf - 1)
        let fo = f0 * sf                                         // 対象の見かけの大きさを保つ
        let o = -fwd * dolly

        let params: [Float] = [Float(Wo), Float(Ho), s.fx, s.fy, s.cx, s.cy, Float(s.Ws), Float(s.Hs),
                               fo, Float(Wo) / 2, Float(Ho) / 2, o.x, o.y, o.z,
                               right.x, right.y, right.z, down.x, down.y, down.z, fwd.x, fwd.y, fwd.z,
                               0 /* k1: ARKit 画像はピンホール扱い。必要なら AVCameraCalibrationData で追加 */, 10]

        // --- 3. Metal ---
        let loader = MTKTextureLoader(device: device)
        let src = try loader.newTexture(cgImage: s.cg, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
        let dArr = s.depth ?? [Float16](repeating: Float16(s.zt), count: 4)   // LiDAR なし: 対象距離の平面で近似
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: s.dw, height: s.dh, mipmapped: false)
        dd.usage = .shaderRead
        guard let dt = device.makeTexture(descriptor: dd) else { throw Err.metal }
        dArr.withUnsafeBytes { dt.replace(region: MTLRegionMake2D(0, 0, s.dw, s.dh), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: s.dw * 2) }
        let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: Wo, height: Ho, mipmapped: false)
        od.usage = [.shaderWrite, .shaderRead]; od.storageMode = .shared
        guard let dst = device.makeTexture(descriptor: od),
              let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { throw Err.metal }
        enc.setComputePipelineState(pso)
        enc.setTexture(src, index: 0); enc.setTexture(dt, index: 1); enc.setTexture(dst, index: 2)
        enc.setBytes(params, length: params.count * MemoryLayout<Float>.stride, index: 0)
        let tw = pso.threadExecutionWidth, th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreads(MTLSize(width: Wo, height: Ho, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()

        var px = [UInt8](repeating: 0, count: Wo * Ho * 4)
        dst.getBytes(&px, bytesPerRow: Wo * 4, from: MTLRegionMake2D(0, 0, Wo, Ho), mipmapLevel: 0)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let cg = px.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: Wo, height: Ho, bitsPerComponent: 8, bytesPerRow: Wo * 4, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let cg else { throw Err.metal }

        let ele = asin(max(-1, min(1, U0.z))) * 180 / .pi
        var roll = atan2(U0.x, -U0.y) * 180 / .pi; roll -= (roll / 90).rounded() * 90
        let text = String(format: "実距離 %.2f m → 仮想撮影距離 %.2f m ・ 仰角 %.0f° ・ 傾き %.0f° ・ %@",
                          tz, tz * sf, ele, roll, s.depthLabel)
        return (UIImage(cgImage: cg), CorrectionInfo(text: text))
    }

    static let msl = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void remap(texture2d<float, access::sample> src [[texture(0)]],
                      texture2d<float, access::sample> dep [[texture(1)]],
                      texture2d<float, access::write> dst [[texture(2)]],
                      constant float *p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
        uint Wo = (uint)p[0], Ho = (uint)p[1];
        if (gid.x >= Wo || gid.y >= Ho) return;
        float fx = p[2], fy = p[3], cx = p[4], cy = p[5];
        float2 S = float2(p[6], p[7]);
        float fo = p[8], cxo = p[9], cyo = p[10];
        float3 o = float3(p[11], p[12], p[13]);
        float3 rx = float3(p[14], p[15], p[16]);
        float3 ry = float3(p[17], p[18], p[19]);
        float3 rz = float3(p[20], p[21], p[22]);
        float k1 = p[23], zmax = p[24];
        constexpr sampler sl(filter::linear, address::clamp_to_edge);
        constexpr sampler sn(filter::nearest, address::clamp_to_edge);

        float3 dv = float3((gid.x + 0.5 - cxo) / fo, (gid.y + 0.5 - cyo) / fo, 1.0);
        float3 d = normalize(rx * dv.x + ry * dv.y + rz * dv.z);
        float4 col = float4(0, 0, 0, 1);
        if (d.z > 1e-3) {
            float t = max(0.0, (0.15 - o.z) / d.z);
            float tp = t;
            float2 last = float2(-1), hit = float2(-1);
            for (int i = 0; i < 300; i++) {
                float3 P = o + d * t;
                if (P.z > zmax) break;
                if (P.z > 0.05) {
                    float2 uv = float2(fx * P.x / P.z + cx, fy * P.y / P.z + cy);
                    if (uv.x >= 0 && uv.y >= 0 && uv.x < S.x && uv.y < S.y) {
                        last = uv;
                        float ds = dep.sample(sn, uv / S).r;
                        if (P.z >= ds) {                       // 深度面と交差
                            float a = tp, b = t;
                            for (int j = 0; j < 6; j++) {
                                float m = 0.5 * (a + b);
                                float3 Q = o + d * m;
                                float2 q = float2(fx * Q.x / Q.z + cx, fy * Q.y / Q.z + cy);
                                if (Q.z >= dep.sample(sn, q / S).r) b = m; else a = m;
                            }
                            float3 Q = o + d * b;
                            hit = float2(fx * Q.x / Q.z + cx, fy * Q.y / Q.z + cy);
                            break;
                        }
                    }
                }
                tp = t;
                t += max(0.008, 0.018 * max(P.z, 0.2));
            }
            float2 uv = hit.x >= 0 ? hit : last;                // 交差なし = 遠景として最後の点を採用
            if (uv.x >= 0) {
                float2 c = float2(cx, cy);
                float2 r = (uv - c) / float2(fx, fy);
                uv = c + (uv - c) * (1.0 + k1 * dot(r, r));
                col = src.sample(sl, uv / S);
                col.a = 1.0;
            }
        }
        dst.write(col, gid);
    }
    """
}
