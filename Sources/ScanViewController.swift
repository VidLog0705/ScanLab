import AVFoundation
import UIKit

/// 操作员自用的实验台。**不做美化**，全部让位给「能看清数、能拨开关」。
/// 竖屏横屏共用一套布局（Auto Layout + 可横向滚动的开关条），四种方向都能跑。
final class ScanViewController: UIViewController {

    private let engine = ScanEngine()

    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let overlay = OverlayView()

    private let infoLabel = UILabel()
    private let resultLabel = UILabel()
    private let problemLabel = UILabel()
    /// 送进 Vision 的那张图（缩略）。读不到码时先看它：图不对就是相机/裁剪的问题，
    /// 图对了才轮得到怀疑分辨率、对焦、码制。
    private let visionView = UIImageView()
    private let startButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    private let actions = UIStackView()
    private let scroll = UIScrollView()
    private let row = UIStackView()

    private var status = EngineStatus()
    private var labelBox: CGRect?
    private var focusPoint: CGPoint?

    private var records: [ScanRecord] = []
    private var pendingDate: Date?

    /// 当前切到的旋转角（打给预览层与数据输出）。
    private var angle: CGFloat = 90
    /// 旋转角是否已经打到预览层连接上。连接是会话配好输入之后才出现的，见 `applyOrientation`。
    private var previewAngleApplied = false
    private var started = false

    private var toggles: [(String, WritableKeyPath<ScanFlags, Bool>, UIButton)] = []

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildUI()
        renderToggleStates()
        syncStartButton()
        updateActions()

