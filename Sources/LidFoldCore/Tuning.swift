import Foundation

/// 所有可調參數集中在這裡（白皮書 8.1）。
/// 數值後面的註解寫清楚「為什麼是這個值」，M1 量到的就標 M1。
public enum Tuning {

    // MARK: - Signal 層

    /// 一階低通的 α（新樣本的權重）。
    ///
    /// M1 實測靜止雜訊峰對峰 0.05°、SD 0.011°，幾乎沒雜訊，所以不需要重平滑；
    /// 平滑得太重只會讓 10 Hz 的延遲更糟。白皮書先給的 0.5 太低。
    public static let alpha: Double = 0.8

    /// 角速度用最近幾次感測器更新做最小平方擬合。
    ///
    /// 白皮書 5.2 寫 3 個樣本，那是假設讀數很雜。M1 實測雜訊 SD 0.011°，
    /// 兩點差分的 ω 雜訊只有 ±0.2 °/s，遠小於 3 °/s 的死區，不需要多平均。
    /// 而 3 個樣本橫跨 200 ms，在起步那一刻會把靜止那段一起平均進來，
    /// ω 嚴重低估 → 插值先慢後猛追，單幀跳 6.9°。改成 2 點。
    public static let velocityWindow: Int = 2

    // MARK: - 狀態機

    /// 死區：|ω| 小於這個值算靜止，單位 °/s。
    ///
    /// M1：靜止雜訊 SD 0.011°、更新間隔 0.1 s → ω 的雜訊約 0.5 °/s，
    /// 所以 3 °/s 是 6σ，很安全。沿用白皮書的 3。
    public static let omegaDeadZone: Double = 3.0

    /// 單次更新就直接判定「在動」的門檻，單位 °/s。
    ///
    /// 偏離白皮書 5.2 的「持續 ≥ 2 個樣本」：感測器只有 10 Hz，等兩個樣本
    /// 要 200 ms，而 M1 實測快闔整段只有 760 ms —— 等於動畫開頭就吃掉 26%。
    /// 真正的闔蓋 ω 是 −42 至 −146 °/s，遠離雜訊（0.5 °/s），單次就夠可信。
    /// 介於 deadZone 與這個值之間的才需要第二個樣本確認。
    public static let omegaInstantTrigger: Double = 20.0

    /// 介於死區與 instantTrigger 之間時，要連續幾次更新才改狀態。
    public static let confirmUpdates: Int = 2

    /// θ 小於這個值算「已關」，單位度。
    ///
    /// M1：螢幕變黑時 θ_off = 0–6°，中位 2°。取最大值 6°，寧可早一點收：
    /// 收晚了螢幕已經黑、沒人看得到；收早了在 6° 以下才停，上蓋幾乎闔死，也看不出來。
    public static let thetaOff: Double = 6.0

    /// 超過這麼久沒有新的感測器更新，就視為 ω = 0（上蓋停住了）。
    /// 比更新週期（100 ms）長，免得在更新空檔誤判。
    public static let staleAfter: Double = 0.25

    /// 物理上可能的最大角速度，單位 °/s。超過的單筆讀數先扣住，
    /// 下一次更新確認了才採信（晚 100 ms，但擋掉假跳值）。
    ///
    /// M1 快闔的逐次跳幅是 16–19°/100 ms ≈ 190 °/s，所以 400 留了一倍多的餘裕。
    /// 實測過一次 114° → 接近 0° 再跳回來的假讀數，就是這個擋掉的。
    public static let maxPlausibleOmega: Double = 400.0

    /// report 7（0.01°）與 report 1（1°）差超過這麼多度，就當 report 7 這次讀壞了，
    /// 改用 report 1。兩個 report 來自同一顆感測器，正常只差不到 1°。
    public static let reportDisagreement: Double = 2.0

    /// 從「闔上中」回到「靜止」要停多久，單位秒。
    /// 比一次感測器更新（100 ms）長一點，免得在更新的空檔誤判成停下來。
    public static let stillHoldTime: Double = 0.25

