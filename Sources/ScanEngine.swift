import AVFoundation
import CoreImage
import UIKit
import Vision

/// 实验开关。界面上一排按钮直接拨这些值 —— 同一个包就能做 A/B，
/// 不用为了对比再出第二个包（iOS 出包一次约 20 分钟 + 10 倍计费）。
struct ScanFlags {
    /// 只认中间取景框（与正式端同宽 0.70）。关掉 = 全画面识别，用来对照安卓那边不裁的行为。
    var cropToScanSpan = true
    /// 面单检测（矩形）。关掉则绿框、对焦、预缩放、选镜头全部没输入。
    var labelDetect = true
    /// 对焦+测光打到面单中心。
    var focusOnLabel = true
    /// 连续两轮没读到就推一档近（**只在手动模式下起作用**，见 `continuous`）。
    var preZoom = true
    /// M4：按估计距离决定用超广角还是主摄。
    var lensSelect = true
    /// **连续扫码闭环**：面单进框 → 按占比瞬时推近 → 读到 → 保持 → 缓退回位 → 等下一件。
    ///
    /// 打开后 `preZoom` / `lensSelect` 自动让位（两套变焦逻辑同时在跑，倍率是谁改的都查不出来）。
    var continuous = false
    /// 放宽矩形检测门槛（置信度 0.5→0.3、四边形容忍 30→45）。
    ///
    /// 单独做成开关是为了**同一个包内 A/B**：2026-11-12 的 12 条记录里 11 条
    /// 「读到那一帧没有矩形」，但分不清是检测本身不行还是被这套门槛筛掉了。
    /// 拨一下就能对比，不用再出一个包。
    var relaxRect = false

    /// 面单检测改走 `VNDetectDocumentSegmentationRequest` —— 问的是「**这是不是一张纸**」
    /// 而不是「这是不是个长方形」。
    ///
    /// 2026-11-12 第 24/25 件就是矩形那一路认错的实证：框占 0.676 / 0.851（说明框得很大），
    /// 推近规则判「已经够大」一步没推，8~23 帧里一个码都没看见。**包裹的每一面都是长方形**，
    /// 长宽比 1.15~2.6、面积 ≤55% 一样过得了筛，矩形检测没有「纸」这个概念。
    /// 纸张分割是 ML 模型（训练集含 labels / receipts），跑在神经网络引擎上，**只返回一个结果**。
    ///
    /// 做成开关而不是两路并联：每帧已经 266ms 把 CPU 吃满，再加一路只会让两路都变慢，
    /// A/B 就不公平了（同【宽矩】的做法）。
    var paperDetect = false

    /// 界面上的缩写，写进 CSV。改开关顺序不要改这里 —— 这是数据的标签。
    var modeTag: String {
        [
            cropToScanSpan ? "裁" : "全",
            labelDetect ? "绿框" : "无框",
            focusOnLabel ? "对焦" : "不对焦",
            continuous ? "连续" : (preZoom ? "预缩放" : "无预缩"),
            lensSelect && !continuous ? "选镜" : "不选镜",
            labelDetect ? (paperDetect ? "纸框" : (relaxRect ? "宽矩" : "严矩")) : "",
        ].filter { !$0.isEmpty }.joined(separator: "/")
    }
}

struct ScanHit {
    let text: String
    let box: CGRect            // 画面归一化、原点左上
    let ms: Double             // 从【本件开始】起算；没有计时的件为 0
    let attempts: Int          // 中间失败了几轮
    let at: CFTimeInterval
    let confidence: Float?
    let distance: Double?
    let zoom: Double
    let camName: String
    let zoomBefore: Double
    let fillBefore: Double
    /// 读到那一刻的面单占比。**nil = 那一帧没检出矩形**（测不到，不是 0）。
    let fillAtHit: Double?
    let capped: Bool
    /// 这一件一共处理了几帧、其中几帧真的检出了面单框。见 `ScanMiss.frames`。
    let frames: Int
    let rectFrames: Int
    /// 这一件每一帧识码器看到了什么。见 `cycleBarcodeSummary`。
    let barcodes: String
    /// 这一件被格式闸丢掉的串（最多 3 个）。**有值 = 读到了，是被我们自己丢的。**
    let rejected: String
    /// 这一件的对焦状态。见 `cycleFocusSummary`。
    let focus: String
    /// 开件时那个绿框的「长边/短边」。**0 = 那一件压根没框住东西。**
    ///
    /// 2026-11-12 第 24/25 件占比 0.676/0.851：能不能被 `pickLabel` 的面积闸拦下，
    /// 取决于它的长宽比是多少（0.851 × 短边 ≤ 0.55 要长宽比 ≥1.55），而原来这一格没记 ——
    /// 「框错了」和「筛选没拦住」就分不清。
    let aspectBefore: Double
    /// 这一件里格式正确、且中心落在绿框内 / 框外的帧数。见 `cycleBoxSummary`。
    let codeInBox: String
}

/// 一件**没读出来**的记录。
///
/// 2026-11-12 需求方：「实际有两条面单没读出来」—— 而 CSV 里一条都没有，
/// 因为原来只记读到的。**失败的件才是要解释的东西**，抹掉之后表看着全绿、
/// 现场却是漏读，这种表最没用。
struct ScanMiss {
    let ms: Double
    let attempts: Int
    /// 这一件一共处理了几帧、其中几帧检出了面单框。
    /// **判据**：命中率在推近之后塌掉 = 放大把矩形框打没了；从头就低 = 检测本身不行。
    let frames: Int
    let rectFrames: Int
    let zoomBefore: Double
    let fillBefore: Double
    let capped: Bool
    let zoom: Double
    let camName: String
    /// 为什么结束：面单走了 / 超时 / 又按了一次【本件开始】。
    let reason: String
    /// 这一件每一帧识码器看到了什么。见 `cycleBarcodeSummary`。
    let barcodes: String
    /// 这一件被格式闸丢掉的串（最多 3 个）。**有值 = 读到了，是被我们自己丢的。**
    let rejected: String
    /// 这一件的对焦状态。见 `cycleFocusSummary`。
    let focus: String
    /// 开件时那个绿框的「长边/短边」。0 = 没框住东西。
    let aspectBefore: Double
    /// 这一件里格式正确、且中心落在绿框内 / 框外的帧数。见 `cycleBoxSummary`。
    let codeInBox: String
}

/// 每 0.2 秒推一次给界面的读数。只在主线程读写。
struct EngineStatus {
    var camName = "—"
    var format = "—"
    /// 送进来的画面尺寸（已按屏幕方向转过）。界面靠它算取景框在画面里的位置。
    var frameW: Double = 0
    var frameH: Double = 0
    var hFov: Double = 0
    var minFocusCM: Double = -1
    var zooms: String = "—"
    var displayZoom: Double = 1
    var decodeMs: Double = -1
    var labelConfidence: Float?
    /// 本帧检出的全部矩形：`个数: 面积/长宽比 …  → 选中的那个`
    var rectInfo: String = "—"
    /// 条码那一路检出的观察：`0 个` / `Code128` / `ITF14无正文`
    var barcodeInfo: String = "—"
    /// Vision 上一次 `perform` 抛的错。空 = 没抛。
    /// ⚠️ 与「没认出码」**必须分开显示**：前者是代码/输入有问题，后者是打法问题。
    var visionError: String = ""
    var distance: Double?
    var chosenLens: Double?
    var preZoomed = false
    var misses = 0
    var fps: Double = 0
    var message: String = ""

    // MARK: 连续扫
    /// 相位：等面单 / 推近读 / 保持 / 回退 / 等下一件。
    var phase: String = "—"
    /// 当前面单长边 ÷ 取景框边长。**这就是「推多少」的唯一输入**。
    var fill: Double = 0
    /// 本轮推到的倍率（已经是截断之后的）。
    var pushZoom: Double = 0
    /// 数码变焦的物理上限（传感器长边 ÷ 视频长边）。超过它全是插值。
    var ceiling: Double = 0
    /// 本轮是否被上限截住了。
    var capped = false
    /// 读到了但格式不对、被丢弃的串（空 = 没有）。
    var rejected: String = ""
    /// 这一件处理了几帧、其中几帧检出面单框。
    var cycleFrames = 0
    var cycleRectFrames = 0
}

