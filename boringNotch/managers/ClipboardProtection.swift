//
//  ClipboardProtection.swift
//  boringNotch
//

import Foundation

/// Decides which clipboard entries agents must not read unless the user says otherwise.
///
/// Password managers normally mark their copies concealed, and those never reach the history
/// at all (`ClipboardManager.isExcluded`). This catches what slips past that: a manager that
/// does not set the flag, and keys pasted from a terminal, a dashboard or a `.env` file.
enum ClipboardProtection {
    static let passwordManagerBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "org.keepassxc.keepassxc",
        "com.dashlane.dashlanephonefinal",
        "com.lastpass.LastPass",
        "me.proton.pass.electron",
        "in.sinew.Enpass-Desktop",
    ]

    /// Long pastes are scanned only at the head: a secret worth hiding is short, and a
    /// megabyte log would otherwise run every pattern over every byte on each launch.
    private static let scanLimit = 64 * 1024

    private static let patterns: [(label: String, regex: NSRegularExpression)] = [
        ("a private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        ("an AWS access key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        ("a GitHub token", #"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})\b"#),
        ("a Slack token", #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#),
        ("an API key", #"\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{20,}"#),
        ("a Stripe key", #"\b[rs]k_(?:live|test)_[A-Za-z0-9]{16,}"#),
        ("a Google API key", #"\bAIza[0-9A-Za-z_-]{35}\b"#),
        ("a JWT", #"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#),
        // Only a literal value counts: `password = os.environ["X"]` contains a bracket and
        // quotes, so a code paste that merely NAMES a secret stays readable.
        ("a credential", #"(?i)\b(?:api[_-]?key|secret|password|passwd|token|access[_-]?key)\b["']?\s*[:=]\s*["']?[A-Za-z0-9_\-+/=.]{16,}"#),
    ].compactMap { label, pattern in
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return (label, regex)
    }

    /// A short human reason, or nil when nothing about the entry looks sensitive.
    static func detectedReason(content: ClipboardEntry.ClipboardContent, sourceApp: String?) -> String? {
        if let sourceApp, passwordManagerBundleIDs.contains(sourceApp) {
            return "Copied from a password manager"
        }
        guard case .text(let text) = content else { return nil }
        let head = text.count > scanLimit ? String(text.prefix(scanLimit)) : text
        let range = NSRange(head.startIndex..., in: head)
        for (label, regex) in patterns where regex.firstMatch(in: head, range: range) != nil {
            return "Looks like \(label)"
        }
        return nil
    }
}
