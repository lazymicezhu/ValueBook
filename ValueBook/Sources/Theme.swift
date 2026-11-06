import SwiftUI

/// 简约深色风格：近黑背景、香槟金点缀、细体大数字
enum Theme {
    static let income = Color(red: 0.94, green: 0.47, blue: 0.42)
    static let expense = Color(red: 0.38, green: 0.80, blue: 0.60)
    /// 「已处置」小章
    static let stamp = Color(red: 0.94, green: 0.47, blue: 0.42)
    static let accent = Color(red: 0.87, green: 0.75, blue: 0.56)
    static let accentGradient = LinearGradient(colors: [Color(red: 0.93, green: 0.82, blue: 0.64), Color(red: 0.80, green: 0.66, blue: 0.46)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
    static let bg = Color(red: 0.047, green: 0.047, blue: 0.055)
    static let card = Color(red: 0.095, green: 0.095, blue: 0.105)
    static let cardHigh = Color(red: 0.14, green: 0.14, blue: 0.155)
    static let separator = Color.white.opacity(0.07)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)

    static func bigNumber(_ size: CGFloat) -> Font { .system(size: size, weight: .light, design: .rounded).monospacedDigit() }
    static func number(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .rounded).monospacedDigit() }
}

/// 卡片容器
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.separator))
    }
}

/// 小标签
struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(Theme.secondary)
    }
}

extension Fmt {
    /// 随手记风格：不带货币符号的金额 20,432.42
    static func plain(_ v: Double) -> String {
        let s = money.string(from: NSNumber(value: abs(v))) ?? "0.00"
        return v < 0 ? "-\(s)" : s
    }
}

enum Filters {
    static func range(_ start: Date, _ end: Date) -> Predicate<LedgerEntry> {
        #Predicate<LedgerEntry> { $0.date >= start && $0.date < end }
    }

    static func search(_ text: String) -> Predicate<LedgerEntry> {
        #Predicate<LedgerEntry> {
            $0.note.localizedStandardContains(text) || $0.category.localizedStandardContains(text) ||
            $0.subcategory.localizedStandardContains(text) || $0.merchant.localizedStandardContains(text) ||
            $0.account.localizedStandardContains(text) || $0.project.localizedStandardContains(text)
        }
    }

    static func account(_ name: String) -> Predicate<LedgerEntry> {
        #Predicate<LedgerEntry> { $0.account == name || $0.toAccount == name }
    }

    static func category(_ type: String, _ name: String) -> Predicate<LedgerEntry> {
        #Predicate<LedgerEntry> { $0.typeRaw == type && $0.category == name }
    }

    static func project(_ name: String) -> Predicate<LedgerEntry> {
        #Predicate<LedgerEntry> { $0.project == name }
    }

    static func merchant(_ name: String) -> Predicate<LedgerEntry> {
        #Predicate<LedgerEntry> { $0.merchant == name }
    }
}
