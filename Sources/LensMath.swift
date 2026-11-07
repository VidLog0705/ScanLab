import CoreGraphics
import Foundation

/// 纯算式：倍率换算、屏幕坐标 ⇄ 设备坐标、面单距离估计、镜头选择。
///
/// 全部无副作用、不碰 AVCaptureDevice —— 这样在 Windows 上也能对着纸面推公式，
/// 真机上一旦画出来的十字/绿框不对，问题一定在换算表而不是相机。
enum LensMath {

    // MARK: - 倍率换算

    /// 内部倍率 → 界面倍率（0.5 = 超广角那颗）。
    static func toDisplay(_ internalFactor: Double, multiplier: Double) -> Double {
        multiplier > 0 ? internalFactor * multiplier : internalFactor
    }

    /// 界面倍率 → 内部倍率。
    static func toInternal(_ displayFactor: Double, multiplier: Double) -> Double {
        multiplier > 0 ? displayFactor / multiplier : displayFactor
    }

    // MARK: - 方向换算

    /// `videoRotationAngle` 的那张表：屏幕方向 → 顺时针旋转角。
    ///
    /// 与正式端 `applyOrientation(to:spec:)` 同源。**写死成表**，不要在这里推导 ——
    /// 推导错一格，绿框和焦点十字会转到别的边上，而画面本身看着完全正常。
    enum ScreenOrientation: String, CaseIterable {
        case portrait, portraitUpsideDown, landscapeLeft, landscapeRight

        var rotationAngle: CGFloat {
            switch self {
            case .portrait: return 90
            case .portraitUpsideDown: return 270
            case .landscapeLeft: return 180
            case .landscapeRight: return 0
            }
        }

        var isPortrait: Bool { self == .portrait || self == .portraitUpsideDown }
    }

    /// 画面（已按 [rotationAngle] 转过、原点左上）里的归一化点 → 设备的归一化点（相机原生横向、原点左上）。
    ///
    /// 这是 `focusPointOfInterest` 要的坐标系。**转错的表现是：焦点十字跑到画面另一侧，
    /// 相机对焦到背景上、面单反而糊** —— 所以十字是画出来的，错了一眼就看得见。
    static func devicePoint(fromDisplayed p: CGPoint, angle: CGFloat) -> CGPoint {
        // angle 归一化到 0/90/180/270
        let a = ((Int(angle.rounded()) % 360) + 360) % 360
        switch a {
        case 90:  return CGPoint(x: p.y, y: 1 - p.x)
        case 180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case 270: return CGPoint(x: 1 - p.y, y: p.x)
        default:  return p
        }
    }

