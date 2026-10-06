import Foundation
import QuartzCore

/// Render 層的幾何（白皮書 2.2、5.4）。純數學，可以單獨驗算。
///
/// ## 座標系
///
/// 世界座標以**轉軸中點**為原點（轉軸 = 螢幕下緣，在機器背面）：
/// - X：往右
/// - Y：往使用者的方向（水平往前）
/// - Z：往上
///
/// 上蓋角度 θ 從 0°（完全闔上，螢幕朝下貼著鍵盤）量到約 115°（平常使用，向後仰）。
/// 螢幕平面沿著「從轉軸往螢幕上緣」的方向是
///
///     u(θ) = (0, cos θ, sin θ)
///
/// θ=0 時 u 指向使用者（上蓋蓋在鍵盤上），θ=90° 時 u 朝正上方。
/// 螢幕法線（面向使用者那一面）是
///
///     n(θ) = (0, sin θ, −cos θ)
///
/// ## 要做什麼
///
/// 內容要看起來釘在「上蓋還在 θ_open 時那塊平面」上。所以螢幕上每一點 P，
/// 要畫的是「從眼睛 E 穿過 P 的那條線，打到虛擬平面上那一點」的顏色。
/// 這是透視投影（單應變換），不是把畫面反向轉 Δθ 而已。
///
/// 用 CATransform3D 表達就是：**先把圖層繞轉軸轉回 Δθ，再從眼睛的位置做透視投影。**
/// `m34` 的透視中心固定在圖層座標的 z 軸上，所以要先把眼睛平移到 z 軸、投影、再平移回去。
public enum Projection {

    /// 眼睛在世界座標的位置，單位公分。
    public struct Eye {
        /// 轉軸正前方多遠。
        public var forward: Double
        /// 轉軸上方多高。
        public var up: Double

        public init(forward: Double = Tuning.eyeForwardCm, up: Double = Tuning.eyeUpCm) {
            self.forward = forward
            self.up = up
        }
    }

    /// 眼睛在「螢幕自己的座標系」裡的位置（原點在轉軸中點）。
    ///
    /// - Returns: `(alongScreen, outward)`，單位公分。
    ///   `alongScreen` = 沿著螢幕表面往上緣的距離，`outward` = 離開螢幕表面的距離。
    ///   `outward` 就是透視投影的視距 d；它隨著上蓋闔上而變小，
    ///   小到 0 代表眼睛正好落在螢幕平面上（完全看不到畫面了）。
    public static func eyeInScreenFrame(theta: Double, eye: Eye) -> (alongScreen: Double, outward: Double) {
        let t = theta * .pi / 180
        return (eye.forward * cos(t) + eye.up * sin(t),
                eye.forward * sin(t) - eye.up * cos(t))
    }

    /// 這個角度下，眼睛還看得到螢幕嗎。
    public static func isVisible(theta: Double, eye: Eye) -> Bool {
        eyeInScreenFrame(theta: theta, eye: eye).outward > Tuning.minEyeDistanceCm
    }

    /// 給覆蓋窗圖層用的變換。
    ///
    /// - Parameters:
    ///   - theta: 上蓋目前角度（度）。
    ///   - thetaOpen: 這次闔蓋的起始角度（度）＝ 虛擬平面的位置。
    ///   - pixelsPerCm: 螢幕每公分幾個點（用 NSScreen 的尺寸算）。
    ///   - eye: 眼睛位置。
    /// - Returns: 設給圖層的 `transform`。圖層的 anchorPoint 要在下緣中點（轉軸）。
    ///   - bezelPixels: 轉軸到「顯示區下緣」的距離（點）。圖層的 y=0 在顯示區下緣，
    ///     但旋轉軸在轉軸上，中間隔著下邊框，差這一段幾何就會歪。
    public static func transform(theta: Double, thetaOpen: Double,
                                 pixelsPerCm: Double, bezelPixels: Double = 0,
                                 eye: Eye = Eye()) -> CATransform3D {
        let delta = (thetaOpen - theta) * .pi / 180
        let e = eyeInScreenFrame(theta: theta, eye: eye)

        // 視距太小（眼睛快貼到螢幕平面）時透視會爆掉。夾住，剩下的交給 M4 的模糊變暗蓋掉。
        let d = max(e.outward, Tuning.minEyeDistanceCm) * pixelsPerCm
        let ey = e.alongScreen * pixelsPerCm   // 眼睛在螢幕座標裡的高度（沿著螢幕往上）
        let ex = 0.0                           // 假設眼睛在正中間

        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / d

        // CA 用列向量，CATransform3DConcat(a, b) = 先 a 再 b。
        // 順序：繞轉軸轉 −Δθ → 把眼睛平移到 z 軸 → 透視 → 平移回去。
        //
        // 轉 **−Δθ**：虛擬平面比現在的螢幕更向後仰，所以在螢幕自己的座標系裡，
        // 它的上緣是往遠離眼睛的方向（−z）倒。寫成 +Δθ 的話內容會往反方向跑，
        // 錯覺完全不成立 —— 一開始就是寫錯邊，用 worldPointSeen 驗出來的。
        let rotate = CATransform3DMakeRotation(-delta, 1, 0, 0)
        let toAxis = CATransform3DMakeTranslation(-ex, -ey, 0)
        let back = CATransform3DMakeTranslation(ex, ey, 0)

        // 圖層座標 → 轉軸座標（往上挪過下邊框）→ 投影 → 再挪回圖層座標。
        let toHinge = CATransform3DMakeTranslation(0, bezelPixels, 0)
        let fromHinge = CATransform3DMakeTranslation(0, -bezelPixels, 0)

        let projected = CATransform3DConcat(
            CATransform3DConcat(rotate, toAxis),
            CATransform3DConcat(perspective, back))

        return CATransform3DConcat(CATransform3DConcat(toHinge, projected), fromHinge)
    }

    /// 驗算用：把螢幕上的一點，依這個變換投影到虛擬平面，回傳世界座標。
    ///
    /// 不是繪圖路徑，是拿來檢查幾何對不對的 —— 同一點在不同 θ 下算出來的世界座標
    /// 應該幾乎一樣（那就代表「內容真的沒動」）。
    ///
    /// - Parameters:
    ///   - screenPoint: 螢幕上的點，單位公分，原點在轉軸中點，y 往螢幕上緣。
    public static func worldPointSeen(screenPoint: (x: Double, y: Double),
                                      theta: Double, thetaOpen: Double,
                                      eye: Eye = Eye()) -> (x: Double, y: Double, z: Double)? {
        let t = theta * .pi / 180
        let u = (0.0, cos(t), sin(t))
        // 螢幕上那一點的世界座標。
        let p = (screenPoint.x, screenPoint.y * u.1, screenPoint.y * u.2)
        let e = (0.0, eye.forward, eye.up)

        // 虛擬平面：通過原點、法線是 n(θ_open)。
        let to = thetaOpen * .pi / 180
        let n = (0.0, sin(to), -cos(to))

        let dir = (p.0 - e.0, p.1 - e.1, p.2 - e.2)
        let denom = dir.1 * n.1 + dir.2 * n.2
        guard abs(denom) > 1e-9 else { return nil }
        let s = -(e.1 * n.1 + e.2 * n.2) / denom
        guard s > 0 else { return nil }   // 虛擬平面在眼睛後面
        return (e.0 + s * dir.0, e.1 + s * dir.1, e.2 + s * dir.2)
    }
}