    // MARK: - 插值（Render 要 60 fps，感測器只有 10 Hz）

    /// 感測器更新之間，用等速外推往前推最多這麼久，單位秒。
    ///
    /// 比更新週期（100 ms）多一點點，涵蓋更新抖動；再長就會在上蓋突然停住時過衝。
    public static let maxExtrapolation: Double = 0.12

    /// 臨界阻尼平滑的時間常數，單位秒。越小越跟手、越容易抖。
    /// 60 ms 約是感測器週期的一半：一次更新內收斂得完，又壓得住跳階。
    public static let smoothingTimeConstant: Double = 0.06

    // MARK: - Render 層的幾何

    /// 眼睛在轉軸正前方多遠，單位公分。白皮書給的預設值，M3 用眼睛調。
    public static let eyeForwardCm: Double = 45

    /// 眼睛在轉軸上方多高，單位公分。同上。
    public static let eyeUpCm: Double = 30

    // MARK: - 漸進模糊（gradient 模式，預設）

    /// 模糊前緣的柔邊寬度，螢幕高度的比例。越大過渡越軟。
    public static let sweepSoftness: Double = 0.45

    /// 相鄰兩層模糊之間，前緣錯開多少（螢幕高度比例）。
    /// 錯開才會出現「清晰 → 半糊 → 全糊」的連續層次。
    public static let sweepStagger: Double = 0.30

    /// 整體變暗的最大程度（白皮書 5.3：1 − 0.7·smoothstep）。
    public static let dimMax: Double = 0.7
    /// 從 p 多少開始變暗。
    public static let dimStart: Double = 0.45

    // MARK: - 透視投影（projection 模式，對照用）

    /// 投影強度。1 = 物理上精確（內容完全釘在空間裡），0 = 完全不動。
    ///
    /// M3 實測：1.0 幾何正確但畫面會放大到快 3 倍（闔 70° 時 1/cos70°），
    /// 看起來像「螢幕被拉長」而不是「內容待在原地」。單片平面螢幕上
    /// 物理正確不等於好看，所以留一個強度旋鈕，用 --strength 調。
    public static let projectionStrength: Double = 0.4

    /// 轉軸到顯示區下緣的距離（下邊框），單位公分。M3 量機器實體。
    public static let bezelBottomCm: Double = 1.0

    /// 闔到一半停住後，多久之內又繼續闔就當成同一次，單位秒。
    ///
    /// M3 第一次實測：Ian 一邊看一邊闔，中途會頓一下，每頓一次就重拍快照、
    /// 把虛擬平面重設到當下角度，畫面因此「跳」一下。沿用原本的虛擬平面才對 ——
    /// 內容本來就該釘在原處，不管中間停了幾次。
    public static let resumeGrace: Double = 2.5

    /// 續闔時允許的角度回彈，單位度。超過就是真的打開過了，要重新開始。
    public static let reopenTolerance: Double = 3.0

    /// 覆蓋窗最多顯示這麼久就強制關掉，單位秒。
    ///
    /// 安全網：覆蓋窗蓋滿整個螢幕，萬一狀態機漏掉收掉的時機（例如感測器卡住），
    /// 畫面會一直被一張舊快照蓋住。M1 實測最慢的一次闔蓋是 8.6 秒，所以 12 秒夠寬。
    public static let maxOverlaySeconds: Double = 12

    /// 視距（眼睛到螢幕平面的垂直距離）夾在這個下限，單位公分。
    /// 上蓋闔到一定程度後眼睛會落到螢幕平面上，透視投影在那裡會發散。
    public static let minEyeDistanceCm: Double = 8

    // MARK: - 感測器

    /// 輪詢頻率：靜止時省電，動起來後拉高（白皮書 5.1）。
    public static let idlePollHz: Double = 5
    public static let activePollHz: Double = 120
    /// 靜止多久之後降回 idlePollHz，單位秒。
    public static let idleAfter: Double = 2.0
}
