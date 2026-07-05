//
//  PinGate.swift
//  HiddenCore
//
//  Fast, allocation-light check that decides whether a search-field string is a
//  hidden-area PIN. Mirrors the guard at the top of
//  Telegram/SourceFiles/hidden/hidden_layer_manager.cpp::tryIntercept and the
//  call site in dialogs_widget.cpp::submit().
//
//  The host wires this into its search bar's "submit/return" handler and MUST
//  run it BEFORE any search / index / network path, exactly like the desktop.
//

import Foundation

public enum PinGate {

    public static let pinLength = 4

    /// True iff `candidate` is exactly `pinLength` ASCII digits.
    /// A `true` result means: treat as PIN, clear the field, do NOT search.
    public static func isPinCandidate(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == pinLength else { return false }
        for scalar in trimmed.unicodeScalars {
            if scalar < "0" || scalar > "9" { return false }
        }
        return true
    }
}
