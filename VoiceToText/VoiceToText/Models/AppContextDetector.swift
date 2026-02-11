import Foundation
import AppKit

// MARK: - App Category

enum AppCategory: String, CaseIterable, Identifiable, Codable {
    case email = "email"
    case messaging = "messaging"
    case code = "code"
    case document = "document"
    case social = "social"
    case notes = "notes"
    case browser = "browser"
    case general = "general"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .email: return "Email"
        case .messaging: return "Messaging"
        case .code: return "Code"
        case .document: return "Document"
        case .social: return "Social Media"
        case .notes: return "Notes"
        case .browser: return "Browser"
        case .general: return "General"
        }
    }

    /// Default LLM prompt modifier for this category.
    var defaultPromptModifier: String {
        switch self {
        case .email: return "Format as professional email content. Keep it clear and courteous."
        case .messaging: return "Be casual and brief. Use natural conversational tone."
        case .code: return "Format as a code comment or documentation. Use precise technical language."
        case .document: return "Use formal, well-structured prose. Organize into clear paragraphs."
        case .social: return "Keep it casual, engaging, and concise."
        case .notes: return "Format as clear, organized notes."
        case .browser: return "Fix grammar and punctuation naturally."
        case .general: return ""
        }
    }
}

// MARK: - App Context Detector

struct AppContextDetector {

    /// Built-in app-to-category mappings.
    private static let defaultMappings: [String: AppCategory] = [
        // Email
        "com.apple.mail": .email,
        "com.google.Gmail": .email,
        "com.microsoft.Outlook": .email,
        "com.readdle.smartemail-Mac": .email,
        "com.superhuman.mail": .email,

        // Messaging
        "com.apple.MobileSMS": .messaging,
        "com.tinyspeck.slackmacgap": .messaging,
        "ru.keepcoder.Telegram": .messaging,
        "com.hnc.Discord": .messaging,
        "net.whatsapp.WhatsApp": .messaging,
        "com.facebook.archon.developerID": .messaging,
        "com.microsoft.teams2": .messaging,
        "us.zoom.xos": .messaging,

        // Code
        "com.microsoft.VSCode": .code,
        "com.apple.dt.Xcode": .code,
        "com.sublimetext.4": .code,
        "com.jetbrains.intellij": .code,
        "dev.zed.Zed": .code,
        "com.todesktop.230313mzl4w4u92": .code, // Cursor

        // Document
        "com.apple.iWork.Pages": .document,
        "com.microsoft.Word": .document,
        "com.google.Docs": .document,
        "com.notion.id": .document,

        // Social
        "com.atebits.Tweetie2": .social,

        // Notes
        "com.apple.Notes": .notes,
        "md.obsidian": .notes,
        "com.craft.docs": .notes,
        "com.electron.logseq": .notes,

        // Browser
        "com.apple.Safari": .browser,
        "com.google.Chrome": .browser,
        "org.mozilla.firefox": .browser,
        "company.thebrowser.Browser": .browser, // Arc
        "com.brave.Browser": .browser,
    ]

    /// Detect the category for the given app bundle identifier.
    static func detect(bundleIdentifier: String?) -> AppCategory {
        guard let bundleId = bundleIdentifier else { return .general }

        // Check default mappings
        if let category = defaultMappings[bundleId] {
            return category
        }

        // Heuristic fallback based on bundle ID patterns
        let lower = bundleId.lowercased()
        if lower.contains("mail") || lower.contains("email") { return .email }
        if lower.contains("slack") || lower.contains("telegram") || lower.contains("discord") || lower.contains("messenger") { return .messaging }
        if lower.contains("code") || lower.contains("xcode") || lower.contains("ide") { return .code }
        if lower.contains("notes") || lower.contains("obsidian") { return .notes }

        return .general
    }

    /// Detect the category for the current frontmost app.
    static func detectFrontmost() -> AppCategory {
        detect(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// Build a context-aware prompt modifier for the given category.
    static func promptModifier(for category: AppCategory) -> String {
        guard category != .general else { return "" }
        return category.defaultPromptModifier
    }
}
