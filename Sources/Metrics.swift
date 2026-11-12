import Foundation

/// 一次「本件开始 → 读到单号」的记录。这个包唯一要产出的东西。
struct ScanRecord {
    let index: Int
    let at: Date
    /// 从按【本件开始】到 Vision 报出单号的毫秒数（含中间每一轮识别）。
    let ms: Double
    /// 中间失败了几轮（0 = 第一轮就读到）。
    let attempts: Int
    let text: String
    let orientation: String
    let mode: String
    let camName: String
    let zoom: Double
    let distance: Double?
    let labelConfidence: Float?
    /// 连续扫：推近**之前**的倍率与面单占比（占比 = 面单长边 ÷ 取景框边长）。
    /// 这两个数是判「该推多少」的全部依据 —— 没有它们，读不到时分不清是推少了还是推歪了。
    let zoomBefore: Double
    let fillBefore: Double
    /// 读到那一刻的面单占比。目标 0.65：低于它说明推得不够，高于 0.85 说明快出框了。
    /// **nil = 那一帧没检出矩形**（量不到），和「量到 0」是两回事 —— CSV 里留空。
    let fillAtHit: Double?
    /// 推近被「传感器 ÷ 视频」那个物理上限截住了（再推就是插值，不加信息）。
    let capped: Bool
    /// 这一件**读到没有**。`false` 的行没有单号、没有耗时意义 —— 它们是**没读到**的那几件。
    ///
    /// 2026-11-12 需求方：「实际有两条面单没读出来」，而表里一条都没有 ——
    /// 原来只记成功的。失败的件才是要解释的东西，抹掉之后表看着全绿、现场却在漏读。
    let miss: Bool
    /// 这一件一共处理了几帧、其中几帧检出了面单框。判「矩形检测差在哪」就靠这两格。
    let frames: Int
    let rectFrames: Int
    /// 没读到的原因（读到的那条为空）。
    let reason: String
    /// 这一件每一帧识码器看到了什么：`无码7` / `无正文3(ITF14无正文)` / `有码1`。
    ///
    /// **0.1.10 加的，是把「读不到」定性唯一需要的列。** 0.1.9 那 19 列里
    /// `处理帧数`、`中间失败轮次`、`倍率`、`推到顶` 全是算出来的（帧数 = 超时 ÷ 266ms），
    /// 而识码器每一帧的实际观察一格都没记 —— 所以那 7 件失败只能猜。
    let barcodeSummary: String
    /// 解出正文但被 `looksLikeWaybill` 丢掉的串（最多 3 个，空格分隔）。
    /// **有值 = 读到了，是我们自己丢的**，不是相机问题。
    let rejected: String
    /// `稳定 0.62` / `对焦中 5/8 0.31`。镜头位置 0 = 无穷远、1 = 最近。
    let focus: String
}

enum MetricsStore {
    static func summary(_ records: [ScanRecord]) -> String {
        guard !records.isEmpty else { return "还没有数据" }
        // 耗时只能统计**读到**的那些。把未读到的算进去，P50 会被拖成没有意义的数。
        let hits = records.filter { !$0.miss }
        let missText = hits.count == records.count ? "" : "  未读到 \(records.count - hits.count)"
        guard !hits.isEmpty else { return "0 件读到" + missText }
        let values = hits.map(\.ms).sorted()
        let p50 = percentile(values, 0.5)
        let p90 = percentile(values, 0.9)
        let mean = values.reduce(0, +) / Double(values.count)
        let firstTry = hits.filter { $0.attempts == 0 }.count
        return String(
            format: "n=%d  P50 %.0fms  P90 %.0fms  均值 %.0fms  一轮中 %d%%",
            hits.count,
            p50,
            p90,
            mean,
            Int((Double(firstTry) / Double(hits.count) * 100).rounded())
        ) + missText
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(idx, 0), sorted.count - 1)]
    }

    /// CSV 正文。带 BOM —— 不带的话 Excel 直接双击打开是乱码（中文表头全毁）。
    static func csv(_ records: [ScanRecord]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        // 新列一律**加在最后**：0.1.8 及以前的 CSV 前 15 列对得上，旧表还能直接对比。
        var lines = ["序号,时间,耗时ms,中间失败轮次,单号,方向,开关组合,镜头,倍率,估计距离cm,面单置信度,推前倍率,推前占比,读到占比,推到顶,结果,处理帧数,矩形帧数,未读到原因,条码观察,丢弃的串,对焦"]
        for r in records {
            let fields = [
                "\(r.index)",
                formatter.string(from: r.at),
                String(format: "%.0f", r.ms),
                "\(r.attempts)",
                r.text,
                r.orientation,
                r.mode,
                r.camName,
                String(format: "%.2f", r.zoom),
                r.distance.map { String(format: "%.1f", $0 * 100) } ?? "",
                r.labelConfidence.map { String(format: "%.2f", $0) } ?? "",
                String(format: "%.2f", r.zoomBefore),
                String(format: "%.3f", r.fillBefore),
                r.fillAtHit.map { String(format: "%.3f", $0) } ?? "",
                r.capped ? "1" : "0",
                r.miss ? "未读到" : "读到",
                "\(r.frames)",
                "\(r.rectFrames)",
                r.reason,
                r.barcodeSummary,
                r.rejected,
                r.focus,
            ]
            // 单号不含逗号，但别赌 —— 该加引号就加
            lines.append(fields.map(quote).joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n")
    }

    private static func quote(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 写进 Documents，返回文件地址。
    static func write(_ records: [ScanRecord]) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd-HHmmss"
        let name = "scanlab-\(formatter.string(from: Date())).csv"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
        do {
            try csv(records).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
