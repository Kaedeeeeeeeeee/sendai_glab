// LocalizationKey.swift
// SDGCore
//
// Type-safe namespace for every key that appears in
// Resources/Localization/Localizable.xcstrings.
//
// NOTE (Phase 2): the full enumeration (~564 keys) will be generated from
// the compiled .xcstrings file by a swiftgen-style tool. For P0-T2 we ship
// only the schema shape and a handful of sample keys so downstream code
// has something concrete to import. Do not hand-edit this file to add
// hundreds of keys; wire up codegen instead.

import Foundation

/// Root namespace for localization keys used by SDG-Lab UI code.
///
/// Usage:
/// ```swift
/// Text(L10n.UI.settingsTitle) // the LocalizationService looks it up
/// ```
///
/// Keys are plain `String`s, not wrapped types, because the String
/// Catalog runtime (`String(localized:)`) already operates on `String`
/// inputs. Type safety is provided by these constants being the only
/// sanctioned source of key literals.
public enum L10n {

    /// Keys used by generic UI chrome — buttons, screen titles, toolbars.
    public enum UI {
        /// Title shown at the top of the Settings screen.
        public static let settingsTitle = "ui.settings.title"

        /// Confirm-action button (e.g. modal "OK").
        public static let buttonConfirm = "ui.button.confirm"

        /// Close/dismiss-action button (e.g. modal "Cancel" / "X").
        public static let buttonClose = "ui.button.close"
    }

    /// Keys used by the dialogue / story system.
    public enum Story {
        /// Speaker tag used when the narrator (not a named character) is
        /// speaking.
        public static let speakerNarration = "story.speaker.narration"
    }
}
