import Foundation

// MARK: - Notification Names

extension Notification.Name {
    /// Posted by HomeKitCache after a successful rebuild on the main queue.
    static let homeKitCacheDidRebuild = Notification.Name("HomeKitCacheDidRebuild")
}

// MARK: - Localized String Helper

/// Returns a localized string from Localizable.xcstrings.
/// Wraps `String(localized:)` for use outside SwiftUI views.
func localized(_ key: String.LocalizationValue) -> String {
    return String(localized: key)
}

// MARK: - Value Sanitization

/// Ensures a value is safe for JSON serialization.
/// Replaces non-finite floating-point values with `nil` and converts
/// unknown types to their string representation.
func sanitizeValue(_ value: Any) -> Any? {
    if let d = value as? Double {
        guard d.isFinite else { return nil }
        return d
    }
    if let f = value as? Float {
        guard f.isFinite else { return nil }
        return f
    }
    if let n = value as? NSNumber {
        let d = n.doubleValue
        guard d.isFinite else { return nil }
        return n
    }
    if value is Bool || value is Int || value is String {
        return value
    }
    return "\(value)"
}