    /// 矩形同样换算。90/180/270 都是直角旋转 ⇒ 对角两点就够，再归一成正矩形。
    static func deviceRect(fromDisplayed r: CGRect, angle: CGFloat) -> CGRect {
        let a = devicePoint(fromDisplayed: CGPoint(x: r.minX, y: r.minY), angle: angle)
        let b = devicePoint(fromDisplayed: CGPoint(x: r.maxX, y: r.maxY), angle: angle)
        return CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    // MARK: - 距离估计（M4）

    /// 面单长边（米）。国内电子面单主流 100×150mm，少数 100×180mm。
    /// 只影响距离**读数**与镜头分界，估歪了也只是选错一档镜头，不会选错码。
    static let labelLongMeters: Double = 0.15

    /// 由「面单长边占画面多少比例」反推拍摄距离。
    ///
    /// - Parameters:
    ///   - longFraction: 面单长边在画面长边方向上的占比（0~1，与方向无关，取矩形长短边最大值）
    ///   - hFovDegrees: 当前格式的水平视场角（`activeFormat.videoFieldOfView`，1x 时）
    ///   - internalZoom: 当前**内部**倍率（`videoZoomFactor`）
    ///
    /// 公式：角宽 = 占比 × 当前有效水平视场角；距离 = (实物长边/2) / tan(角宽/2)。
    /// ⚠️ `videoFieldOfView` 在虚拟多摄上取的是整机格式的值，与实际成像略有出入 ⇒
    /// 这是**估计值**，界面上标 `~`，不要当测量结果引用。
    static func estimateDistance(
        longFraction: Double,
        hFovDegrees: Double,
        internalZoom: Double,
        longMeters: Double = labelLongMeters
    ) -> Double? {
        guard longFraction > 0.02, longFraction <= 1,
              hFovDegrees > 1, hFovDegrees < 179,
              internalZoom > 0.1, longMeters > 0 else { return nil }

        let effectiveH = hFovDegrees * .pi / 180 / internalZoom
        let angular = longFraction * effectiveH
        guard angular > 0.001, angular < .pi else { return nil }

        let d = (longMeters / 2) / tan(angular / 2)
        return d.isFinite && d > 0 ? d : nil
    }

    /// 近到什么程度该换超广角。
    ///
    /// 依据是物理不是手感：iPhone 15/16 Pro 主摄最近合焦约 20cm，小于这个距离**怎么对焦都是糊的**，
    /// 只有 0.5x 超广角（微距）能合上。分界线取 32cm 留一点余量 —— 20~32cm 之间主摄已经明显变软。
    static let closeLimitMeters: Double = 0.32

    /// 按距离挑镜头档位（界面倍率）。超广角不可用（没这颗镜头）就只能 1x。
    static func lensTarget(distance: Double?, ultraWideAvailable: Bool) -> Double {
        guard ultraWideAvailable, let d = distance else { return 1.0 }
        return d < closeLimitMeters ? 0.5 : 1.0
    }

    // MARK: - 自检

    /// 换算表的对照。返回失败项（空 = 全对）。
    ///
    /// 不用 `assert`：Release 包会把 assert 编掉，而这包**只出 Release** ——
    /// 写了等于没写。改成返回值，界面顶上红字显示，错了一眼能看见还不用崩。
    static func check() -> [String] {
        var fails: [String] = []

        func expect(_ name: String, _ got: CGPoint, _ want: CGPoint) {
            if abs(got.x - want.x) > 1e-9 || abs(got.y - want.y) > 1e-9 {
                fails.append("\(name): 得 \(got) 应为 \(want)")
            }
        }
        func expect(_ name: String, _ got: CGRect, _ want: CGRect) {
            if abs(got.minX - want.minX) > 1e-9 || abs(got.minY - want.minY) > 1e-9
                || abs(got.width - want.width) > 1e-9 || abs(got.height - want.height) > 1e-9 {
                fails.append("\(name): 得 \(got) 应为 \(want)")
            }
        }
        func expect(_ name: String, _ got: Double, _ want: Double, tol: Double = 1e-9) {
            if abs(got - want) > tol { fails.append("\(name): 得 \(got) 应为 \(want)") }
        }

        // 0° 原样
        expect("0°", devicePoint(fromDisplayed: CGPoint(x: 0.25, y: 0.75), angle: 0),
               CGPoint(x: 0.25, y: 0.75))
        // 90°：设备左上 → 显示右上；设备右下 → 显示左下
        expect("90°左", devicePoint(fromDisplayed: CGPoint(x: 1, y: 0), angle: 90),
               CGPoint(x: 0, y: 0))
        expect("90°右", devicePoint(fromDisplayed: CGPoint(x: 0, y: 1), angle: 90),
               CGPoint(x: 1, y: 1))
        // 270°：设备左上 → 显示左下
        expect("270°", devicePoint(fromDisplayed: CGPoint(x: 0, y: 1), angle: 270),
               CGPoint(x: 0, y: 0))
        // 180°：对角互换
        expect("180°", devicePoint(fromDisplayed: CGPoint(x: 0.2, y: 0.8), angle: 180),
               CGPoint(x: 0.8, y: 0.2))
        // 负角度/超 360 要能归一
        expect("-270°", devicePoint(fromDisplayed: CGPoint(x: 1, y: 0), angle: -270),
               CGPoint(x: 0, y: 0))
        // 矩形换算
        expect("rect90",
               deviceRect(fromDisplayed: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), angle: 90),
               CGRect(x: 0.2, y: 0.6, width: 0.4, height: 0.3))
        // 倍率往返
        expect("倍率往返", toInternal(toDisplay(1.0, multiplier: 0.5), multiplier: 0.5), 1.0)
        // 距离：面单长边占满画面 1/3、视场 70°、1x ⇒ (0.15/2) / tan(70°/6) ≈ 0.363 m
        if let d = estimateDistance(longFraction: 1.0 / 3.0, hFovDegrees: 70, internalZoom: 1) {
            expect("距离估计", d, 0.363, tol: 0.005)
        } else {
            fails.append("距离估计: 返回 nil")
        }
        // 30cm 该换超广角，60cm 不该；没有超广角就只能 1x
        expect("近换超广角", lensTarget(distance: 0.3, ultraWideAvailable: true), 0.5)
        expect("远用主摄", lensTarget(distance: 0.6, ultraWideAvailable: true), 1.0)
        expect("无超广角", lensTarget(distance: 0.3, ultraWideAvailable: false), 1.0)

        return fails
    }
}
