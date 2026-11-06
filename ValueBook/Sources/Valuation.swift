import Foundation

extension Date {
    var startOfDay: Date { Calendar.current.startOfDay(for: self) }
    var startOfMonth: Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: self))!
    }
    var startOfYear: Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year], from: self))!
    }
    func adding(months: Int) -> Date { Calendar.current.date(byAdding: .month, value: months, to: self)! }
    func adding(years: Int) -> Date { Calendar.current.date(byAdding: .year, value: years, to: self)! }
    func adding(days: Int) -> Date { Calendar.current.date(byAdding: .day, value: days, to: self)! }
    func days(to other: Date) -> Int {
        Calendar.current.dateComponents([.day], from: startOfDay, to: other.startOfDay).day ?? 0
    }
}

struct ValueSample: Identifiable {
    var date: Date
    var value: Double
    var id: Date { date }
}

extension Asset {
    var residualValue: Double { price * min(max(residualRate, 0), 1) }

    /// 只按折旧模型算出的价值
    func modelValue(at date: Date) -> Double {
        let years = Double(max(purchaseDate.days(to: date), 0)) / 365.0
        let residual = residualValue
        switch method {
        case .none:
            return price
        case .straight:
            guard lifeYears > 0 else { return residual }
            let v = price - (price - residual) * years / lifeYears
            return max(residual, v)
        case .accelerated:
            // 指数衰减：到使用年限时，可折旧部分只剩 5%
            guard lifeYears > 0 else { return residual }
            let k = log(20.0) / lifeYears
            return residual + (price - residual) * exp(-k * years)
        }
    }

    /// 某一天这件东西值多少钱
    func value(at date: Date) -> Double {
        if date.startOfDay < purchaseDate.startOfDay { return 0 }
        if isRetired, let retiredDate, date.startOfDay >= retiredDate.startOfDay { return 0 }

        // 有手动估值时：估值点之间线性插值，最后一个估值点之后按折旧模型的比例继续走
        let points = valuations.filter { $0.date.startOfDay >= purchaseDate.startOfDay }
        guard !points.isEmpty else { return modelValue(at: date) }
        var anchors = [ValuePoint(date: purchaseDate, value: price)] + points
        anchors.sort { $0.date < $1.date }
        let d = date.startOfDay
        for i in 0..<(anchors.count - 1) {
            let a = anchors[i], b = anchors[i + 1]
            if d >= a.date.startOfDay && d <= b.date.startOfDay {
                let span = Double(a.date.days(to: b.date))
                guard span > 0 else { return b.value }
                let t = Double(a.date.days(to: d)) / span
                return a.value + (b.value - a.value) * t
            }
        }
        let last = anchors.last!
        let base = modelValue(at: last.date)
        guard base > 0 else { return last.value }
        return last.value * modelValue(at: date) / base
    }

    /// 持有天数（购买当天算第 1 天）
    func daysHeld(asOf date: Date = .now) -> Int {
        let end = (isRetired ? (retiredDate ?? date) : date)
        return max(startDate.days(to: end) + 1, 1)
    }

    var currentValue: Double { value(at: .now) }

    /// 日均成本：每笔钱各自 ÷ 它付款到今天的天数，再加起来
    var dailyCost: Double { dailyCost(at: isRetired ? (retiredDate ?? .now) : .now) }

    /// 每一笔花费：买入那笔 + 附属账目（卖掉后，卖出的钱从买入那笔里扣）
    func payments(addOns: [ValuePoint]? = nil, sold: Bool = false) -> [ValuePoint] {
        let main = ValuePoint(date: purchaseDate, value: sold ? price - salePrice : price)
        guard addOnTotal != 0 else { return [main] }
        return [main] + (addOns ?? self.addOns)
    }

    /// 某天的日均：那天及之前付的每一笔，各自 ÷（付款日到那天的天数），再加起来
    /// floor：是否给刚付的钱设最少摊销天数（只对设了年限、要换新的物品；订阅这类不设年限的按实际天数）
    static func dailyCost(of payments: [ValuePoint], at end: Date, floor useFloor: Bool = true) -> Double {
        let d = end.startOfDay
        let floor = useFloor ? Double(minAmortizeDays) : 1
        return payments.reduce(0) { sum, p in
            guard p.date.startOfDay <= d else { return sum }
            // 刚付的钱至少按 minAmortizeDays 天摊，免得付款头几天日均冲得特别高
            return sum + p.value / max(Double(p.date.days(to: d) + 1), floor)
        }
    }

    /// 每一笔钱最少摊多少天（设置里可选 7 / 30 / 60），默认 30
    static let minAmortizeKey = "amortizeMinDays"
    static var minAmortizeDays: Int {
        let v = UserDefaults.standard.integer(forKey: minAmortizeKey)
        return v > 0 ? v : 30
    }

    /// 是否按最少天数摊：设了年限（会换新）的才摊；AI、云服务这类不设年限的按实际天数。
    /// 等同于 hasTarget，但不用为老数据去算达标日，便宜
    var usesMinAmortize: Bool { targetYears > 0 || targetDailyCost > 0 }

    /// 日均折旧：已损失的价值 ÷ 持有天数
    var dailyDepreciation: Double {
        let lost = isRetired ? price - salePrice : price - currentValue
        return lost / Double(daysHeld())
    }

    // MARK: - 日均花费

