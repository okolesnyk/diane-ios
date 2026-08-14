import SwiftUI
import UIKit

// MARK: - Input rules (nonisolated, tested in FormsLogicTests)

/// What an emoji field is allowed to hold: exactly one emoji, or nothing.
enum EmojiInput {
    /// The value the field should hold after an edit. nil = refuse the edit and
    /// keep what was there; "" = cleared to None.
    /// More than one emoji (a paste, or a second tap on the emoji keyboard)
    /// keeps the LAST grapheme cluster, so a ZWJ family or a skin tone — one
    /// Character, many scalars — survives whole.
    static func accept(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        guard last.isWholeEmoji else { return nil }
        return String(last)
    }
}

extension Character {
    /// One whole emoji: a sequence carrying a ZWJ, a VS16, a skin tone or an
    /// emoji-presentation scalar (flags and keycaps included), or a lone emoji
    /// scalar. The 0x238C floor drops digits, '#' and '*', which are Emoji=Yes
    /// only because of their keycap forms.
    fileprivate var isWholeEmoji: Bool {
        let scalars = unicodeScalars
        if scalars.count > 1 {
            return scalars.contains {
                $0.value == 0x200D || $0.value == 0xFE0F
                    || $0.properties.isEmojiPresentation
                    || $0.properties.isEmojiModifier
            }
        }
        guard let only = scalars.first else { return false }
        return only.properties.isEmoji && only.value > 0x238C
    }
}

// MARK: - The field

/// A UITextField that asks iOS for the EMOJI keyboard.
private final class EmojiKeyboardTextField: UITextField {
    /// Public API since iOS 8. nil when the family removed the emoji keyboard
    /// in Settings — iOS then raises the normal one, whose emoji key still
    /// gets there (the curated grid went; owner 2026-08-14, keyboard only).
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" }
    }

    /// Opt out of "remember the keyboard last used here" so emoji wins again.
    override var textInputContextIdentifier: String? { "" }
}

/// Tap it and the emoji keyboard rises; it stores at most one emoji.
struct EmojiTextField: UIViewRepresentable {
    @Binding var emoji: String
    @Binding var focused: Bool

    func makeUIView(context: Context) -> UITextField {
        let field = EmojiKeyboardTextField()
        field.delegate = context.coordinator
        field.text = emoji
        field.textAlignment = .center
        field.font = .preferredFont(forTextStyle: .title2)
        field.adjustsFontForContentSizeCategory = true
        field.tintColor = .clear  // one emoji — there is no caret to place
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartInsertDeleteType = .no
        field.backgroundColor = .clear
        field.accessibilityLabel = "Emoji"
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.changed(_:)),
            for: .editingChanged
        )
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != emoji { field.text = emoji }
        guard field.window != nil else { return }
        if focused, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !focused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    /// Fill the well it sits in, so the whole 44pt cell is the tap target.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 52
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 44
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: EmojiTextField

        init(_ parent: EmojiTextField) {
            self.parent = parent
        }

        /// One emoji only: letters and digits are refused rather than stored.
        @objc func changed(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }  // let an IME finish
            let value = EmojiInput.accept(field.text ?? "") ?? parent.emoji
            if field.text != value { field.text = value }
            if parent.emoji != value { parent.emoji = value }
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            // The emoji mode only lands once the live field reloads its input.
            field.reloadInputViews()
            if !parent.focused { parent.focused = true }
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if parent.focused { parent.focused = false }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            return true
        }
    }
}

// MARK: - Controls

/// The tappable emoji cell — the current pick, `sparkles` when there is none.
struct EmojiWell: View {
    @Binding var emoji: String
    @Binding var focused: Bool

    var body: some View {
        ZStack {
            if emoji.isEmpty {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            EmojiTextField(emoji: $emoji, focused: $focused)
        }
        .frame(width: 52, height: 44)  // HIG tap target
        .background(
            Color.secondary.opacity(focused ? 0.22 : 0.12),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}