protocol ScanEngineDelegate: AnyObject {
    func engine(_ engine: ScanEngine, didHit hit: ScanHit)
    /// 一件读不到就结束了。**必须上报** —— 否则 CSV 里只剩成功的那部分。
    func engine(_ engine: ScanEngine, didMiss miss: ScanMiss)
    /// 绿框（画面归一化、原点左上）；nil = 这一帧没看到面单。
    func engine(_ engine: ScanEngine, didSeeLabel box: CGRect?, confidence: Float?)
    /// 焦点十字该画在哪（画面归一化、原点左上）；nil = 不画。
    func engine(_ engine: ScanEngine, didMoveFocusTo point: CGPoint?)
    /// **送进 Vision 的那张图的缩略图**（每 0.5 秒一张）。
    /// 画出来是为了让「识码器到底看到什么」在屏幕上有证据 —— 不然「没读到码」
    /// 到底是图不对、还是图对了但太小，只能靠猜。
    func engine(_ engine: ScanEngine, didSeeVisionFrame image: UIImage?)
    func engine(_ engine: ScanEngine, didUpdate status: EngineStatus)
}

final class ScanEngine: NSObject {
    weak var delegate: ScanEngineDelegate?

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "scanlab.session")
    private let videoQueue = DispatchQueue(label: "scanlab.video")
    private let lock = NSLock()

    private var device: AVCaptureDevice?
    private var videoOutput: AVCaptureVideoDataOutput?

    // MARK: 只在锁里读写

    private var _flags = ScanFlags()
    private var _angle: CGFloat = 90
    /// 内部倍率 → 界面倍率。超广角=0.5 全靠它，取不到就当 1（显示倍率与内部倍率相等）。
    private var _multiplier: Double = 1
    /// 起不来时的原因。走锁：失败发生在 sessionQueue，读发生在 videoQueue。
    private var _failure = ""

    var flags: ScanFlags {
        get { lock.lock(); defer { lock.unlock() }; return _flags }
        set { lock.lock(); defer { lock.unlock() }; _flags = newValue }
    }
    var rotationAngle: CGFloat {
        get { lock.lock(); defer { lock.unlock() }; return _angle }
        set { lock.lock(); defer { lock.unlock() }; _angle = newValue }
    }
    var multiplier: Double {
        get { lock.lock(); defer { lock.unlock() }; return _multiplier }
        set { lock.lock(); defer { lock.unlock() }; _multiplier = newValue }
    }

    // MARK: 只在 videoQueue 里读写

    private var lastWork: CFTimeInterval = 0
    private var lastStatusAt: CFTimeInterval = 0
    private var lastFrameAt: CFTimeInterval = 0
    private var fps: Double = 0
    private var frameW: Double = 0
    private var frameH: Double = 0

    private var cycleStart: CFTimeInterval?
    private var attempts = 0
    private var misses = 0
    private var preZoomActive = false
    private var chosenLens: Double?
    private var lensVotes: [Double] = []
    private var smoothedBox: CGRect?
    private var smoothedConfidence: Float?
    private var lastLabelAt: CFTimeInterval = 0
    private var lastFocusPoint: CGPoint?
    private var lastDistance: Double?
    private var lastDecodeMs: Double = -1
    private var lastRectInfo = "—"
    private var lastBarcodeInfo = "—"
    private var lastVisionError = ""
    /// 最近一次「读到了但格式不对」的串。空 = 没有。**不许静默**：丢了一条真面单
    /// 和「没读到」在屏幕上长得一样的话，测出来的数就解释不了。
    private var lastRejected = ""
    private var lastThumbAt: CFTimeInterval = 0
    private var lastPayload = ""
    private var lastPayloadAt: CFTimeInterval = 0
    /// 本题处理帧数 / 其中检出面单框的帧数。开件时清零。
    private var cycleFrames = 0
    private var cycleRectFrames = 0
    /// 这一件的逐帧识码观察，三桶分开数。
    ///
    /// ⚠️ **这是把「读不到」定性唯一需要的三个数**。2026-11-12 那 7 件失败，
    /// 表里 19 列有 10 列是算出来的（`帧数` = 超时 ÷ 266ms、`倍率` = 占比反算…），
    /// 而识码器每一帧看到什么**一格都没记**。三种情况对应三种完全不同的病：
    /// - `无码` = 根本没看见码 → 对焦/模糊/角度/裁剪
    /// - `无正文` = 看见了解不出 → 清晰度或码制
    /// - `有码` = 解出了正文 → 那还读不到，就只可能是 `looksLikeWaybill` 丢的
    private var cycleNoBarcode = 0
    private var cycleNoPayload = 0
    private var cyclePayload = 0
    /// 第一个「看见码但没正文」的种类（`ITF14无正文`），空 = 没发生过。
    private var cycleNoPayloadKind = ""
    /// 被格式闸丢掉的串，最多留 3 个。
    private var cycleRejected: [String] = []
    /// 这一件有几帧 `isAdjustingFocus` 为真、以及最后一次的镜头位置。
    /// 镜头位置 0 = 无穷远、1 = 最近；一直是 0 就说明**根本没对到面单上**。
    private var cycleFocusHunting = 0
    private var cycleLensPosition: Double = -1
    /// 这一件里「格式正确且码中心在绿框内 / 在框外」的帧数。
    ///
    /// 记账从 0.1.11 起只认「码在框内」，所以**「外N」这一格是唯一的证据**：
    /// 它 > 0 就说明码读到了、是我们自己因为框不对不认 —— 那是定位的错，不是相机的错。
    private var cycleCodeIn = 0
    private var cycleCodeOut = 0
    /// 开件时那个绿框的长/短（0 = 没框）。见 `ScanHit.aspectBefore`。
    private var aspectBefore: Double = 0
    /// **检出那个框时**的界面倍率。
    ///
    /// 距离必须拿「框和倍率同一时刻」的两个数算。原来用当前的 `videoZoomFactor` 配
    /// 冻结的旧框：推近之后框不再更新（矩形丢了），倍率却已经是推后的 ——
    /// 算出来的距离正好偏大一个倍率。2026-11-12 的 271cm 就是这么来的。
    private var boxZoom: Double = 1.0

    // MARK: 连续扫的相位（只在 videoQueue 里读写）

    private enum Phase {
        case idle        // 等面单进框
        case seeking     // 已推近，等读到
        case holding     // 读到了，保持放大
        case restoring   // 缓退回原倍率
        case waitingNew  // 已回位，等这件离开
    }

    private var phase: Phase = .idle
    private var phaseAt: CFTimeInterval = 0
    /// 上一次「补一档」的时刻。进 `.seeking` 时归零。见 `seekBumpInterval`。
    private var lastBumpAt: CFTimeInterval = 0
    private var holdUntil: CFTimeInterval = 0
    private var restoreEndsAt: CFTimeInterval = 0
    /// 回位要退回到的倍率（界面口径）。**开一次会话定一次**，之后不跟着当前值漂。
    private var baseZoom: Double = 1.0
    private var zoomBefore: Double = 0
    private var fillBefore: Double = 0
    private var pushZoom: Double = 0
    private var cappedByCeiling = false
    /// 这一轮记下的那个单号。重臂时拿它跟当前读到的码比 —— **号码变了才算换了一件**。
    private var armedPayload = ""

    /// 识别间隔。正式端 0.3s；这里 0.25s —— 测的是「多久能读到」，粒度粗了量不准。
    static let workInterval: CFTimeInterval = 0.25
    /// 取景框边长占画面短边的比例。与正式端中档一致。
    static let scanSpan: CGFloat = 0.70
    /// 变焦速度（倍/秒）。与正式端 `zoomRampRate` 一致：0.5 档 = 0.5 秒，即「缓进缓退」。
    static let zoomRampRate: Float = 1.0
    /// 预缩放的目标：**让面单长边占到画面这一维的多少**。
    ///
    /// 不再用「乘 1.6」这种固定步长 —— 2026-11-07 真机量出来：80cm、1x 时面单只占 14%，
    /// 条码那一条在 1080 宽的画面里只剩 ~100 像素，Code 128 稳定解要 ≥160 像素。
    /// 乘 1.6 只推到 160，正好压在门槛上，等于没推。固定步长在**不知道距离**时没有意义。
    ///
    /// 0.5 是这么来的：面单占一半画面时，长 100mm 的条码 ≈ 1080×0.33 ≈ 350 像素，
    /// 约 4 像素/模块 —— 留了一倍余量。
    static let preZoomTargetFill: Double = 0.5
    /// 预缩放最多推到多少（界面倍率）。
    static let preZoomCeiling: Double = 4.0
    /// 推近的速度（倍/秒）。**故意比 [zoomRampRate] 快**：这段是「主动推近」，
    /// 不是录像开头那次缓动。1x→3.6x 用 3.0 只需 0.87 秒。
    static let preZoomRampRate: Float = 3.0

    // MARK: 连续扫的参数

    /// 推近的目标：**面单长边占取景框的比例**。
    ///
    /// 0.65 不是拍的，是两头夹出来的：
    /// - **下限 ~0.56** —— 160mm 面单要占框 56% 才能让 75mm 的条码到 200 像素
    ///   （Code128 约 120 个模块 × 1.7 像素）。低于这个数，推了也白推。
    /// - **上限 ~0.85** —— 80cm、2.1x 时面单正好占框 80%，只剩 4cm 抖动余量。
    ///   2026-10-22 正式端真机日志里「面单被推出框 → 回弹 → 又进来 → 再推」连转 5 轮，
    ///   就是推得太狠。
    ///
    /// 0.65 落在中间，上下各有 10~20% 余量。
    static let targetFill: Double = 0.65

    /// 读到之后**保持放大**多久再往回退。这是「录像开头一段面单特写」的长度。
    static let holdSeconds: CFTimeInterval = 2.0

    /// 面单要**看不见**多久才算这一件走了（下一件的入口）。
    ///
    /// 取 2.0 秒，与正式端 `absenceThreshold` 同一口径。原来写的 0.75 秒是错的：
    /// 2026-11-09 真机一个完全静止的包裹被记了 5 条 —— 矩形检测在静止面单上会抖，
    /// 抖一下 0.75 秒就过去了。**换件不算慢**：换件走的是「单号变了」那条路，立刻重臂，
    /// 这个 2 秒只管「同一件又回来了」。
    static let rearmAbsence: CFTimeInterval = 2.0

    /// 一直读不到就叫这一轮作废（面单还举着也认了 —— 总比卡在推近状态强）。
    static let seekTimeout: CFTimeInterval = 6.0

    /// 推过一次还读不到，隔多久再补一档。0.8 秒 ≈ 3 帧（实测每帧 251~267ms）。
    ///
    /// **这是推近的第二条理由，不依赖绿框准不准。** 第一条（按占比反算）只有在框真的
    /// 套在面单上时才成立；框在包裹上时占比是虚高的 —— 2026-11-12 第 24/25 件占比
    /// 0.676/0.851，规则判「已经够大」一步没推，8~23 帧一个码都没看见。
    /// 框不准不该让系统停在原地干等。
    static let seekBumpInterval: CFTimeInterval = 0.8
    /// 每补一档乘多少。1.0 起 4 档到 2.20（本机上限），走完约 3.2 秒 < 超时 6 秒。
    static let seekBumpFactor: Double = 1.35

    // MARK: - 生命周期

    func start() {
        LensMath.check().forEach { print("[ScanLab] 自检失败 \($0)") }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let found = Self.pickBackCamera() else {
                self.reportFailure("这台设备没有可用的后置相机")
                return
            }

            self.session.beginConfiguration()
            // ⚠️ 必须和正式端同一个档（正式端默认 1080P）。720P 的像素密度只有 1/2.25，
            // 同一张面单同样距离下条码模块的像素数不够 ⇒ **一个字都读不出来**，
            // 那就不是「慢」而是「零」，A/B 连基线都没有。2026-11-07 真机「全关也读不到」。
            self.session.sessionPreset = .hd1920x1080
            if !self.session.canSetSessionPreset(.hd1920x1080) {
                // 不静默降级：屏幕上得看得见这一条，否则测出来的是另一台机器的行为。
                self.reportFailure("这台设备设不上 1080P，分辨率不是正式端那一档")
            }

            do {
                let input = try AVCaptureDeviceInput(device: found)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                } else {
                    self.session.commitConfiguration()
                    self.reportFailure("加不上相机输入")
                    return
                }
            } catch {
                self.session.commitConfiguration()
                self.reportFailure("打开相机失败：\(error.localizedDescription)")
                return
            }

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: self.videoQueue)
            if self.session.canAddOutput(output) {
                self.session.addOutput(output)
            } else {
                self.session.commitConfiguration()
                self.reportFailure("加不上视频输出")
                return
            }

            self.session.commitConfiguration()
            self.device = found
            self.videoOutput = output

            let multiplier = Self.displayMultiplier(found)
            self.multiplier = multiplier

            self.configureDevice(found)
            self.applyRotation(self.rotationAngle)
            self.session.startRunning()

            // publishStatus 碰的都是 videoQueue 的私有状态，回到自己的队列上再推。
            self.videoQueue.async { self.publishStatus(force: true) }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// 屏幕方向变了。预览层与数据输出必须用**同一个角**，否则绿框和实际识别范围会错开。
    func setRotation(_ angle: CGFloat) {
        rotationAngle = angle
        applyRotation(angle)
    }

    private func applyRotation(_ angle: CGFloat) {
        scanLabApplyRotation(angle, to: videoOutput?.connection(with: .video))
    }

    private func configureDevice(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            // ⚠️ 不要锁帧率：锁了会把曝光时间压死，近距离反而更容易糊。
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
            }
            // ⚠️ `videoZoomFactor` 是**内部**口径：虚拟多摄上 1.0 是**超广角 0.5x**，
            // 内部 2.0 才是界面上的 1x（正式端 2026-10-20 真机点出来的，
            // 见 CameraSegmentRecorder.swift `displayZoomMultiplier` 那段）。
            // 这里直接写 1 等于一开机就把镜头推到最广 —— 面单在画面里只有一半大，
            // 条码模块的像素数跟着砍半。起步要和正式端一样是 1x。
            let startZoom = LensMath.toInternal(1.0, multiplier: multiplier)
            device.videoZoomFactor = min(
                max(startZoom, Double(device.minAvailableVideoZoomFactor)),
                Double(device.maxAvailableVideoZoomFactor))

            videoQueue.async { [weak self] in self?.baseZoom = 1.0 }
        } catch {
            reportFailure("相机参数设不上：\(error.localizedDescription)")
        }
    }

    private func reportFailure(_ message: String) {
        lock.lock()
        _failure = message
        lock.unlock()

        var s = EngineStatus()
        s.message = message
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.engine(self, didUpdate: s)
        }
    }

    // MARK: - 一件的开始

    /// 按【本件开始】：清计数、镜头回位、下一轮从零算。
    func beginCycle() {
        videoQueue.async { [weak self] in
            guard let self else { return }
            let now = CACurrentMediaTime()
            // 上一件还没读到就又按了一次 —— 那一件得留一条「未读到」。
            // `emitMiss` 自己判 cycleStart，正常的一件读到后它是空的，不会误报。
            self.emitMiss(now, reason: "又按了一次开始")
            self.cycleStart = now
            self.resetCycleCounters()
            self.preZoomActive = false
            self.chosenLens = nil
            self.lensVotes.removeAll()
            self.lastFocusPoint = nil
            self.lastPayload = ""
            self.resetPhase()
            self.rampTo(1.0)
            self.publishStatus(force: true)
        }
    }

    /// 把当前这一件当「没读到」收尾。没有在跑的一件就什么都不做。
    ///
    /// ⚠️ 调用方负责在调用之后清 `cycleStart` —— 这里只读不写，
    /// 免得「超时」和「面单走了」两条路径各写一遍清场逻辑、早晚漏一条。
    private func emitMiss(_ now: CFTimeInterval, reason: String) {
        guard let start = cycleStart else { return }
        let snapshot = ScanMiss(
            ms: (now - start) * 1000,
            attempts: max(attempts - 1, 0),
            frames: cycleFrames,
            rectFrames: cycleRectFrames,
            zoomBefore: zoomBefore,
            fillBefore: fillBefore,
            capped: cappedByCeiling,
            zoom: currentDisplayZoom,
            camName: device?.localizedName ?? "—",
            reason: reason,
            barcodes: cycleBarcodeSummary,
            rejected: cycleRejectedSummary,
            focus: cycleFocusSummary,
            aspectBefore: aspectBefore,
            codeInBox: cycleBoxSummary)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.engine(self, didMiss: snapshot)
        }
    }

    /// 连续扫的相位清干净。切开关、重来一件、退出时都调。
    private func resetPhase() {
        phase = .idle
        phaseAt = 0
        lastBumpAt = 0
        holdUntil = 0
        restoreEndsAt = 0
        zoomBefore = 0
        fillBefore = 0
        pushZoom = 0
        cappedByCeiling = false
        armedPayload = ""
    }

    /// 清这一件的逐帧计数。**开件 / 收件 / 切开关 / 放弃 全走这一处。**
    ///
    /// 原来是五处各写一遍 `attempts = 0; misses = 0; frames = 0; rectFrames = 0`，
    /// 0.1.10 要再加五格 —— 再散着写必然漏一条。收成一处，加字段只改这里。
    /// ⚠️ 不动 `cycleStart`：开件和收件的方向正好相反，那个交给调用方。
    private func resetCycleCounters() {
        attempts = 0
        misses = 0
        cycleFrames = 0
        cycleRectFrames = 0
        cycleNoBarcode = 0
        cycleNoPayload = 0
        cyclePayload = 0
        cycleNoPayloadKind = ""
        cycleRejected.removeAll()
        cycleFocusHunting = 0
        cycleLensPosition = -1
        cycleCodeIn = 0
        cycleCodeOut = 0
        aspectBefore = 0
    }

    /// `条码观察` 列：这一件每一帧识码器看到了什么，三桶分开数。
    private var cycleBarcodeSummary: String {
        var parts: [String] = []
        if cycleNoBarcode > 0 { parts.append("无码\(cycleNoBarcode)") }
        if cycleNoPayload > 0 {
            let kind = cycleNoPayloadKind.isEmpty ? "" : "(\(cycleNoPayloadKind))"
            parts.append("无正文\(cycleNoPayload)\(kind)")
        }
        if cyclePayload > 0 { parts.append("有码\(cyclePayload)") }
        return parts.joined(separator: " ")
    }

    /// `丢弃的串` 列。**这一格有值 = 读到了、是被 `looksLikeWaybill` 丢的**，
    /// 不是相机的问题 —— 0.1.9 的数据里这条可能性一次都没被排除过。
    private var cycleRejectedSummary: String {
        cycleRejected.joined(separator: " ")
    }

    /// `码在框内` 列：`内2 外1`。空 = 这一件一次都没解出格式正确的码。
    ///
    /// `外N > 0` 是**定位错了的直接证据**：码已经读出来了，是我们自己的框没罩住它。
    /// 没有这一格，「读不到」和「读到了但不认」在表里长得一模一样。
    private var cycleBoxSummary: String {
        var parts: [String] = []
        if cycleCodeIn > 0 { parts.append("内\(cycleCodeIn)") }
        if cycleCodeOut > 0 { parts.append("外\(cycleCodeOut)") }
        return parts.joined(separator: " ")
    }

    /// `对焦` 列：`稳定 0.62` / `对焦中 5/8 0.31`。
    private var cycleFocusSummary: String {
        guard cycleLensPosition >= 0 else { return "" }
        let hunt = cycleFocusHunting > 0
            ? "对焦中 \(cycleFocusHunting)/\(cycleFrames)"
            : "稳定"
        return String(format: "%@ %.2f", hunt, cycleLensPosition)
    }

    /// 界面上拨了「连续」开关：相位清零，立刻回到原倍率。
    func resetContinuous() {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.resetPhase()
            self.cycleStart = nil
            self.resetCycleCounters()
            self.setZoomImmediate(self.baseZoom)
            self.publishStatus(force: true)
        }
    }

    /// 导表前把「开着但没读到」的那一件收掉，收完再回调（主线程）。
    ///
    /// 不收的话：摆 20 件、表里 18 条 —— 缺的那两件到底是没读出来还是压根没测，
    /// 从表上看不出来。2026-11-12 需求方报的正是这个：两条没读出来，表里一条都没有。
    func closeOpenCycle(_ completion: @escaping () -> Void) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.emitMiss(CACurrentMediaTime(), reason: "导出前还没读到")
            self.cycleStart = nil
            self.resetCycleCounters()
            DispatchQueue.main.async { completion() }
        }
    }

    /// 放弃这一件。
    func cancelCycle() {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.cycleStart = nil
            self.resetCycleCounters()
            self.preZoomActive = false
        }
    }

    // MARK: - 相机选择与倍率

    private static func pickBackCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera,
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .back)
        for type in types {
            if let match = discovery.devices.first(where: { $0.deviceType == type }) {
                return match
            }
        }
        return AVCaptureDevice.default(for: .video)
    }

    /// 内部倍率 → 界面倍率的系数。iOS 18 用 KVC 读写（SDK 里标成 unavailable，但真机上有）；
    /// 取不到就按「有超广角 = 0.5」推。与正式端同一套，别自己另发明一套。
    private static func displayMultiplier(_ device: AVCaptureDevice) -> Double {
        // ⚠️ 必须先 `responds(to:)`：iOS 18 以下没这个选择子，KVC 抛的是 ObjC 异常，
        // Swift 那个 `as?` / `try?` 都接不住，直接闪退。
        let key = "displayVideoZoomFactorMultiplier"
        if device.responds(to: NSSelectorFromString(key)),
           let number = device.value(forKey: key) as? NSNumber,
           number.doubleValue > 0 {
            return number.doubleValue
        }
        let hasUltraWide = device.constituentDevices.contains {
            $0.deviceType == .builtInUltraWideCamera
        }
        return hasUltraWide ? 0.5 : 1
    }

    /// ⚠️ `minAvailableVideoZoomFactor` 是**内部**倍率：三摄机器上它是 1.0（超广角），
    /// 乘过 multiplier 才是界面的 0.5。直接拿它比 0.75 会得出「没有超广角」—— 试过，是错的。
    private var hasUltraWide: Bool {
        guard let device else { return false }
        let minDisplay = LensMath.toDisplay(
            Double(device.minAvailableVideoZoomFactor), multiplier: multiplier)
        return minDisplay < 0.75
    }

    /// 推到某个**界面**倍率。已经是这个值就什么都不做。
    private func rampTo(_ display: Double, rate: Float = ScanEngine.zoomRampRate) {
        guard let device else { return }
        let multiplier = self.multiplier
        let internalFactor = LensMath.toInternal(display, multiplier: multiplier)
        let clamped = min(
            max(internalFactor, Double(device.minAvailableVideoZoomFactor)),
            Double(device.maxAvailableVideoZoomFactor))
        guard abs(clamped - Double(device.videoZoomFactor)) > 0.005 else { return }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.ramp(toVideoZoomFactor: CGFloat(clamped), withRate: rate)
        } catch {
            // 变焦失败不影响识别，只是少一个实验变量。
        }
    }

    /// **瞬时**推到某个界面倍率。`rampTo` 是缓动，这个是立刻到位。
    ///
    /// 为什么扫描期可以瞬时：这一段发生在**读到之前**，不进录像。
    /// 「缓进缓出」那条规矩针对的是录像画面（正式端 2026-09-22），用在这里
    /// 等于把省下来的时间又还回去 —— 1.0 倍/秒下 1x→2.1x 要走 1.1 秒。
    private func setZoomImmediate(_ display: Double) {
        guard let device else { return }
        let internalFactor = LensMath.toInternal(display, multiplier: multiplier)
        let clamped = min(
            max(internalFactor, Double(device.minAvailableVideoZoomFactor)),
            Double(device.maxAvailableVideoZoomFactor))
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.cancelVideoZoomRamp()
            device.videoZoomFactor = CGFloat(clamped)
        } catch {
            // 变焦失败不影响识别，只是少一个实验变量。
        }
    }

    /// 面单长边 ÷ 取景框边长。**「该推多少」的全部输入就是这一个数。**
    ///
    /// 取景框是居中的正方形，边长 = 画面短边 × `scanSpan`；面单框是归一化的，
    /// 两个方向要各自乘回像素才能比大小（正方形在归一化坐标里不是正方形）。
    private func fillRatio(_ box: CGRect) -> Double {
        let longPx = max(Double(box.width) * frameW, Double(box.height) * frameH)
        let sidePx = Double(Self.scanSpan) * min(frameW, frameH)
        return sidePx > 0 ? longPx / sidePx : 0
    }

    /// 码的中心落在绿框里吗。**记账的唯一几何条件**（另一个是格式闸）。
    ///
    /// 开件看的是矩形、记账看的是条码，这两条**原来没有任何关系校验** ——
    /// 2026-11-12 第 15 件 `处理帧数 2 / 矩形帧数 0 / 结果 读到` 就是：框一帧都没检出，
    /// 账照样记了。那一条就是「误读」的唯一来路。
    ///
    /// `smoothedBox` 丢帧时会冻结 0.5 秒（见第 5 步），超过 0.5 秒就不算框住 ——
    /// 拿一个停在原地的旧框去认一件新东西，会把刚才那条路重新打开。
    private func codeInsideLabel(_ code: CGRect, now: CFTimeInterval) -> Bool {
        // 绿框关着就没有「框内」这个概念，那时候唯一的闸还是格式闸（老行为）。
        // 不加这一行，【绿框】一关就**什么都记不下来** —— 关掉它是为了测「不靠框」，
        // 不是为了让这个包罢工。
        guard flags.labelDetect else { return true }
        guard let box = smoothedBox, lastLabelAt > 0, now - lastLabelAt <= 0.5 else { return false }
        // 留 2% 边：码贴在面单边缘时中心压线不算错，绿框本来就是给眼睛看的。
        return box.insetBy(dx: -0.02, dy: -0.02)
            .contains(CGPoint(x: code.midX, y: code.midY))
    }

    /// 数码变焦的**物理上限**（界面口径）：传感器长边 ÷ 视频长边。
    ///
    /// 竖屏 1080P 的视频横向 1080 来自传感器，而 16:9 是从 4:3 裁出来的 ——
    /// 按**长边**比才是同一把尺子：视频 1920 ← 传感器 4032 ⇒ 2.10。
    /// 超过这个数再推全是插值，**一个真像素都不多**。
    ///
    /// 取不到传感器尺寸时退回 2.1（iPhone 11 实测值）—— 宁可退到一个已知的数，
    /// 也不要因为算不出来就一路推到 4x 把画面糊掉。
    private var zoomCeiling: Double {
        guard let device else { return 2.1 }
        let still = device.activeFormat.highResolutionStillImageDimensions
        let sensorLong = Double(max(still.width, still.height))
        let videoLong = max(frameW, frameH)
        guard sensorLong > 0, videoLong > 0 else { return 2.1 }
        let ratio = sensorLong / videoLong
        return ratio >= 1.5 ? ratio : 2.1
    }

    private var currentDisplayZoom: Double {
        guard let device else { return 1 }
        return LensMath.toDisplay(Double(device.videoZoomFactor), multiplier: multiplier)
    }

    /// 连续扫码闭环：**一件 = 进框 → 推近 → 读到 → 保持 → 回位 → 等下一件**。
    ///
    /// 次序是照正式端要走的流程写的，两条关键差别都在这里：
    /// ① **推近发生在读到之前**（现在正式端是读到之后才推，那是确认动作，不是搜索动作）；
    /// ② 读到之后**保持 2 秒**才回退（给录像留一段面单特写）。
    /// `barcodeSeen` 是这一帧「**框内**读到了码」（本方法拿不到那个局部变量）。
    private func continuousTick(now: CFTimeInterval, barcodeSeen: Bool) {
        switch phase {
        case .idle:
            guard let box = smoothedBox else { return }
            // 这一帧必须真的检出矩形。`smoothedBox` 丢帧时会冻结 0.5 秒，
            // 拿冻结值去算要推多少，就是拿一个测不出来的数当输入。
            guard now - lastLabelAt <= 0.3 else { return }
            let fill = fillRatio(box)
            guard fill > 0.02 else { return }

            let current = currentDisplayZoom
            zoomBefore = current
            fillBefore = fill
            cycleStart = now
            resetCycleCounters()

            // 1x 就读得到（离得近）：**别推**。这一帧的图是推近之前拍的，
            // 推了也不会让这一次读得更快，只会白拍一段变焦回到视频里。
            // ⚠️ 这里**不能**清 `lastPayload`：清了的话「同一件还在框里」会每帧都记一条。
            if barcodeSeen {
                pushZoom = current
                cappedByCeiling = false
                return
            }

            // 真的要推了 —— 这是新的一件，上一件的单号不该把这一次去重掉。
            lastPayload = ""
            let ceiling = zoomCeiling
            let want = min(max(current * (Self.targetFill / fill), current), ceiling)
            pushZoom = want
            cappedByCeiling = want >= ceiling - 0.01
            setZoomImmediate(want)

            phase = .seeking
            phaseAt = now
            lastBumpAt = now

        case .seeking:
            if now - lastLabelAt > Self.rearmAbsence {
                // 面单拿走了还没读到 —— 这一轮作废，回去等下一件
                //
                // ⚠️ `rampTo(baseZoom)` 是 0.1.10 补的。原来只有「超时」那条分支回位，
                // 这条不回 —— 于是失败之后倍率就停在推到的位置上，下一件开件时
                // `zoomBefore` 是个错的数（2026-11-12 第 2、8 件的 2.20 就是这么来的）。
                // 它只解释得了 23 件里的那一对，剩下 5 件照旧失败，所以这不是那 7 件的病因。
                emitMiss(now, reason: "面单走了还没读到")
                rampTo(baseZoom)
                phase = .waitingNew
                cycleStart = nil
            } else if now - phaseAt > Self.seekTimeout {
                // 一直读不到：回退，并且**必须进 waitingNew** —— 直接回 idle 的话
                // 面单还在框里，下一帧又会推一次，就成了「推 → 读不到 → 推」的死循环。
                emitMiss(now, reason: "超时")
                rampTo(baseZoom)
                phase = .waitingNew
                cycleStart = nil
            } else if !barcodeSeen, now - lastBumpAt >= Self.seekBumpInterval {
                // **第二条推近理由，不依赖框准不准。**
                // 按占比算的那一步只有在框真的套在面单上时才成立；框在包裹上时占比是
                // 虚高的，规则就判「已经够大」，一步不推 —— 2026-11-12 第 24/25 件
                // 占比 0.676/0.851、倍率 1.00、8~23 帧一个码都没看见，就是这么来的。
                // 所以：推过之后仍然无码，就一档一档往上补，直到物理上限。
                // 框对的件不受影响（它们推到位那一两帧就读到了）。
                lastBumpAt = now
                let ceiling = zoomCeiling
                if currentDisplayZoom < ceiling - 0.01 {
                    let next = min(currentDisplayZoom * Self.seekBumpFactor, ceiling)
                    pushZoom = next
                    cappedByCeiling = next >= ceiling - 0.01
                    setZoomImmediate(next)
                }
            }

        case .holding:
            guard now >= holdUntil else { return }
            let from = currentDisplayZoom
            rampTo(baseZoom)          // 回退是**录进画面**的，必须缓
            restoreEndsAt = now + abs(from - baseZoom) / Double(Self.zoomRampRate)
            phase = .restoring
            phaseAt = now

        case .restoring:
            guard now >= restoreEndsAt else { return }
            phase = .waitingNew

        case .waitingNew:
            // 重臂的判据是「换了一件」，**不是「矩形消失了一会儿」**。
            // ⚠️ 2026-11-09 真机：一个完全静止的包裹被记了 5 条（间隔 4/6/16/8 秒，
            // 正好是保持 2s + 回退 1.2s + 重新检出）。根因是矩形检测在静止面单上会抖，
            // 抖一下就被当成「这件走了」。修法是拿**单号**当身份，不是拿框。
            if !lastPayload.isEmpty, lastPayload != armedPayload {
                phase = .idle            // 单号换了 = 换了一件
            } else if now - lastLabelAt > Self.rearmAbsence,
                      now - lastPayloadAt > Self.rearmAbsence {
                phase = .idle            // 框和码都静默了 = 这件拿走了
            }
        }
    }

    private var phaseName: String {
        switch phase {
        case .idle: return "等面单"
        case .seeking: return "推近读"
        case .holding: return "保持"
        case .restoring: return "回退"
        case .waitingNew: return "等下一件"
        }
    }

    private var zoomDescription: String {
        guard let device else { return "—" }
        var parts: [String] = []
        if #available(iOS 16.0, *) {
            let secondaries = device.activeFormat.secondaryNativeResolutionZoomFactors
            if !secondaries.isEmpty {
                parts.append(secondaries.map { fmt($0) }.joined(separator: "/"))
            }
        }
        let switches = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        if !switches.isEmpty {
            parts.append("换镜 " + switches.map { fmt($0) }.joined(separator: "/"))
        }
        let range = "\(fmt(device.videoZoomFactor)) (\(fmt(CGFloat(device.minAvailableVideoZoomFactor)))~\(fmt(CGFloat(device.maxAvailableVideoZoomFactor))))"
        parts.insert("当前 " + range, at: 0)
        return parts.joined(separator: "  ")
    }

    private func fmt(_ value: CGFloat) -> String {
        let display = LensMath.toDisplay(Double(value), multiplier: multiplier)
        return String(format: "%.2f", display)
    }

    // MARK: - 对焦

    private func focus(at displayed: CGPoint) {
        guard let device, device.isFocusPointOfInterestSupported else { return }
        let point = LensMath.devicePoint(fromDisplayed: displayed, angle: rotationAngle)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.focusPointOfInterest = point

            if device.isExposurePointOfInterestSupported {
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.exposurePointOfInterest = point
            }
        } catch {
            // 对焦点设不上只会慢一点，不报。
        }
    }

    // MARK: - 每帧

    private func publishStatus(force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastStatusAt >= 0.2 else { return }
        lastStatusAt = now

        lock.lock()
        let failure = _failure
        lock.unlock()

        var s = EngineStatus()
        s.message = failure
        s.decodeMs = lastDecodeMs
        s.misses = misses
        s.preZoomed = preZoomActive
        s.chosenLens = chosenLens
        s.distance = lastDistance
        s.labelConfidence = smoothedConfidence
        s.rectInfo = lastRectInfo
        s.barcodeInfo = lastBarcodeInfo
        s.visionError = lastVisionError
        s.phase = phaseName
        s.fill = smoothedBox.map { fillRatio($0) } ?? 0
        s.pushZoom = pushZoom
        s.ceiling = zoomCeiling
        s.capped = cappedByCeiling
        s.rejected = lastRejected
        s.cycleFrames = cycleFrames
        s.cycleRectFrames = cycleRectFrames
        s.fps = fps
        s.frameW = frameW
        s.frameH = frameH
        if let device {
            s.camName = device.localizedName
            s.format = "\(Int(device.activeFormat.formatDescription.dimensions.width))×\(Int(device.activeFormat.formatDescription.dimensions.height))"
            s.hFov = Double(device.activeFormat.videoFieldOfView)
            // ⚠️ 单位是**毫米**（Apple 文档），不是米 —— 旁边那些 WWDC 中文转述写「米」，是错的。
            // 虚拟多摄取的是各颗里**最小**的那个（通常=超广角的 ~2cm），不代表主摄也能凑这么近。
            s.minFocusCM = device.minimumFocusDistance > 0
                ? Double(device.minimumFocusDistance) / 10
                : -1
            s.displayZoom = LensMath.toDisplay(Double(device.videoZoomFactor), multiplier: multiplier)
            s.zooms = zoomDescription
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.engine(self, didUpdate: s)
        }
    }
}