    /// 到某天为止的日均花费（处置后停在处置那天）
    func dailyCost(at date: Date, addOns: [ValuePoint]? = nil) -> Double {
        let end = isRetired ? min(date, retiredDate ?? date) : date
        let sold = isRetired && date.startOfDay >= (retiredDate ?? date).startOfDay
        return Self.dailyCost(of: payments(addOns: addOns, sold: sold), at: end, floor: usesMinAmortize)
    }

    /// 想用多少年。老数据只存了目标日均的，按当时的达标日换算成年数（保留一位小数）
    var effectiveTargetYears: Double {
        if targetYears > 0 { return targetYears }
        guard targetDailyCost > 0 else { return 0 }
        let reach = Self.reachDate(of: payments(), target: targetDailyCost)
        let days = max(startDate.days(to: reach) + 1, 1)
        return max((Double(days) / 365 * 10).rounded() / 10, 0.1)
    }

    var hasTarget: Bool { effectiveTargetYears > 0 }

    /// 达标那天：从第一笔付款起用满目标年数的那天，跟花了多少钱无关
    var targetDate: Date? {
        guard let total = targetTotalDays else { return nil }
        return startDate.adding(days: total - 1).startOfDay
    }

    /// 用满目标年数那天的日均（只作参考）
    var dailyCostAtTarget: Double? {
        targetDate.map { Self.dailyCost(of: payments(), at: $0) }
    }

    /// 这些钱付完、之后不再付的前提下，日均第一次降到 target 的那天
    static func reachDate(of payments: [ValuePoint], target: Double) -> Date {
        let lo = payments.map(\.date).max() ?? .now
        if dailyCost(of: payments, at: lo) <= target { return lo.startOfDay }
        // 最后一笔之后日均只降不升，二分找第一天
        var a = 0, b = 365 * 200
        while a < b {
            let m = (a + b) / 2
            if dailyCost(of: payments, at: lo.adding(days: m)) <= target { b = m } else { a = m + 1 }
        }
        return lo.adding(days: a).startOfDay
    }

    /// 从开始到达标一共要用多少天
    var targetTotalDays: Int? {
        let y = effectiveTargetYears
        return y > 0 ? max(Int((y * 365).rounded()), 1) : nil
    }

    var daysLeft: Int? { targetTotalDays.map { max($0 - daysHeld(), 0) } }

    var reachedTarget: Bool { targetTotalDays.map { daysHeld() >= $0 } ?? false }

    var targetProgress: Double {
        guard let total = targetTotalDays, total > 0 else { return 0 }
        return min(Double(daysHeld()) / Double(total), 1)
    }

    /// 日均花费曲线：从第一笔付款到今天（或处置日）。
    /// 每次付款那天日均会跳高，所以付款日和前一天一定取点，其余均匀取样
    func dailyCostSeries(maxPoints: Int = 240) -> [ValueSample] {
        let end = isRetired ? (retiredDate ?? .now) : Date.now
        let start = startDate
        let held = max(start.days(to: end), 1)
        let step = max(held / maxPoints, 1)
        var offsets = Set(stride(from: 0, through: held, by: step))
        offsets.insert(held)
        let extras = addOns
        for p in payments(addOns: extras) {
            let o = start.days(to: p.date)
            for k in [o - 1, o] where k >= 0 && k <= held { offsets.insert(k) }
        }
        return offsets.sorted().map { o in
            let d = o == held ? end : start.adding(days: o)
            return ValueSample(date: d, value: dailyCost(at: d, addOns: extras))
        }
    }

    /// 生成价值曲线
    func series(maxPoints: Int = 160) -> [ValueSample] {
        let end = isRetired ? (retiredDate ?? .now) : Date.now
        let total = max(purchaseDate.days(to: end), 1)
        let step = max(total / maxPoints, 1)
        var out: [ValueSample] = []
        var day = 0
        while day < total {
            let d = purchaseDate.adding(days: day)
            out.append(ValueSample(date: d, value: value(at: d)))
            day += step
        }
        let lastValue = isRetired ? salePrice : value(at: end)
        out.append(ValueSample(date: end, value: lastValue))
        return out
    }

    /// 往后预测的曲线
    func forecast(years: Int = 3) -> [ValueSample] {
        guard !isRetired else { return [] }
        let start = Date.now
        return stride(from: 0, through: years * 365, by: max(years * 365 / 60, 1)).map {
            let d = start.adding(days: $0)
            return ValueSample(date: d, value: value(at: d))
        }
    }
}

enum Fmt {
    static let money: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    static func yuan(_ v: Double, sign: Bool = false) -> String {
        let s = money.string(from: NSNumber(value: abs(v))) ?? "0.00"
        let prefix = v < 0 ? "-" : (sign && v > 0 ? "+" : "")
        return "\(prefix)¥\(s)"
    }

    static func money(_ v: Double, _ currency: String, sign: Bool = false) -> String {
        let s = money.string(from: NSNumber(value: abs(v))) ?? "0.00"
        let prefix = v < 0 ? "-" : (sign && v > 0 ? "+" : "")
        return "\(prefix)\(Rates.symbol(currency))\(s)"
    }

    static func short(_ v: Double) -> String {
        if abs(v) >= 10000 { return String(format: "%.1f万", v / 10000) }
        return String(format: "%.0f", v)
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let dayHeader: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f
    }()

    static let dayWithYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 EEE"
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f
    }()

    static let todayTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f
    }()

    static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEE"
        return f
    }()

    static let monthDot: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月"
        return f
    }()

    static let yearMonth: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.M"
        return f
    }()

    static let shortDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    static let month: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月"
        return f
    }()
}
