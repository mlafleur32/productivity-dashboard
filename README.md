# ProductivityDashboard

A native macOS assistant that turns email and calendar into a dashboard of what
needs attention, built around one rule: mail from a sender you haven't approved
never leaves your Mac.

A full write-up is coming. Until then, see [ARCHITECTURE.md](ARCHITECTURE.md)
for the design and [THREAT_PATTERNS.md](THREAT_PATTERNS.md) for the
security posture.

To try it without any accounts, open
`ProductivityDashboard/ProductivityDashboard.xcodeproj`, choose the
**ProductivityDashboard Demo** scheme, set your own team under Signing &
Capabilities if Xcode asks, and Run. Demo mode uses synthetic data only.