// MARK: - 采集回调

extension ScanEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()

        if lastFrameAt > 0 {
            let delta = now - lastFrameAt
            if delta > 0 { fps = fps * 0.8 + (1 / delta) * 0.2 }
        }
        lastFrameAt = now

        guard now - lastWork >= Self.workInterval else { return }
        lastWork = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        let height = Double(CVPixelBufferGetHeight(pixelBuffer))
        guard width > 0, height > 0 else { return }
        frameW = width
        frameH = height

        let flags = self.flags
        let cropping = flags.cropToScanSpan

        // 1) 裁中间取景框。裁剪用的是 CI 坐标系（左下原点），换回左上原点的活交给 toDisplayed。
        let region: CGRect
        if cropping {
            let side = Self.scanSpan * min(width, height)
            region = CGRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side)
        } else {
            region = CGRect(x: 0, y: 0, width: width, height: height)
        }

        let full = CIImage(cvPixelBuffer: pixelBuffer)
        let cropped = cropping
            ? full.cropped(to: region)
                .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
            : full

        // 2) 请求：条码
        let barcodeRequest = VNDetectBarcodesRequest()
        // 正式端只开 code128。这里**故意放宽**：如果这台机器上的面单其实不是 code128，
        // 正式端也会读不到 —— 那是一个必须知道的结论，而放宽码制是唯一能问出来的办法。
        barcodeRequest.symbologies = [.code128, .code39, .code93, .itf14, .ean13]
        if let revision = VNDetectBarcodesRequest.supportedRevisions.last {
            barcodeRequest.revision = revision
        }

        var rectRequest: VNDetectRectanglesRequest?
        var paperRequest: VNDetectDocumentSegmentationRequest?
        if flags.labelDetect {
            if flags.paperDetect {
                // 「这是不是一张纸」。ML 模型，训练集含面单这类标签，跑在神经网络引擎上，
                // **只返回一个结果** —— 所以 `pickLabel` 那套筛选和兜底在这里用不上。
                let request = VNDetectDocumentSegmentationRequest()
                if let revision = VNDetectDocumentSegmentationRequest.supportedRevisions.last {
                    request.revision = revision
                }
                paperRequest = request
            } else {
                let request = VNDetectRectanglesRequest()
                // 放宽检出（门槛太高会连面单一起漏掉）、收紧形状（面单就是 1.5 左右的长方形）。
                // 挑哪个交给 pickLabel，不要让 Vision 的置信度排序替我们决定。
                request.maximumObservations = 8
                request.minimumAspectRatio = 0.5
                request.maximumAspectRatio = 2.6
                request.minimumSize = 0.15
                // 这两项是唯一还带猜测的地方：2026-11-12 的 12 条里 11 条「读到那一帧没有矩形」，
                // 可能是放大之后边缘变软过不了置信度门槛、也可能是四边形不方过不了 30° 容忍。
                // 拨【宽矩】当场对比，看命中率动不动 —— 不猜，量。
                request.minimumConfidence = flags.relaxRect ? 0.3 : 0.5
                request.quadratureTolerance = flags.relaxRect ? 45 : 30
                rectRequest = request
            }
        }

        // ⚠️ 条码这一路**单独一次 perform、单独一个 handler**：正式端就是一次一个请求。
        // 两个请求塞进同一次 perform 是我自己加的变化，读不到码时它会变成无法排除的变量。
        // 另外不裁框时走 `cvPixelBuffer`（也是正式端那条路），把 CIImage 这一层也摘掉。
        let barcodeHandler: VNImageRequestHandler = cropping
            ? VNImageRequestHandler(ciImage: cropped, orientation: .up, options: [:])
            : VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        let started = CACurrentMediaTime()
        do {
            try barcodeHandler.perform([barcodeRequest])
            lastVisionError = ""
        } catch {
            // ⚠️ 不许静默：**识码器整个抛异常**与「图看了但没认出码」是两件事，
            // 前者要改代码，后者是打法问题。吞掉之后两者在屏幕上长得一模一样 ——
            // 正式端同一处也是这么要求的（CameraSegmentRecorder 的 lastBarcodeError）。
            lastVisionError = String(describing: error)
        }
        lastDecodeMs = (CACurrentMediaTime() - started) * 1000

        // 每 0.5 秒把「送进 Vision 的那张图」缩一张给界面 —— 判断依据，不是装饰。
        if now - lastThumbAt > 0.5 {
            lastThumbAt = now
            let thumb = Self.thumbnail(of: cropped)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.engine(self, didSeeVisionFrame: thumb)
            }
        }

        attempts += 1

        // 3) 条码（results 已经是 [VNBarcodeObservation]，不用再转型）
        let observations = barcodeRequest.results ?? []
        let barcodes: [(String, CGRect)] = observations.compactMap { bc in
            guard let payload = bc.payloadStringValue, !payload.isEmpty else { return nil }
            return (payload, Self.toDisplayed(bc.boundingBox, region: region, width: width, height: height))
        }
        // 看见了码但没解出正文，和「根本没见过码」是两件事 —— 分开显示。
        lastBarcodeInfo = observations.isEmpty
            ? "0 个"
            : observations.map { ob in
                let name = Self.symbologyName(ob)
                return (ob.payloadStringValue?.isEmpty == false) ? name : name + "无正文"
            }.joined(separator: " ")

        // 4) 面单（单独一次 perform，见上）
        var labelBox: CGRect?
        var labelConfidence: Float?
        if let paperRequest {
            let paperHandler: VNImageRequestHandler = cropping
                ? VNImageRequestHandler(ciImage: cropped, orientation: .up, options: [:])
                : VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            var paperError: String?
            do {
                try paperHandler.perform([paperRequest])
            } catch {
                paperError = String(describing: error)
            }
            // 没有候选这回事：**它给什么就是什么**。给不出来就是这一帧没看见纸，
            // 绿框消失、不开件、等下一帧 —— 这比拿一个凑出来的框往下推近强。
            let one = paperRequest.results?.first
            if let one {
                labelBox = Self.toDisplayed(
                    one.boundingBox, region: region, width: width, height: height)
                labelConfidence = one.confidence
            }
            lastRectInfo = paperError.map { "抛错 " + $0 }
                ?? (labelBox.map { "纸框 " + Self.describe($0) } ?? "纸框 0 个")
        } else if let rectRequest {
            let rectHandler: VNImageRequestHandler = cropping
                ? VNImageRequestHandler(ciImage: cropped, orientation: .up, options: [:])
                : VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            var rectError: String?
            do {
                try rectHandler.perform([rectRequest])
            } catch {
                rectError = String(describing: error)
            }
            let all = (rectRequest.results ?? []).map { r -> (CGRect, Float) in
                (Self.toDisplayed(r.boundingBox, region: region, width: width, height: height),
                 r.confidence)
            }
            // 候选全打到屏幕上（面积/长宽比）。**面单不在里面时，再怎么挑都没用** ——
            // 这个列表就是判据：0 个 = Vision 根本没看见面单这块矩形。
            var info = all.isEmpty ? "0 个" : "\(all.count) 个: "
                + all.map { Self.describe($0.0) }.joined(separator: "  ")

            // 有单号就优先在「包住单号」的那几个里挑，没有就全体里挑。
            var pool = all
            if let hit = barcodes.first {
                let containing = all.filter {
                    $0.0.insetBy(dx: -0.02, dy: -0.02).contains(CGPoint(x: hit.1.midX, y: hit.1.midY))
                }
                if !containing.isEmpty { pool = containing }
            }
            if let picked = Self.pickLabel(from: pool) {
                labelBox = picked.0
                labelConfidence = picked.1
                info += "  → " + Self.describe(picked.0)
            }
            lastRectInfo = rectError.map { "抛错 " + $0 } ?? info
        } else {
            lastRectInfo = "未开"
        }

        // 5) 平滑（面单在动，逐帧跳会看瞎）
        if let box = labelBox {
            if let previous = smoothedBox {
                smoothedBox = Self.lerp(previous, box, 0.5)
            } else {
                smoothedBox = box
            }
            smoothedConfidence = labelConfidence
            lastLabelAt = now
            // 框和倍率必须成对记。推近之后矩形常常就检不到了，`smoothedBox` 会一直冻着，
            // 而 `videoZoomFactor` 已经是新的 —— 拿这两个数算距离，误差正好是一个倍率。
            boxZoom = currentDisplayZoom
        } else if now - lastLabelAt > 0.5 {
            smoothedBox = nil
            smoothedConfidence = nil
        }

        // 6) 距离与镜头（M4）：每件只选一次，选完锁死，避免在 0.5x/1x 之间来回跳
        if let box = smoothedBox, let device {
            let longFraction = Double(max(box.width, box.height))
            lastDistance = LensMath.estimateDistance(
                longFraction: longFraction,
                hFovDegrees: Double(device.activeFormat.videoFieldOfView),
                internalZoom: LensMath.toInternal(boxZoom, multiplier: multiplier))
        }

        if flags.lensSelect, !flags.continuous, cycleStart != nil, chosenLens == nil,
           let distance = lastDistance, smoothedBox != nil {
            lensVotes.append(LensMath.lensTarget(distance: distance, ultraWideAvailable: hasUltraWide))
            if lensVotes.count >= 2 {
                let ultraWideVotes = lensVotes.filter { $0 < 0.75 }.count
                let target = ultraWideVotes * 2 > lensVotes.count ? 0.5 : 1.0
                chosenLens = target
                rampTo(target)
            }
        }

        // 7) 预缩放：连续两轮没读到、面单又在框里 ⇒ 推到「面单占画面 preZoomTargetFill」
        //
        // 步长是从**当前看到的占比**反算的，不是固定倍数：80cm 和 40cm 需要推的量差一倍，
        // 固定倍数在其中一个距离上必然不够或过头。
        if flags.continuous {
            // 连续扫：推近的触发者是**面单框**，不是「连续两轮没读到」——
            // 80~100cm 下 1x 是一帧都读不到的，等两轮再推等于白等半秒。
            // `barcodeSeen` 的口径是「**框内**读到了码」，不是「视野里有码」。
            // 码在框外等于没读到 —— 那正是要看清楚、要推近的情形。
            continuousTick(
                now: now,
                barcodeSeen: barcodes.contains { codeInsideLabel($0.1, now: now) })
        } else if flags.preZoom, cycleStart != nil, !preZoomActive, misses >= 2, let box = smoothedBox {
            preZoomActive = true
            let fill = Double(max(box.width, box.height))
            let current = LensMath.toDisplay(Double(device?.videoZoomFactor ?? 1), multiplier: multiplier)
            let need = fill > 0.02 ? Self.preZoomTargetFill / fill : Self.preZoomCeiling
            // 推近要**快**：缓进缓退是给录像开头的，用在这里等于把省下来的时间
            // 又还给缓动（80cm 推到 3.6x 按 1.0 倍/秒要走 2.6 秒）。退回去仍然缓。
            rampTo(min(max(current * need, current), Self.preZoomCeiling),
                   rate: Self.preZoomRampRate)
        }

        // 8) 对焦打到面单中心（动够多才重设，否则相机会一直重新对焦、画面发飘）
        if flags.focusOnLabel, let box = smoothedBox {
            let point = CGPoint(x: box.midX, y: box.midY)
            if let previous = lastFocusPoint,
               hypot(point.x - previous.x, point.y - previous.y) < 0.05 {
                // 没动，不重设
            } else {
                lastFocusPoint = point
                focus(at: point)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.engine(self, didMoveFocusTo: point)
                }
            }
        } else if smoothedBox == nil, flags.focusOnLabel, lastFocusPoint != nil {
            lastFocusPoint = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.engine(self, didMoveFocusTo: nil)
            }
        }

        // 9) 绿框上屏
        let boxForUI = smoothedBox
        let confidenceForUI = smoothedConfidence
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.engine(self, didSeeLabel: boxForUI, confidence: confidenceForUI)
        }

        // 9.5) 矩形命中率。**必须在第 10 步之前**：读到时 `cycleStart` 会被清掉。
        // 这一格是判「矩形检测到底多差」的唯一量：命中率在推近之后塌掉 ⇒ 放大把框打没了；
        // 从头就低 ⇒ 检测本身不行。2026-11-12 那 12 条只能看出「读到那帧没有」，看不出过程。
        if cycleStart != nil {
            cycleFrames += 1
            if labelBox != nil { cycleRectFrames += 1 }
            // 开件时那个框的长宽比：只在第一帧有框时抓一次，之后框会跟着抖动。
            if aspectBefore <= 0, let box = smoothedBox { aspectBefore = Self.aspect(box) }

            // 识码观察三桶 + 对焦状态。**这两样是 0.1.10 唯一的新信息** ——
            // 0.1.9 那 19 列里 10 列是算出来的，读不到的原因一格都没记。
            if observations.isEmpty {
                cycleNoBarcode += 1
            } else if barcodes.isEmpty {
                cycleNoPayload += 1
                if cycleNoPayloadKind.isEmpty,
                   let bare = observations.first(where: { $0.payloadStringValue?.isEmpty != false }) {
                    cycleNoPayloadKind = Self.symbologyName(bare)
                }
            } else {
                cyclePayload += 1
            }
            // 码在不在绿框里。**这是「定位错了」与「相机不行」的分界**，见 `cycleBoxSummary`。
            let decodedNow = barcodes.filter { Self.looksLikeWaybill($0.0) }
            if decodedNow.contains(where: { codeInsideLabel($0.1, now: now) }) {
                cycleCodeIn += 1
            } else if !decodedNow.isEmpty {
                cycleCodeOut += 1
            }
            if let device {
                if device.isAdjustingFocus { cycleFocusHunting += 1 }
                cycleLensPosition = Double(device.lensPosition)
            }
        }

        // 10) 读到单号
        //
        // 只认**格式对**、**而且码的中心落在绿框里**的串。
        // - 格式闸：2026-11-09 真机第 7 条读出 `JT5,($VfF`，正文解错一个字符照样上水印。
        // - 框内闸（0.1.11）：开件看矩形、记账看条码，**这两条原来没有任何关系校验**——
        //   2026-11-12 第 15 件 `处理帧数 2 / 矩形帧数 0 / 结果 读到`，框一帧都没检出，
        //   账照样记了。那就是误读的唯一来路。框错了只让它**慢**（等下一件），不让它**错**。
        let decoded = barcodes.filter { Self.looksLikeWaybill($0.0) }
        let validHits = decoded.filter { codeInsideLabel($0.1, now: now) }
        // `丢弃的串` 只管**格式闸**丢掉的东西。码在框外不算格式问题 —— 那一格必须永远
        // 等于「读到了、是我们自己丢的」，否则两件完全不同的事会被混成一条。
        lastRejected = decoded.isEmpty ? (barcodes.first?.0 ?? "") : ""
        // 这一件的「解出正文但被格式闸丢掉」记录。**CSV 里这一格有值 = 相机没问题，
        // 是我们自己丢的** —— 0.1.9 那 7 件失败里这条可能性一次都没被排除过。
        if cycleStart != nil, !lastRejected.isEmpty,
           !cycleRejected.contains(lastRejected), cycleRejected.count < 3 {
            cycleRejected.append(lastRejected)
        }

        if let hit = validHits.first {
            misses = 0
            // 没有计时（闲着随手扫到）就不要报「几百轮」—— attempts 一直累加着。
            let hadCycle = cycleStart != nil
            let elapsed = hadCycle ? (now - (cycleStart ?? now)) * 1000 : 0
            let attemptCount = hadCycle ? max(attempts - 1, 0) : 0

            // 连续扫：**一件只记一次**（推近之后那第一次）。同一件后续每 0.25 秒
            // 都会再解出同一串，照单全收就是每个包裹几十条记录。
            var record = true
            if flags.continuous {
                // .idle 里读到 = 1x 就够读，`continuousTick` 那一趟没推近（见那里）。
                // ⚠️ 必须**有开件**才记：`cycleStart` 为空时 `.idle` 是「没看到面单框」，
                // 这时候读到码只是视野里顺便有张码（比如绿框关着），记下来就是每帧一条。
                if (phase == .seeking || phase == .idle), hadCycle {
                    phase = .holding
                    holdUntil = now + Self.holdSeconds
                    cycleStart = nil
                    attempts = 0
                } else {
                    record = false   // 保持 / 回退 / 等下一件 期间的重复读到
                }
            } else {
                cycleStart = nil
                attempts = 0
                if preZoomActive {
                    preZoomActive = false
                    rampTo(chosenLens ?? 1.0)
                }
            }

            let duplicate = hit.0 == lastPayload && now - lastPayloadAt < 1.0
            lastPayload = hit.0
            lastPayloadAt = now

            if record && !duplicate {
                if flags.continuous { armedPayload = hit.0 }
                let snapshot = ScanHit(
                    text: hit.0,
                    box: hit.1,
                    ms: elapsed,
                    attempts: attemptCount,
                    at: now,
                    confidence: labelConfidence,
                    distance: lastDistance,
                    zoom: currentDisplayZoom,
                    camName: device?.localizedName ?? "—",
                    zoomBefore: zoomBefore,
                    fillBefore: fillBefore,
                    // 当帧没检出矩形时**必须记空**，不能拿 `smoothedBox` 里冻结的旧值充数：
                    // 2026-11-09 那七条 `读到占比` 和 `推前占比` 三位小数全相等，就是冻结值冒充的。
                    fillAtHit: labelBox != nil ? smoothedBox.map { fillRatio($0) } ?? 0 : nil,
                    capped: cappedByCeiling,
                    frames: cycleFrames,
                    rectFrames: cycleRectFrames,
                    barcodes: cycleBarcodeSummary,
                    rejected: cycleRejectedSummary,
                    focus: cycleFocusSummary,
                    aspectBefore: aspectBefore,
                    codeInBox: cycleBoxSummary)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.engine(self, didHit: snapshot)
                }
            }
        } else if cycleStart != nil {
            misses += 1
        }

        // ⚠️ 这里**不要**再按屏幕方向转坐标：连接上已经转过（videoRotationAngle），
        // 送进来的 buffer 就是转好的。转两次的表现是绿框和单号位置对不上。
        publishStatus()
    }

    // MARK: - 坐标

    // MARK: - 挑面单

    /// 面单长边/短边 ≈ 1.5（100×150mm 的电子面单）。放宽到 1.15~2.6：斜着拍会被拉长。
    /// 用「长/短」而不是「宽/高」，这样和面单是横是竖无关。
    private static let labelAspectRange: ClosedRange<Double> = 1.15...2.6

    /// 面单很少占画面一半以上；占这么大的，通常就是**整个包裹**。
    /// 2026-11-07 真机：绿框框住的是整箱 —— 因为当时按「面积最大」挑，箱子当然最大。
    private static let labelMaxArea: Double = 0.55

    private static func aspect(_ rect: CGRect) -> Double {
        let long = Double(max(rect.width, rect.height))
        let short = Double(min(rect.width, rect.height))
        return short > 0 ? long / short : 0
    }

    /// 面积 / 长宽比，给屏幕上的候选列表用。
    private static func describe(_ rect: CGRect) -> String {
        String(format: "%.2f/%.1f", Double(rect.width * rect.height), aspect(rect))
    }

    /// `VNBarcodeSymbologyCode128` → `Code128`。屏幕和 CSV 都用这一个写法。
    private static func symbologyName(_ observation: VNBarcodeObservation) -> String {
        observation.symbology.rawValue
            .replacingOccurrences(of: "VNBarcodeSymbology", with: "")
    }

    /// 长得像不像一个运单号：只允许 `A-Z0-9-`，长度 10–24。
    ///
    /// 依据是 2026-11-09 真机第 7 条读出的 `JT5,($VfF` —— Code 128 解错几个字符
    /// 不会报错，只会给你一串看着像的乱码。**正式端没有这道闸**（只比「最短位数」），
    /// 这串会被原样上水印。这里先立一节，测出来能不能挡住再决定正式端要不要抄。
    ///
    /// 允许 `-`：京东面单是 `JDX060247420440-1-1-`（正式端会把尾部序号剥掉，这里不剥）。
    /// 长度按归一化之后的字符数算（去空白、转大写），与服务端同一口径。
    static func looksLikeWaybill(_ raw: String) -> Bool {
        let s = String(raw.filter { !$0.isWhitespace }).uppercased()
        guard (10...24).contains(s.count) else { return false }
        return s.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "-")
        }
    }

    /// 从候选里挑面单。
    ///
    /// ⚠️ **不能只挑面积最大的** —— 整箱包裹也是一个矩形，而且永远比面单大。
    /// 先按「像面单」（长宽比 + 面积占比）过滤，再在里面挑最大的：
    /// 这样拿到的是面单本体，而不是面单里更小的条码块，也不是外面那个箱子。
    private static func pickLabel(from pool: [(CGRect, Float)]) -> (CGRect, Float)? {
        // **挑不出来就返回 nil**：不框、不开件、等下一帧。
        //
        // 原来的兜底是「一个都不像就用面积最大的那个」。那行代码**保证会框错** ——
        // 整箱包裹永远比面单大，而包裹的每一面都过得了这个筛（长宽比 1.15~2.6、
        // 面积 ≤55%），于是框在箱子上、按箱子的尺寸算倍率、推到 1.3x 还是读不到。
        // 宁可这一帧不动，也不要拿一个错的框往下走。
        pool.filter {
            labelAspectRange.contains(aspect($0.0))
                && Double($0.0.width * $0.0.height) <= labelMaxArea
        }.max(by: { $0.0.width * $0.0.height < $1.0.width * $1.0.height })
    }

    /// Vision 的框（裁剪图、左下原点）→ 整幅画面归一化、**左上原点**。
    private static func toDisplayed(
        _ raw: CGRect, region: CGRect, width: Double, height: Double
    ) -> CGRect {
        let x = (region.minX + raw.minX * region.width) / width
        let y = (region.minY + raw.minY * region.height) / height
        let w = raw.width * region.width / width
        let h = raw.height * region.height / height
        return CGRect(x: x, y: 1 - (y + h), width: w, height: h)
    }

    // MARK: - 缩略图

    /// 渲染 CIImage 要用同一个 CIContext：每次新建代价很大，而这个只做调试显示。
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// 把 CIImage 缩成一张小图给界面看。失败给 nil（界面上就是空白，不会崩）。
    private static func thumbnail(of image: CIImage, maxSide: CGFloat = 200) -> UIImage? {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1,
              extent.width.isFinite, extent.height.isFinite else { return nil }
        let scale = maxSide / max(extent.width, extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(small, from: small.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t)
    }
}

/// 把旋转角打到连接上。预览层和数据输出**必须调这同一个函数** —— 各写一份，早晚有一边歪。
func scanLabApplyRotation(_ angle: CGFloat, to connection: AVCaptureConnection?) {
    guard let connection else { return }

    if #available(iOS 17.0, *) {
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
            return
        }
    }

    // iOS 16 退路。⚠️ `videoOrientation` 的 landscape 命名与 `UIInterfaceOrientation` 是**反的**，
    // 这张表照 `videoRotationAngle` 的语义写（180 = 横左）。改之前先在真机上看一眼画面正不正。
    guard connection.isVideoOrientationSupported else { return }
    switch ((Int(angle.rounded()) % 360) + 360) % 360 {
    case 90: connection.videoOrientation = .portrait
    case 180: connection.videoOrientation = .landscapeLeft
    case 270: connection.videoOrientation = .portraitUpsideDown
    default: connection.videoOrientation = .landscapeRight
    }
}
