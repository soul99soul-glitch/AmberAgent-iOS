import SwiftUI
import UIKit

/// Native UIKit secure text field for API Keys and credentials.
///
/// Why not SwiftUI's `SecureField`:
/// On iOS, long-pressing an unfocused or empty `SecureField` invokes UIKit's password
/// AutoFill heuristic (`UIMenu.Identifier.autoFill`), which replaces the standard edit
/// menu with a single「自动填充」item and suppresses「粘贴」.
///
/// `AmberAPIKeyTextField` keeps `isSecureTextEntry = true` (never echoing secrets and
/// blocking copy/cut), strips the AutoFill menu hijack so long-press「粘贴」and
/// hardware keyboard `⌘V` always work, reads `UIPasteboard` strictly when the user
/// explicitly invokes `paste(_:)`, and trims leading/trailing whitespace and newlines.
final class AmberAPIKeyTextField: UITextField {
    var onTextChange: ((String) -> Void)?
    /// Injectable for unit tests so paste behavior and clipboard-read counts can be verified
    /// without touching the system pasteboard.
    var pasteboardStringProvider: () -> String? = { UIPasteboard.general.string }
    private(set) var hasTypedInCurrentFocus = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSecureKeyInput()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureSecureKeyInput() {
        isSecureTextEntry = true
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        keyboardType = .asciiCapable
        returnKeyType = .done
        // Prevent iOS Password/Contact AutoFill heuristic from hijacking long-press menu.
        textContentType = UITextContentType(rawValue: "")
        clearButtonMode = .whileEditing

        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        addTarget(self, action: #selector(handleEditingDidBegin), for: .editingDidBegin)
        addTarget(self, action: #selector(handleEditingChanged), for: .editingChanged)
    }

    /// Never let a long pasted API key expand the field's horizontal intrinsic size in SwiftUI.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
    }

    override var keyCommands: [UIKeyCommand]? {
        let pasteCommand = UIKeyCommand(
            input: "v",
            modifierFlags: .command,
            action: #selector(paste(_:))
        )
        return [pasteCommand] + (super.keyCommands ?? [])
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Focusing on touch-down ensures the very first long-press on an unfocused key field
        // presents the standard edit menu with「粘贴」rather than an unfocused AutoFill callout.
        if isEnabled && !isFirstResponder {
            _ = becomeFirstResponder()
        }
        super.touchesBegan(touches, with: event)
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        builder.remove(menu: .autoFill)
        builder.remove(menu: .lookup)
        builder.remove(menu: .share)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(UIResponderStandardEditActions.paste(_:)) {
            // Return true without probing UIPasteboard so opening the menu or focusing the field
            // never triggers a premature clipboard read or privacy banner.
            return isEnabled
        }
        if action == #selector(UIResponderStandardEditActions.selectAll(_:))
            || action == #selector(UIResponderStandardEditActions.delete(_:)) {
            return isEnabled && !(text ?? "").isEmpty
        }
        // Never allow copying/cutting secrets out of the field, and reject AutoFill/Camera selectors.
        return false
    }

    /// Trims leading and trailing whitespace/newlines commonly copied with long API keys.
    static func sanitizePastedKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    override func paste(_ sender: Any?) {
        _ = performExplicitUserPaste()
    }

    /// Reads the pasteboard strictly on an explicit user paste action (long-press「粘贴」or ⌘V),
    /// trims outer whitespace/newlines, and updates the field & binding.
    @discardableResult
    func performExplicitUserPaste() -> Bool {
        guard isEnabled, let raw = pasteboardStringProvider() else { return false }
        let sanitized = Self.sanitizePastedKey(raw)
        guard !sanitized.isEmpty else { return false }

        let current = self.text ?? ""
        let updated: String
        if isFirstResponder,
           let selectedRange = selectedTextRange {
            let startOffset = offset(from: beginningOfDocument, to: selectedRange.start)
            let endOffset = offset(from: beginningOfDocument, to: selectedRange.end)
            let hasExplicitSelection = startOffset != endOffset
            if (hasExplicitSelection || hasTypedInCurrentFocus),
               startOffset >= 0,
               endOffset >= startOffset,
               endOffset <= current.utf16.count {
                let startIndex = String.Index(utf16Offset: startOffset, in: current)
                let endIndex = String.Index(utf16Offset: endOffset, in: current)
                var copy = current
                copy.replaceSubrange(startIndex..<endIndex, with: sanitized)
                updated = Self.sanitizePastedKey(copy)
            } else {
                updated = sanitized
            }
        } else {
            updated = sanitized
        }

        hasTypedInCurrentFocus = false
        self.text = updated
        onTextChange?(updated)
        sendActions(for: .editingChanged)
        return true
    }

    @objc private func handleEditingDidBegin() {
        hasTypedInCurrentFocus = false
    }

    @objc private func handleEditingChanged() {
        hasTypedInCurrentFocus = true
        onTextChange?(text ?? "")
    }
}

/// SwiftUI wrapper around `AmberAPIKeyTextField` for all API Key / secret inputs.
struct AmberSecureKeyInput: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var font: UIFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    var textColor: UIColor = UIColor(AmberTheme.foreground)
    var placeholderColor: UIColor = UIColor(AmberTheme.muted)
    var textAlignment: NSTextAlignment = .natural
    var accessibilityLabel: String? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> AmberAPIKeyTextField {
        let field = AmberAPIKeyTextField(frame: .zero)
        field.delegate = context.coordinator
        field.onTextChange = { [weak coordinator = context.coordinator] newValue in
            coordinator?.propagateTextChange(newValue)
        }
        applyConfiguration(to: field)
        return field
    }

    func updateUIView(_ uiView: AmberAPIKeyTextField, context: Context) {
        context.coordinator.text = $text
        uiView.onTextChange = { [weak coordinator = context.coordinator] newValue in
            coordinator?.propagateTextChange(newValue)
        }
        applyConfiguration(to: uiView)
    }

    private func applyConfiguration(to field: AmberAPIKeyTextField) {
        if field.text != text {
            field.text = text
        }
        field.font = font
        field.textColor = textColor
        field.textAlignment = textAlignment
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: placeholderColor,
                .font: font,
            ]
        )
        field.accessibilityLabel = accessibilityLabel ?? placeholder
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func propagateTextChange(_ newValue: String) {
            if text.wrappedValue != newValue {
                text.wrappedValue = newValue
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}
