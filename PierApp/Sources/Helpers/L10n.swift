import SwiftUI

// MARK: - Localization Helpers for SPM

/// Shorthand to retrieve a localized string from the SPM resource bundle.
/// SwiftUI `Text("key")` defaults to `Bundle.main`, but Swift Package Manager
/// puts `Localizable.strings` into `Bundle.module`.
func L(_ key: String) -> LocalizedStringKey {
    LocalizedStringKey(key)
}

/// Get a plain localized String from Bundle.module.
func LS(_ key: String) -> String {
    NSLocalizedString(key, bundle: Bundle.module, comment: "")
}

/// SwiftUI Text that correctly resolves from SPM Bundle.module.
struct LText: View {
    let key: String
    init(_ key: String) {
        self.key = key
    }
    var body: some View {
        Text(NSLocalizedString(key, bundle: Bundle.module, comment: ""))
    }
}
