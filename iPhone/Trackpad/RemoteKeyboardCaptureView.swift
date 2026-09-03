#if canImport(UIKit)
import UIKit

/// A first responder with no document.  Every character is forwarded the moment
/// it is typed and nothing is kept on the phone, so there is no text to read
/// back, autocorrect, or leak into a screenshot.
public final class RemoteKeyboardCaptureView: UIView, UIKeyInput {
    public var onText: ((String) -> Void)?
    public var onReturn: (() -> Void)?
    public var onDeleteBackward: (() -> Void)?
    public var onActiveChange: ((Bool) -> Void)?

    public var keyboardType: UIKeyboardType = .default
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var autocapitalizationType: UITextAutocapitalizationType = .none
    public var spellCheckingType: UITextSpellCheckingType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no
    public var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    public var returnKeyType: UIReturnKeyType = .default
    public var enablesReturnKeyAutomatically = false
    public var isSecureTextEntry = false

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    public override var canBecomeFirstResponder: Bool { true }

    /// The keyboard follows the view: it opens when the mode appears and closes
    /// when it goes away, so no stray responder survives a mode switch.
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder()
        } else {
            resignFirstResponder()
        }
    }

    /// UIKeyInput asks this to decide whether the delete key is live.  Claiming
    /// text keeps backspace enabled even though nothing is stored here.
    public var hasText: Bool { true }

    private func configure() {
        backgroundColor = .clear
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
    }

    @objc private func handleTap() {
        becomeFirstResponder()
    }

    public func insertText(_ text: String) {
        if text == "\n" {
            onReturn?()
        } else {
            onText?(text)
        }
    }

    public func deleteBackward() {
        onDeleteBackward?()
    }

    @discardableResult
    public override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onActiveChange?(true) }
        return result
    }

    @discardableResult
    public override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onActiveChange?(false) }
        return result
    }
}
#endif
