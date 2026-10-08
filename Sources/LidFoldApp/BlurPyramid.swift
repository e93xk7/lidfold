import CoreImage
import CoreGraphics
import Foundation

/// 預先算好的幾張模糊圖（白皮書 D3）。
///
/// 即時對 3K 圖做高斯模糊會掉幀，所以闔蓋當下只拍一張清晰的，
/// 模糊版在背景算，算好再換上去。動畫本身只做遮罩與透明度混合。
final class BlurPyramid {

    /// 模糊半徑（點）。由淺到深。
    static let radii: [Double] = [10, 28]

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    let sharp: CGImage
    private(set) var blurred: [CGImage] = []

    init(sharp: CGImage) {
        self.sharp = sharp
    }

    /// 在背景算模糊。算好後回到主執行緒呼叫 `completion`。
    func computeBlurs(scale: Double, completion: @escaping ([CGImage]) -> Void) {
        let image = sharp
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = ProcessInfo.processInfo.systemUptime
            let ci = CIImage(cgImage: image)
            // 先把邊緣往外延伸，不然模糊之後四周會透出去。
            let clamped = ci.clampedToExtent()
            var results: [CGImage] = []
            for r in Self.radii {
                guard let filter = CIFilter(name: "CIGaussianBlur") else { continue }
                filter.setValue(clamped, forKey: kCIInputImageKey)
                filter.setValue(r * scale, forKey: kCIInputRadiusKey)
                guard let out = filter.outputImage,
                      let cg = Self.context.createCGImage(out, from: ci.extent) else { continue }
                results.append(cg)
            }
            let ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
            DispatchQueue.main.async {
                Log.write(String(format: "模糊 %d 張算完，%.0f ms", results.count, ms))
                completion(results)
            }
        }
    }
}