        let fails = LensMath.check()
        problemLabel.text = fails.isEmpty ? "" : "⚠️ 换算表自检失败：\n" + fails.joined(separator: "\n")
        problemLabel.isHidden = fails.isEmpty
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    granted ? self.startCamera() : self.showProblem("没有相机权限，请到 设置 › ScanLab 打开")
                }
            }
        default:
            showProblem("没有相机权限，请到 设置 › ScanLab 打开")
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        overlay.frame = view.bounds
        applyOrientation()
        refreshGeometry()
    }

    private func startCamera() {
        let layer = AVCaptureVideoPreviewLayer(session: engine.session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer

        engine.delegate = self
        // 先把角打上再开会话：start() 里会用同一个 angle 配数据输出。
        applyOrientation(force: true)
        engine.start()
        syncStartButton()

        // 会话起得来之后连接才有，这时补打一次（多半是这次才真正生效）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.applyOrientation(force: true)
        }
    }

    private func showProblem(_ text: String) {
        problemLabel.text = "⚠️ " + text
        problemLabel.isHidden = false
    }

    // MARK: - 方向

    private func currentOrientation() -> LensMath.ScreenOrientation {
        guard let orientation = view.window?.windowScene?.interfaceOrientation else { return .portrait }
        switch orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .portrait
        }
    }

    /// 第一次必须 `force` —— 竖屏时 wanted == angle（都是 90），不强制就一次也不会打到连接上，
    /// 表现是预览横躺着、绿框也歪。
    private func applyOrientation(force: Bool = false) {
        let wanted = currentOrientation().rotationAngle
        // ⚠️ 预览层的 connection 要等会话配上输入才存在，所以不能只靠「角度变了」判断 ——
        // 加 `previewAngleApplied`，没打上就每趟 layout 都再试一次。
        guard force || wanted != angle || !previewAngleApplied else { return }
        angle = wanted

        if let connection = previewLayer?.connection {
            scanLabApplyRotation(angle, to: connection)
            previewAngleApplied = true
        }
        engine.setRotation(angle)
        refreshGeometry()
    }

    // MARK: - 界面

    private func buildUI() {
        overlay.isUserInteractionEnabled = false
        overlay.backgroundColor = .clear
        view.addSubview(overlay)

        infoLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = .white
        infoLabel.numberOfLines = 0
        infoLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        infoLabel.layer.cornerRadius = 6
        infoLabel.clipsToBounds = true
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoLabel)

        resultLabel.font = .monospacedSystemFont(ofSize: 22, weight: .bold)
        resultLabel.textColor = .systemGreen
        resultLabel.numberOfLines = 1
        resultLabel.adjustsFontSizeToFitWidth = true
        resultLabel.minimumScaleFactor = 0.6
        resultLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        resultLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(resultLabel)

        problemLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        problemLabel.textColor = .systemRed
        problemLabel.numberOfLines = 0
        problemLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        problemLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(problemLabel)

        startButton.setTitle("本件开始", for: .normal)
        startButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold)
        startButton.setTitleColor(.white, for: .normal)
        startButton.backgroundColor = .systemBlue
        startButton.layer.cornerRadius = 10
        startButton.isEnabled = false
        startButton.addAction(UIAction { [weak self] _ in self?.beginCycle() }, for: .touchUpInside)
        startButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(startButton)

        row.axis = .horizontal
        row.spacing = 8
        // fill 而不是 center：让开关按钮撑满整行高度，手指好按（原来只有 ~30pt 高）
        row.alignment = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)
        view.addSubview(scroll)

        for button in [
            makeToggle("连续", key: \.continuous),
            makeToggle("裁框", key: \.cropToScanSpan),
            makeToggle("绿框", key: \.labelDetect),
            makeToggle("对焦", key: \.focusOnLabel),
            makeToggle("预缩", key: \.preZoom),
            makeToggle("选镜", key: \.lensSelect),
        ] {
            row.addArrangedSubview(button)
        }

        // 【导出】【清零】不放滚动条里 —— 竖屏时它们原本被挤到屏幕右边看不见，
        // 看着就像「点了没反应」。挪到底部左侧，永远在眼前。
        configureAction(exportButton, title: "导出", action: #selector(exportCSV))
        configureAction(clearButton, title: "清零", action: #selector(clearRecords))
        actions.axis = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.addArrangedSubview(exportButton)
        actions.addArrangedSubview(clearButton)
        view.addSubview(actions)

        visionView.contentMode = .scaleAspectFit
        visionView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        visionView.layer.borderWidth = 1
        visionView.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
        visionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(visionView)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            visionView.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            visionView.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
            visionView.widthAnchor.constraint(equalToConstant: 100),
            visionView.heightAnchor.constraint(equalToConstant: 133),

            infoLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            infoLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            infoLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.75),

            resultLabel.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 8),
            resultLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            resultLabel.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -12),

            problemLabel.topAnchor.constraint(equalTo: resultLabel.bottomAnchor, constant: 8),
            problemLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            problemLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),

            startButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            startButton.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
            startButton.widthAnchor.constraint(equalToConstant: 168),
            startButton.heightAnchor.constraint(equalToConstant: 56),

            actions.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            actions.centerYAnchor.constraint(equalTo: startButton.centerYAnchor),
            actions.heightAnchor.constraint(equalToConstant: 44),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: startButton.leadingAnchor, constant: -8),

            scroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: startButton.topAnchor, constant: -8),
            scroll.heightAnchor.constraint(equalToConstant: 44),

            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),

            resultLabel.bottomAnchor.constraint(lessThanOrEqualTo: scroll.topAnchor, constant: -8),
        ])
    }

    private func makeToggle(_ title: String, key: WritableKeyPath<ScanFlags, Bool>) -> UIButton {
        let button = UIButton(type: .system)
        button.titleLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        button.layer.cornerRadius = 8
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            var flags = self.engine.flags
            flags[keyPath: key].toggle()
            // 连续扫唯一的输入就是面单框。绿框关着还拨连续 = 一直停在「等面单」，
            // 屏幕上不会有任何提示说为什么不动 —— 直接替他把绿框打开。
            if flags.continuous { flags.labelDetect = true }
            self.engine.flags = flags
            // 连续扫的相位与倍率都归零：中途拨开关不能留一个「推近中」的状态在跑。
            self.engine.resetContinuous()
            self.renderToggleStates()
            self.syncStartButton()
            self.refreshGeometry()
        }, for: .touchUpInside)
        toggles.append((title, key, button))
        return button
    }

    private func configureAction(_ button: UIButton, title: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        button.setTitleColor(.white, for: .normal)
        button.setTitleColor(.lightGray, for: .disabled)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    /// 连续扫时【本件开始】没有意义 —— 自动开件，按了只会插进去一次手动计时。
    /// **置灰而不是藏起来**：藏了会让人以为界面少了东西。
    private func syncStartButton() {
        if engine.flags.continuous {
            startButton.setTitle("连续扫中", for: .normal)
            startButton.isEnabled = false
        } else {
            startButton.setTitle(pendingDate == nil ? "本件开始" : "重新开始", for: .normal)
            startButton.isEnabled = started
        }
    }

    /// 没数据时把【导出】置灰并写上件数 —— 灰的按钮点不动是「看得出来」的，
    /// 而静默 `return` 在操作员眼里等于「按钮坏了」（2026-11-07 就是这么被报的）。
    private func updateActions() {
        exportButton.setTitle(records.isEmpty ? "导出" : "导出 \(records.count)", for: .normal)
        exportButton.isEnabled = !records.isEmpty
        clearButton.isEnabled = !records.isEmpty
    }

    private func renderToggleStates() {
        let flags = engine.flags
        for (title, key, button) in toggles {
            let on = flags[keyPath: key]
            button.setTitle((on ? "● " : "○ ") + title, for: .normal)
            button.setTitleColor(.white, for: .normal)
            button.backgroundColor = on
                ? UIColor.systemGreen.withAlphaComponent(0.85)
                : UIColor.black.withAlphaComponent(0.45)
            button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        }
    }

    private func renderInfo() {
        let s = status
        var lines: [String] = []

        if !s.message.isEmpty {
            lines.append("⚠️ " + s.message)
        }
        lines.append(String(
            format: "%@  %@  送帧 %.0f×%.0f  %.1f fps",
            s.camName, s.format, s.frameW, s.frameH, s.fps))
        let focusText = s.minFocusCM > 0
            ? String(format: "最近对焦 %.0fcm", s.minFocusCM)
            : "最近对焦 未知"
        lines.append(String(format: "视场 %.1f°  ", s.hFov) + focusText
            + String(format: "  识别 %.1fms", s.decodeMs))
        lines.append(String(format: "倍率 %.2f  %@", s.displayZoom, s.zooms))

        var label = s.labelConfidence.map { String(format: "面单 %.2f", $0) } ?? "面单 —"
        if let distance = s.distance { label += String(format: "  ~%.0fcm", distance * 100) }
        if let lens = s.chosenLens { label += String(format: "  选镜 %.1fx", lens) }
        if s.preZoomed { label += "  预缩中" }
        label += "  空转 \(s.misses) 轮"
        lines.append(label)

        // 连续扫这一行是**判据**：占比决定推多少，上限决定推到底有没有用。
        if engine.flags.continuous {
            var line = String(
                format: "连续 %@  占比 %.2f  推 %.2fx  上限 %.2fx",
                s.phase, s.fill, s.pushZoom, s.ceiling)
            if s.capped { line += "  ⚠️推到顶" }
            lines.append(line)
        }
        // 候选矩形：面单不在这个列表里，绿框/对焦/选镜全都无从谈起
        lines.append("条码 " + s.barcodeInfo)
        lines.append("矩形 " + s.rectInfo)
        if !s.visionError.isEmpty {
            lines.append("⚠️ 识码抛错 " + s.visionError)
        }
        // 读到了但格式不对被丢弃的串。必须看得见 —— 否则「丢了一条真面单」
        // 和「根本没读到」在屏幕上长得一模一样。
        if !s.rejected.isEmpty {
            lines.append("⚠️ 丢弃不合格式：" + s.rejected)
        }

        if !records.isEmpty {
            lines.append("\(records.count) 件  " + MetricsStore.summary(records))
        }
        lines.append("开关：" + engine.flags.modeTag)

        infoLabel.text = "\n" + lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 几何

    /// 取景框在**画面**里的归一化位置（原点左上）。画面尺寸由引擎每帧报上来，不猜。
    private var viewfinderRect: CGRect {
        let w = status.frameW
        let h = status.frameH
        guard w > 0, h > 0 else { return .zero }
        let side = Double(ScanEngine.scanSpan) * min(w, h)
        return CGRect(
            x: (w - side) / 2 / w,
            y: (h - side) / 2 / h,
            width: side / w,
            height: side / h)
    }

    private func refreshGeometry() {
        guard previewLayer != nil else { return }
        overlay.viewfinderRect = engine.flags.cropToScanSpan
            ? (screenRect(viewfinderRect) ?? .zero)
            : .zero
        overlay.labelRect = labelBox.flatMap { screenRect($0) }
        overlay.focusPoint = focusPoint.flatMap { screenPoint($0) }
        overlay.setNeedsDisplay()
    }

    /// 画面归一化矩形（原点左上）→ 屏幕坐标。经预览层换算，aspectFill 裁掉的部分自动算进去。
    private func screenRect(_ rect: CGRect) -> CGRect? {
        guard let previewLayer, rect.width > 0, rect.height > 0 else { return nil }
        let device = LensMath.deviceRect(fromDisplayed: rect, angle: angle)
        return previewLayer.layerRectConverted(fromMetadataOutputRect: device)
    }

    private func screenPoint(_ point: CGPoint) -> CGPoint? {
        guard let previewLayer else { return nil }
        let device = LensMath.devicePoint(fromDisplayed: point, angle: angle)
        return previewLayer.layerPointConverted(fromCaptureDevicePoint: device)
    }

    // MARK: - 动作

    private func beginCycle() {
        pendingDate = Date()
        resultLabel.text = "计时中…"
        engine.beginCycle()
        syncStartButton()
    }

    @objc private func exportCSV() {
        guard !records.isEmpty else {
            resultLabel.text = "还没有数据：先按【本件开始】打几件"
            return
        }
        guard let url = MetricsStore.write(records) else {
            resultLabel.text = "写不出 CSV，检查存储空间"
            return
        }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = startButton
        sheet.popoverPresentationController?.sourceRect = startButton.bounds
        present(sheet, animated: true)
    }

    @objc private func clearRecords() {
        records.removeAll()
        resultLabel.text = nil
        updateActions()
        renderInfo()
    }

    private var orientationName: String {
        currentOrientation().rawValue
    }
}

// MARK: - 引擎回调

extension ScanViewController: ScanEngineDelegate {
    func engine(_ engine: ScanEngine, didHit hit: ScanHit) {
        resultLabel.text = String(
            format: "%@  %.0fms  %d 轮  %.2fx→%.2fx%@",
            hit.text, hit.ms, hit.attempts, hit.zoomBefore, hit.zoom,
            hit.capped ? "  ⚠️推到顶" : "")

        // 手动模式靠【本件开始】计时；连续扫没有按钮，每一件都该落一条记录。
        let manual = pendingDate
        guard manual != nil || engine.flags.continuous else { return }

        records.append(ScanRecord(
            index: records.count + 1,
            at: manual ?? Date().addingTimeInterval(-hit.ms / 1000),
            ms: hit.ms,
            attempts: hit.attempts,
            text: hit.text,
            orientation: orientationName,
            mode: engine.flags.modeTag,
            camName: hit.camName,
            zoom: hit.zoom,
            distance: hit.distance,
            labelConfidence: hit.confidence,
            zoomBefore: hit.zoomBefore,
            fillBefore: hit.fillBefore,
            fillAtHit: hit.fillAtHit,
            capped: hit.capped))
        pendingDate = nil
        syncStartButton()
        updateActions()
    }

    func engine(_ engine: ScanEngine, didSeeLabel box: CGRect?, confidence: Float?) {
        labelBox = box
        refreshGeometry()
    }

    func engine(_ engine: ScanEngine, didMoveFocusTo point: CGPoint?) {
        focusPoint = point
        refreshGeometry()
    }

    func engine(_ engine: ScanEngine, didSeeVisionFrame image: UIImage?) {
        visionView.image = image
    }

    func engine(_ engine: ScanEngine, didUpdate status: EngineStatus) {
        self.status = status
        renderInfo()
        refreshGeometry()
    }
}

// MARK: - 覆盖层

/// 取景框 + 绿框 + 焦点十字。三样都画出来，坐标错了一眼看得见 —— 这是这个包的主要用途之一。
final class OverlayView: UIView {
    var viewfinderRect: CGRect = .zero
    var labelRect: CGRect?
    var focusPoint: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("不支持 storyboard") }

    override func draw(_ rect: CGRect) {
        // 框外压暗
        if !viewfinderRect.isEmpty {
            let path = UIBezierPath(rect: bounds)
            path.append(UIBezierPath(roundedRect: viewfinderRect, cornerRadius: 12))
            path.usesEvenOddFillRule = true
            UIColor.black.withAlphaComponent(0.35).setFill()
            path.fill()
        }

        drawBrackets()

        // 面单绿框
        if let box = labelRect, box.width > 1 {
            let path = UIBezierPath(roundedRect: box, cornerRadius: 6)
            UIColor.black.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 4.5
            path.stroke()
            UIColor.systemGreen.setStroke()
            path.lineWidth = 2.5
            path.stroke()
        }

        // 焦点十字：对焦点被换算错了，表现就是它跑到别处去 —— 别删。
        if let point = focusPoint {
            let arm: CGFloat = 14
            let path = UIBezierPath()
            path.move(to: CGPoint(x: point.x - arm, y: point.y))
            path.addLine(to: CGPoint(x: point.x + arm, y: point.y))
            path.move(to: CGPoint(x: point.x, y: point.y - arm))
            path.addLine(to: CGPoint(x: point.x, y: point.y + arm))
            path.append(UIBezierPath(
                arcCenter: point, radius: 9, startAngle: 0, endAngle: .pi * 2, clockwise: true))

            UIColor.black.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 3.5
            path.stroke()
            UIColor.systemYellow.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    private func drawBrackets() {
        guard !viewfinderRect.isEmpty else { return }
        let frame = viewfinderRect
        let arm: CGFloat = 28
        let path = UIBezierPath()

        func corner(_ from: CGPoint, _ dx: CGFloat, _ dy: CGFloat) {
            path.move(to: from)
            path.addLine(to: CGPoint(x: from.x + dx, y: from.y))
            path.move(to: from)
            path.addLine(to: CGPoint(x: from.x, y: from.y + dy))
        }
        corner(CGPoint(x: frame.minX, y: frame.minY), arm, arm)
        corner(CGPoint(x: frame.maxX, y: frame.minY), -arm, arm)
        corner(CGPoint(x: frame.minX, y: frame.maxY), arm, -arm)
        corner(CGPoint(x: frame.maxX, y: frame.maxY), -arm, -arm)

        path.lineCapStyle = .round
        UIColor.black.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 8
        path.stroke()
        UIColor.white.setStroke()
        path.lineWidth = 4
        path.stroke()
    }
}
