import SwiftUI
import UIKit

/// 只输入数字、冒号自动补的 hh:mm:ss 时间输入框
/// 从右往左填充：敲 1 → 00:00:01，敲 1234 → 00:12:34
/// 数据源唯一：外部用 Binding<Double> 双向绑定，避免"显示值"与"真实值"两套状态打架。
struct TimeMaskField: UIViewRepresentable {
    @Binding var value: Double
    /// 允许的最大秒数
    let maxSeconds: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MaskedTimeTextField {
        let field = MaskedTimeTextField()
        field.maxSeconds = maxSeconds
        let coordinator = context.coordinator
        field.onCommit = { newValue in
            coordinator.parent.value = newValue
        }
        field.setSecondsValue(value)
        return field
    }

    func updateUIView(_ view: MaskedTimeTextField, context: Context) {
        context.coordinator.parent = self
        view.maxSeconds = maxSeconds
        if !view.isFirstResponder {
            view.setSecondsValue(value)
        }
    }

    final class Coordinator {
        var parent: TimeMaskField
        init(_ parent: TimeMaskField) { self.parent = parent }
    }
}

final class MaskedTimeTextField: UITextField, UITextFieldDelegate {
    var maxSeconds: Double = 0
    var onCommit: ((Double) -> Void)?

    private var digits: String = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        delegate = self
        keyboardType = .numberPad
        textAlignment = .left
        font = .monospacedDigitSystemFont(ofSize: 17, weight: .regular)
        borderStyle = .none
        tintColor = .systemBlue
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        let done = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(finishEditing))
        toolbar.items = [UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil), done]
        inputAccessoryView = toolbar
    }

    @objc private func finishEditing() {
        resignFirstResponder()
    }

    /// 外部值 → 显示：必须按 时/分/秒 拆位（旧实现把总秒数当 hhmmss，导致显示与真实值错位）
    func setSecondsValue(_ seconds: Double) {
        let clamped = max(0, seconds.isFinite ? seconds : 0)
        let total = min(Int(clamped.rounded()), 359999)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        digits = String(format: "%02d%02d%02d", h, m, s)
        text = Self.format(digits)
    }

    private var secondsValue: Double {
        let value = Int(digits) ?? 0
        let h = value / 10000
        let m = (value / 100) % 100
        let s = value % 100
        return Double(h * 3600 + m * 60 + s)
    }

    private static func format(_ digits: String) -> String {
        let padded = String(repeating: "0", count: max(0, 6 - digits.count)) + digits.suffix(6)
        let h = padded.prefix(2)
        let m = padded.dropFirst(2).prefix(2)
        let s = padded.suffix(2)
        return "\(h):\(m):\(s)"
    }

    func textField(_ textField: UITextField,
                   shouldChangeCharactersIn range: NSRange,
                   replacementString string: String) -> Bool {
        if string.isEmpty {
            // 退格：删掉最后一位数字
            if !digits.isEmpty { digits.removeLast() }
        } else {
            let numbers = string.filter { $0.isNumber }
            guard !numbers.isEmpty else { return false }
            digits += numbers
            if digits.count > 6 { digits = String(digits.suffix(6)) }
        }
        text = Self.format(digits)
        if let end = textField.endOfDocument as UITextPosition? {
            textField.selectedTextRange = textField.textRange(from: end, to: end)
        }
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        var value = secondsValue
        if maxSeconds > 0, value > maxSeconds { value = maxSeconds }
        if value < 0 { value = 0 }
        setSecondsValue(value)
        onCommit?(value)
    }
}
