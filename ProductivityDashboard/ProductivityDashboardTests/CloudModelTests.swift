//
//  CloudModelTests.swift
//  ProductivityDashboardTests
//
//  The model picker's resolution rule: whatever is (or isn't) in
//  UserDefaults, the analyzer must always land on a valid model from the
//  curated list — unknown or missing stored values fold to the default,
//  never crash, never produce an un-curated ID.
//

import Testing
@testable import ProductivityDashboard

struct CloudModelTests {

    @Test("Nothing stored resolves to the default (Opus 4.8)")
    func nilResolvesToDefault() {
        #expect(CloudModel.resolve(storedValue: nil) == .opus48)
        #expect(CloudModel.defaultModel == .opus48)
    }

    @Test("Each curated ID resolves to itself", arguments: CloudModel.allCases)
    func curatedIDsRoundTrip(_ model: CloudModel) {
        #expect(CloudModel.resolve(storedValue: model.rawValue) == model)
    }

    @Test("Unknown stored IDs fold to the default", arguments: [
        "claude-opus-4-5",        // real model, deliberately not curated
        "claude-fable-5",         // real model, deliberately not curated
        "gpt-9",                  // nonsense
        "",                       // empty
        "CLAUDE-OPUS-4-8",        // wrong case — raw values are exact
    ])
    func unknownFoldsToDefault(_ stored: String) {
        #expect(CloudModel.resolve(storedValue: stored) == .opus48)
    }

    @Test("Curated list is exactly the three chosen models, Opus first")
    func curatedListPinned() {
        #expect(CloudModel.allCases.map(\.rawValue) == [
            "claude-opus-4-8",
            "claude-sonnet-5",
            "claude-haiku-4-5",
        ])
    }
}
