import SwiftUI

// MARK: - Localization Helpers for SPM

/// Resolved localization bundle: uses the user's language preference
/// (stored in AppStorage "pier.language") to pick the correct .lproj
/// sub-bundle inside Bundle.module.
/// This is necessary because Bundle.module ignores UserDefaults "AppleLanguages".
private var _resolvedBundle: Bundle?

/// Returns the correct localization bundle based on the user's language setting.
/// SPM may lowercase .lproj directory names (e.g. "zh-hans.lproj" instead of
/// "zh-Hans.lproj"), so we do case-insensitive matching via filesystem scan.
func localizedBundle() -> Bundle {
    if let cached = _resolvedBundle { return cached }
    let lang = UserDefaults.standard.string(forKey: "pier.language") ?? "system"
    if lang != "system" {
        if let bundle = findLprojBundle(for: lang) {
            _resolvedBundle = bundle
            return bundle
        }
    }
    // Fallback: use the device's preferred language
    let preferred = Locale.preferredLanguages.first ?? "en"
    let candidates = [preferred, String(preferred.prefix(2))]
    for candidate in candidates {
        if let bundle = findLprojBundle(for: candidate) {
            _resolvedBundle = bundle
            return bundle
        }
    }
    _resolvedBundle = Bundle.module
    return Bundle.module
}

/// Find the .lproj sub-bundle for a locale, with case-insensitive matching.
/// SPM's `.process()` may lowercase directory names (e.g. "zh-hans" instead of "zh-Hans").
private func findLprojBundle(for locale: String) -> Bundle? {
    // 1. Try exact match first (fast path)
    if let path = Bundle.module.path(forResource: locale, ofType: "lproj"),
       let bundle = Bundle(path: path) {
        return bundle
    }
    // 2. Try lowercased (SPM often lowercases)
    let lowercased = locale.lowercased()
    if lowercased != locale {
        if let path = Bundle.module.path(forResource: lowercased, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
    }
    // 3. Scan the bundle's resource directory for case-insensitive match
    guard let resourceURL = Bundle.module.resourceURL else { return nil }
    let fm = FileManager.default
    guard let contents = try? fm.contentsOfDirectory(at: resourceURL,
                                                      includingPropertiesForKeys: nil) else { return nil }
    let target = locale.lowercased() + ".lproj"
    for url in contents {
        if url.lastPathComponent.lowercased() == target {
            return Bundle(url: url)
        }
    }
    return nil
}

/// Invalidate the cached bundle (call when language setting changes).
func invalidateLocalizedBundle() {
    _resolvedBundle = nil
}

/// Shorthand to retrieve a localized string from the SPM resource bundle.
/// SwiftUI `Text("key")` defaults to `Bundle.main`, but Swift Package Manager
/// puts `Localizable.strings` into `Bundle.module`.
func L(_ key: String) -> LocalizedStringKey {
    LocalizedStringKey(key)
}

/// Get a plain localized String from the correct locale bundle.
func LS(_ key: String) -> String {
    NSLocalizedString(key, bundle: localizedBundle(), comment: "")
}

/// SwiftUI Text that correctly resolves from SPM Bundle.module.
struct LText: View {
    let key: String
    init(_ key: String) {
        self.key = key
    }
    var body: some View {
        Text(NSLocalizedString(key, bundle: localizedBundle(), comment: ""))
    }
}
