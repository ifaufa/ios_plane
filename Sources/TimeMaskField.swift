import SwiftUI
import UIKit

/// 只输入数字、冒号自动补的 hh:mm:ss 时间输入框
/// 从右往左填充：敲 1 → 00:00:01，敲 1234 → 00:12:34
struct TimeMaskField: UIViewRepresentable {
    /// 当前秒数（外部值）
    let seconds: Double
    /// 允许的最大秒数
    let maxSeconds: Double
    /// 提交（失焦/点完成）时回调，值已做范围校验
    let onCommit: (Double) -> Void

    func makeUIView(context: Context) -> MaskedTimeTextField {
        let field = MaskedTimeTextField()
        field.maxSeconds = maxSeconds
        field.onCommit = onCommit
        field.setSecondsValue(seconds)
        return field
    }

    func updateUIView(_ view: MaskedTimeTextField, context: Context) {
        view.maxSeconds = maxSeconds
        view.onCommit = onCommit
        if !view.isFirstResponder {
            view.setSecondsValue(seconds)
        }
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

    func setSecondsValue(_ seconds: Double) {
        let clamped = max(0, seconds.isFinite ? seconds : 0)
        let total = Int(clamped.rounded())
        digits = String(format: "%06d", min(total, 359999))
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
            // 退格：删掉最后一位
            if !digits.isEmpty { digits.removeLast() }
        } else {
            let numbers = string.filter { $0.isNumber }
            guard !numbers.isEmpty else { return false }
            digits += numbers
            if digits.count > 6 { digits = String(digits.suffix(6)) }
        }
        text = Self.format(digits)
        // 光标始终放在末尾
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
