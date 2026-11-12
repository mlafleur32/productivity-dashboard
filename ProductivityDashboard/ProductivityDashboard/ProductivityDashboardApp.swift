//
//  ProductivityDashboardApp.swift
//  ProductivityDashboard
//
//  Created by Matt Lafleur on 5/28/26.
//

import SwiftUI
import SwiftData

@main
struct ProductivityDashboardApp: App {
    let modelContainer: ModelContainer

    init() {
        let schema = Schema([
            AllowedSender.self,
            ClassificationCacheEntry.self,
            CloudVerdictEntry.self,
            ArchiveLogEntry.self,
            UnsubscribeLogEntry.self,
            CalendarActionLogEntry.self,
            VIPSender.self,
        ])
        // cloudKitDatabase: .none is explicit and load-bearing: ARCHITECTURE.md
        // mandates single-device, local-only storage — the classification
        // cache and allowlist encode a behavioral profile of the inbox that
        // must not leave this Mac. We hold NO CloudKit entitlement, so sync
        // can't happen anyway, but stating .none here means a future stray
        // capability checkbox can't silently turn it on.
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        do {
            // Demo mode (-DemoMode): a seeded IN-MEMORY store. The real
            // on-disk store — real allowlist, VIPs and logs — is never opened.
            if DemoMode.isActive {
                modelContainer = try DemoEnvironment.makeModelContainer(schema: schema)
            } else {
                modelContainer = try ModelContainer(for: schema, configurations: [configuration])
            }
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            if DemoMode.isActive {
                ContentView(calendar: DemoEnvironment.makeCalendar(),
                            inbox: DemoEnvironment.makeInbox(),
                            calendarActions: DemoEnvironment.makeCalendarActions())
                    .background(DemoWindowSizer())
            } else {
                ContentView()
            }
        }
        .modelContainer(modelContainer)
        // Large enough that the Assistant's summary and the first plan rows
        // show without scrolling. A saved frame wins over this, so demo mode
        // also turns restoration off and sizes its window to the screen
        // (DemoWindowSizer) for consistent screenshots and recordings.
        .defaultSize(width: 1280, height: 900)
        .restorationBehavior(DemoMode.isActive ? .disabled : .automatic)

        // Native macOS Settings window (app menu ▸ Settings…, ⌘,). Two tabs
        // that together form the privacy boundary's control surface: WHO may
        // reach the cloud (allowlist) and HOW (API key + model). A Scene gets
        // its own environment, so the container must be attached here as
        // well — it's the same instance, not a second store.
        Settings {
            TabView {
                AccountsSettingsView(store: DemoMode.isActive ? DemoCredentialsStore() as CredentialsStore : nil)
                    .tabItem { Label("Accounts", systemImage: "envelope") }
                VIPSettingsView()
                    .tabItem { Label("VIPs", systemImage: "star") }
                AllowlistSettingsView()
                    .tabItem { Label("Cloud Allowlist", systemImage: "cloud") }
                ClaudeAPISettingsView()
                    .tabItem { Label("Claude API", systemImage: "key") }
                EventSuggestionSettingsView()
                    .tabItem { Label("Event Suggestions", systemImage: "calendar.badge.plus") }
            }
        }
        .modelContainer(modelContainer)
        // Settings windows default to .contentSize resizability, which locks
        // manual resizing entirely — discovered when the Usage section grew
        // the Claude API pane past its original height. .contentMinSize keeps
        // the panes' min frames as the floor but lets the user drag larger.
        .windowResizability(.contentMinSize)
    }
}
