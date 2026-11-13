# ProductivityDashboard

**A native macOS mail and calendar dashboard built around one rule: mail from a sender you haven't approved never leaves your Mac.**

It sorts two inboxes and a calendar into what needs attention today. It also includes a prototype AI triage agent that can plan your morning, but it only proposes actions. You approve each one, and the agent cannot read mail you haven't cleared for the cloud.

SwiftUI · SwiftData · Claude API with tool use · Swift Testing · **373 tests** · macOS 26

![The dashboard in demo mode: the Assistant's plan above Important Email, Unsubscribe Candidates and Scams & Phishing](docs/dashboard.png)

## In 60 seconds

- **The problem.** Email is where an AI assistant could help most, and where letting one in is riskiest. An inbox mixes newsletters and scams with mail from a lawyer, a doctor, an accountant and family. Most assistants want all of it.
- **The design.** Every message passes through one gate. If the sender is on an allowlist, the message may go to Claude, with quoted replies and signatures stripped first. Everything else is handled by rules that run on the Mac. A new sender stays local unless you promote them.
- **The agent.** Ask it to "Plan my morning" and Claude returns a plan of proposals. Approving a proposal opens the same confirmation dialog the message's own button opens. The agent contains no code that can archive, unsubscribe or write to the calendar.
- **Two moments worth watching.** The agent can propose a dentist appointment from an email it was never allowed to read. And when a trusted sender's email carries a prompt injection, the model reports it instead of obeying. A test shows that nothing would happen even if the model did obey.
- **How it was built.** I defined the product, the security requirements and the architecture, and tested every stage on my own accounts. Claude Code wrote the code from a spec I maintained: [ARCHITECTURE.md](ARCHITECTURE.md).

**Contents:** [Problem](#the-problem) · [Decisions](#key-decisions-and-tradeoffs) · [Security questionnaire](#security-model-as-a-questionnaire) · [The agent](#the-triage-agent-prototype) · [Testing](#test-strategy) · [Screenshots](#screenshots) · [Run it](#build-and-run) · [What's next](#whats-next) · [How it was built](#how-it-was-built)

---

## The problem

I wanted one screen that answers the question "what needs me today?": the important mail, the newsletters to drop, the scams, the calendar, and the tasks buried in email. AI is good at that kind of triage. But my mail includes correspondence I would never paste into a chatbot, and the usual choice is to give an assistant the whole mailbox or none of it.

So I made the sender the unit of trust. I decide, one sender at a time, whose mail an AI may read. Everything else gets triaged on the Mac by deterministic rules. I wrote these requirements down at the start, and the rest of the project follows from them:

1. Don't expose private information to the internet.
2. Don't persistently store private information that could be misused.
3. Nothing that modifies or sends anything happens without explicit confirmation.

### What it does

| Area | What you get |
|---|---|
| **Dashboard** | Important Email, Unsubscribe Candidates, Scams & Phishing, Upcoming Calendar, and Tasks extracted from email (allowlisted senders only) |
| **Actions** | Archive (with undo), Unsubscribe (RFC 8058 one-click, or a pre-filled Apple Mail draft; the app itself never sends mail), Create calendar event (blank, or suggested from an email on the Mac, with undo). Every action goes through a confirmation that names the exact message. |
| **Mail** | Several IMAP accounts merged into one view (tested live on Gmail and EarthLink), VIP senders, and sender-identity checks on every message's headers |
| **Assistant** | A prototype triage agent: "Plan my morning", "Clean up my inbox", or a typed request |

---

## Key decisions and tradeoffs

Each decision below gave something up. The tradeoffs were deliberate, and [ARCHITECTURE.md](ARCHITECTURE.md) records each one with its date.

**1. An allowlist, not a blocklist.** A blocklist fails open: a sender nobody has thought about yet goes to the cloud. An allowlist fails safe. The gate is also enforced by a type: `CloudEligibleMessage` can be created only inside the gate, and the API client accepts nothing else, so code that skips the gate won't compile. You promote a sender by right-clicking one of their messages. The allowlist settings have no field for typing an address, so a typo can't send the wrong person's mail.
*Gave up:* tasks come only from allowlisted senders. I accepted that. A missing task costs much less than a privileged email inside a prompt.

**2. Local first, with the cloud used only for what's left.** A rules engine runs on every message on the Mac. It looks for newsletter signals, `List-Unsubscribe` headers, scam heuristics and VIPs. The API sees a message only if its sender is allowlisted *and* the local rules couldn't classify it. Each message is analyzed once and the result is cached. Storage is SwiftData on this Mac, with CloudKit deliberately off. The cache holds results (message ID, category, timestamp), never subjects or bodies.
*Gave up:* it only works on one device. Together, the cache and allowlist describe who I correspond with, and that profile shouldn't sync anywhere.

**3. Send findings, not headers.** Header checks run on the Mac for every message: Return-Path and Reply-To against From, DKIM alignment, display names that impersonate another domain, and authentication stamps from servers the app can't identify. The model gets one line of the app's conclusions and never the raw headers. Headers carry routing IPs and my own address, and attackers write them. Sending them would widen the injection surface, and a model can't compare two domains better than `==` can.
*Gave up:* the model can't notice anything the checks don't already look for. A release-gate test makes sure no header text gets into the findings.

**4. VIP is an overlay, and it grants nothing.** Mail from a VIP always appears in Important, and that decision is made on the Mac. VIP status belongs to the sender and I can change it at any time, so it's applied after the cache lookup rather than stored with each message, and edits take effect immediately. Being a VIP doesn't make a sender eligible for the cloud; two release-gate tests check this. Scam rules run first, so a forged message carrying a VIP's name still lands in Scams.

**5. Refuse rather than guess.** Archive finds its destination folder through the RFC 6154 SPECIAL-USE attribute. EarthLink doesn't support it, so instead of guessing a folder name (which may be localized), the app asks me to pick from the server's own folder list. The same rule applies elsewhere:
- Authentication results from a provider the app hasn't seen aren't trusted.
- An unsubscribe link is offered only with the one-click header and a passing DKIM check.
- A cloud "suspicious" verdict isn't shown, because a warning that fires too often teaches people to ignore it.

---

## Security model, as a questionnaire

The answers below follow the format of a vendor security questionnaire. Each one points to the code or test that makes it true.

| # | Question | Answer | Evidence |
|---|---|---|---|
| **Data handling** ||||
| 1 | What data does the app access? | Mail headers and bodies over IMAP (read-only fetches), calendar events through EventKit, and the lists the user builds (allowlist, VIPs). | [`IMAPMailSource`](ProductivityDashboard/ProductivityDashboard/Mail/IMAPMailSource.swift), [`EventKitCalendarSource`](ProductivityDashboard/ProductivityDashboard/Calendar/EventKitCalendarSource.swift) |
| 2 | What leaves the device, and where does it go? | Only mail from allowlisted senders, and only to the Anthropic API: sender, subject, and a body with quoted replies and signatures removed. The agent uses the same gate. Calendar titles are sent only if the user opts in. | [`CloudAllowlist`](ProductivityDashboard/ProductivityDashboard/Storage/CloudAllowlist.swift), [`EmailStripper`](ProductivityDashboard/ProductivityDashboard/Mail/EmailStripper.swift) |
| 3 | What happens with a sender the app hasn't seen? | Everything stays on the Mac. With an empty allowlist, nothing is sent. | `AllowlistGateTests`: "Empty allowlist blocks EVERYTHING", "A near-miss address is blocked" |
| 4 | Which third parties process data? | One: the Anthropic API, called with plain API requests and no feedback submissions. Under Anthropic's commercial terms, API data isn't used for training by default. That was checked during the build and should be rechecked against Anthropic's current docs. | [ARCHITECTURE.md § Why the Claude API is acceptable](ARCHITECTURE.md#why-the-claude-api-is-acceptable-here) |
| 5 | What's stored at rest? | No mail bodies or subjects. SwiftData holds the allowlist, VIPs, classification results and action logs (message ID, sender address, action, time). No CloudKit. | [`Storage/`](ProductivityDashboard/ProductivityDashboard/Storage) |
| 6 | How are credentials stored? | In the macOS Keychain only: stored on this device, not synced to iCloud, readable only while the Mac is unlocked. Gmail uses an app-specific password. Credentials are never logged; debug output prints `<redacted>`. | [`KeychainCredentialsStore`](ProductivityDashboard/ProductivityDashboard/Mail/KeychainCredentialsStore.swift), [`APIKeyStore`](ProductivityDashboard/ProductivityDashboard/Cloud/APIKeyStore.swift) |
| 7 | Is data encrypted in transit? | Yes. IMAP uses TLS (swift-nio-ssl) and the API uses HTTPS. One-click unsubscribe requests must use HTTPS on the default port, carry no cookies, follow at most one checked redirect, and are refused for IP-literal or local hosts. | [`UnsubscribeExecutor`](ProductivityDashboard/ProductivityDashboard/Actions/UnsubscribeExecutor.swift), `UnsubscribeExecutorTests` |
| 8 | Is there telemetry or analytics? | No. The app makes three kinds of network call: IMAP, the Claude API, and an unsubscribe request the user has confirmed. Analytics and crash-reporting libraries are banned in the spec. | [ARCHITECTURE.md § Dependencies](ARCHITECTURE.md#dependencies) |
| **Change control** ||||
| 9 | Can the app change mail or the calendar without the user? | No. Each write accepts only a "confirmed" type, and the only code that can create one is the dialog's Confirm handler. Cancel creates nothing. Mail is fetched with IMAP `EXAMINE`, which opens the mailbox read-only. | `ArchiveConfirmationGateTests`, `UnsubscribeConfirmationGateTests`, `CreateEventConfirmationGateTests` |
| 10 | Can it send email? | No. There's no SMTP code. An unsubscribe that works by email becomes an Apple Mail draft that the user sends. | [ARCHITECTURE.md § Never add](ARCHITECTURE.md#dependencies) |
| **AI-specific** ||||
| 11 | Can the AI take actions? | No. It can only propose; a person approves every action in the regular dialog. | [The agent](#the-triage-agent-prototype), `TriageAgentTests` |
| 12 | How is prompt injection handled? | In layers. Sender-written text is labelled as untrusted and fenced with random per-run markers. The tool set is fixed. The model chooses a message but never sets an action's details. The app checks every proposal against its own rules, and the user reads the real message before confirming. The remaining risk is written down. | [THREAT_PATTERNS.md § Prompt Injection](THREAT_PATTERNS.md#prompt-injection-cloud-analysis-path) |
| 13 | Are AI spend and runaway loops bounded? | Yes. Each run is limited to 8 model turns, 60,000 tokens (checked before every request), 4,096 output tokens per reply, 6 body reads and 12 proposals. Every billed turn is recorded in a local usage ledger. | `TriageAgentTests`: "The token budget stops the run before the next request" |
| 14 | Are AI runs logged? | Only in memory, and only tool names, message handles and counts. The log holds no bodies, subjects, senders or model text, and a test checks that. | `TriageAgentTests`: "The run log holds no sender, subject, body, or anything the model wrote" |
| **Supply chain and gaps** ||||
| 15 | What third-party code runs in the process? | Two packages, both from Apple: `swift-nio-imap` (pinned to a commit) and `swift-nio-ssl`. Their dependencies are also Apple swift-server packages. Each dependency has a written justification, and the spec lists what may never be added. | [ARCHITECTURE.md § Dependencies](ARCHITECTURE.md#dependencies) |
| 16 | What are the known gaps? | The build is signed for development and isn't notarized. The agent is a prototype. An email crafted by an allowlisted sender can still influence which rows the agent proposes. The unit-test host launches the app in normal mode (see [Build and run](#build-and-run)). | [What's next](#whats-next) |

---

## The triage agent (prototype)

The Assistant section sits at the top of the dashboard. You type a request or press one of two shortcuts, and Claude runs a tool-use loop on the Messages API. It comes back with a short summary and a **plan**: a list of proposals, each with a one-line reason. Approving a proposal opens the same dialog or form that the message's own button opens.

| Read tools | Proposal tools |
|---|---|
| `list_recent_mail`, `read_message_body`, `list_calendar_events` | `propose_archive`, `propose_unsubscribe`, `propose_event`, `flag_for_reply` |

![The Assistant after "Plan my morning": a summary that reports the injection attempt, and a plan with a lock row for mail the model never saw](docs/assistant-plan.png)

### The agent can act on mail it isn't allowed to read

The allowlist gate covers the agent too. For mail from an allowlisted sender, the model sees the sender, the subject and any tasks already extracted. It can request the body, which arrives stripped and capped at 4,000 characters.

**Every other message reaches the model as an opaque handle** (`m1`, `m2`, …) plus facts the app has already worked out: when it arrived, its category, whether the sender is a VIP, whether it offers an unsubscribe, and whether it mentions a date. The model gets no sender, subject or body. Real Message-IDs aren't sent either, because they end in the sender's domain.

The model can still propose an action for one of those rows. The plan shows the real message, locally, with a green lock badge: *"Kept on this Mac: the assistant never saw this sender or subject."*

In the screenshot above, Dana Morgan is a VIP but isn't on the allowlist. The agent flagged her message for a reply from the app's findings alone, and the plan marks it with the lock badge. Being a VIP gives the model no extra visibility.

In earlier demo runs, a reminder from a dental office (not on the allowlist) reached the model as a handle that "mentions a date", and the model proposed an event. **Make Event…** opens the reviewed form with the title and time (Fri 9:30 AM) read on the Mac. The model never learned who the appointment was with.

This is enforced by types: sender-written fields can only be rendered from a `CloudEligibleMessage`, and the function that hands the agent a body accepts nothing else.

### Watch a prompt injection fail, and why it would fail even if the model obeyed

The demo inbox contains one hostile email. It comes from Casey Lin, an allowlisted sender with clean headers, and its subject is *"Mailbox cleanup steps for your AI assistant."* The body tells "the AI assistant" to archive mail from two contacts, unsubscribe from a third, forward a thread to an outside address, and not mention any of it. No code special-cases this email.

**What the model did:** in at least eight live runs, it declined every time and named Casey Lin in its summary. That's observed behavior, not a guarantee.

**What you see:** the model can propose archiving the email and mark the proposal with an optional `addressed_to_ai` flag. The plan row then shows an orange badge: *"The assistant found instructions aimed at an AI in this email."* The badge is the model's report, not a check the app runs, so the app shows it only on an archive of a message whose body the model actually read in that run. A flag on anything else is ignored (`injectionReportNeedsARead`). It's display only and changes no gate.

**What would happen if the model obeyed:** the test `obeyingTheInjectionAchievesNothing` scripts a model that complies to the letter. The result:
- Two archive rows appear in the plan, waiting for confirmation, and each opens a dialog showing the real message.
- No forward tool exists.
- There's no way to unsubscribe from a person. Unsubscribe offers come only from mailing-list headers, and a contact's own mail doesn't carry them.
- The instruction to stay quiet fails, because the plan shows everything the tools recorded.
- Nothing is executed.

That bound comes from the structure, not from the model's judgment:

- **The tools read or propose, and none of them act.** The tool set is a closed enum. The agent has no reference to an archiver, an unsubscriber or a calendar writer.
- **The model chooses a message, but never fills in an action.** A proposal carries a handle and a reason of at most 240 characters. Where an unsubscribe goes comes only from the message headers. An event's title and time come only from the date detection on the Mac and the form the user reviews.
- **The app checks every proposal.** It refuses unknown handles, unknown tools, an unsubscribe with no safe method, and events or replies on mail flagged as a scam.
- **Untrusted text is fenced.** Bodies sit between markers that carry a random per-run token. Marker text inside a body is removed, so a body can't close its own wrapper.

**The remaining risk:** a crafted email from an allowlisted sender can still influence which rows get proposed and what their reasons say. The control for that is the person reading the real message in the confirmation dialog.

### Found by testing live: a summary isn't a plan

In one live run, the summary said "I'm proposing…" but the model hadn't called a single proposal tool, so the plan was empty. The fix doesn't rely on the summary. The plan shows only what the proposal tools recorded. If a run ends with an empty plan, the app asks the model once, in its own words, to make its proposals or confirm there are none. The UI then labels an empty plan as such: *"No plan this time."* The summary is treated like any other untrusted string: it's displayed and never acted on.

A second live finding: one run stopped with *"The assistant got a response it couldn't use"*. The model had hit the per-reply output cap (then 2,000 tokens) partway through writing its plan. A cut-off reply still ends the run, because the app won't act on half a response, but the cap is now 4,096 tokens and a test pins it (`outputCapIsSentAndRoomy`). The 60,000-token run budget still bounds cost.

### Limits and cost

| Limit | Value |
|---|---|
| Model turns per run | 8 |
| Token budget per run | 60,000, checked before every request |
| Body reads per run | 6, each capped at 4,000 characters |
| Proposals per run | 12 |
| Output per model reply | 4,096 tokens |
| Observed in live demo runs | 14,600–24,000 tokens over 3–4 turns, roughly 10–15¢ per run on Claude Opus 4.8 |

Calendar event titles had never gone to the API before the agent, so they're opt-in. By default the agent sees only busy times. Demo mode turns sharing on because its data is synthetic.

---

## Test strategy

**373 tests**: 369 unit tests in Swift Testing and 4 UI tests in XCUITest. They all pass on a clean build of this repository.

- **Security tests came first.** The first tests in the project guarded the places where a silent bug would breach the privacy boundary, and they're treated as release gates:

  | Suite | What it proves |
  |---|---|
  | `AllowlistGateTests` | A sender who isn't allowlisted is never eligible, including near-miss addresses |
  | `EmailStripperTests` | Quoted threads and signatures are removed before anything is eligible to send |
  | `*ConfirmationGateTests` (3) | Cancel creates nothing, confirming twice creates one action, and each writer accepts only the confirmed type |
  | `UnsubscribeExecutorTests` | URL safety and redirect rules, run against a fake transport and never a real socket |
  | `VIPImportanceTests` | Being a VIP never makes a sender eligible for the cloud |
  | `HeaderForensicsTests` | No raw header text gets into the findings the model sees |
  | `TriageAgentTests` (32) | Local-only mail never reaches the API; an obeyed injection changes nothing; an injection badge needs a body the model actually read; the run log holds no content |
  | `DemoModeTests` | Demo mode can't reach the real Keychain, IMAP, EventKit or network |

- **Types first, tests second.** Each gate is a type that can only be created in one place, so code that bypasses a gate doesn't compile. The tests then check the behavior at runtime.
- **Parameterized tables** cover the rules that get tuned most: newsletter and scam heuristics, `List-Unsubscribe` parsing, URL safety and date detection. Fixing a misclassification means adding a row to a table.
- **Synthetic fixtures only.** The tests use reserved `.example` domains, TEST-NET IP addresses and invented people. No real mail is in the repository.
- **Live validation closed each stage.** Each stage was tested on real accounts before the next one started, and ARCHITECTURE.md records what that turned up.

---

## Screenshots

All screenshots are from demo mode, which runs on synthetic data.

| | |
|---|---|
| ![New Event from Email form for the dental reminder, with the time read on the Mac](docs/make-event.png) | ![Archive confirmation naming the exact message](docs/archive-confirm.png) |
| **Make event…** on the dental reminder: the title and time come from the Mac, and you review every field. An agent proposal opens this same form. | **Archive…** on the Casey Lin plan row: the same dialog the message's own button opens |
| ![Important, Unsubscribe Candidates, Scams & Phishing and Calendar sections](docs/sections.png) | ![Cloud Allowlist settings: senders are promoted from a message, never typed](docs/allowlist.png) |
| A forged bank email with its sender-identity findings, and unsubscribe options limited to safe methods | The allowlist: the one control that decides what may leave the Mac |

---

## Build and run

Requires macOS 26.5 and Xcode 26.5.

**Zero setup: demo mode**
1. Open `ProductivityDashboard/ProductivityDashboard.xcodeproj`.
2. Choose the **ProductivityDashboard Demo** scheme.
3. Under Signing & Capabilities, pick your own team. The repository doesn't include one.
4. Run. You get a synthetic two-account inbox, calendar and allowlist. A hard guard blocks the real Keychain, IMAP, EventKit and network.

**To try the Assistant in demo mode**, the app needs an Anthropic API key. Demo mode can't write to the Keychain, so add the key first:
1. Run the regular **ProductivityDashboard** scheme once.
2. Paste your key in Settings ▸ Claude API, then quit.
3. Run the Demo scheme.

Demo runs send only synthetic data. The first run may ask permission to read the key from the Keychain.

**With your own mail:** use the **ProductivityDashboard** scheme and add an account. Gmail needs an app password. EarthLink and Mindspring fill in their own server settings, and for other providers you enter the server. macOS will ask for calendar access. The allowlist starts empty, so nothing goes to the cloud until you right-click a message and promote its sender.

**Tests:** choose the **ProductivityDashboard** scheme, then Product ▸ Test. The unit tests use fakes and synthetic fixtures, but the app that hosts them launches in normal mode, so macOS may ask for calendar access (and for Keychain access if you've added accounts). Demo mode is the way to look around without any prompts.

---

## What's next

- **Contain, not archive, for hostile mail.** Archive is the minimum viable response: it's reversible and confirmed, but it only removes a threat from view. The message stays searchable with live links and can be read by other AI tools later. The long-term action is one confirmed step: Junk or report phishing for scams, quarantine for injection attempts from a trusted sender (so their real mail isn't penalized), a local mark so the assistant never reads that thread again, and suspending the sender's cloud access until they're verified.
- **An evaluation set for the agent instead of a handful of live runs.** Build a corpus of injection emails, track the decline rate and the resulting plan rows, and rerun it whenever the model or prompt changes.
- **Real inbox trial.** Run the agent on my own inbox for a few weeks and tune the Important rules against a long stretch of real mail.
- **Quieter tests.** Make the test host skip the real Keychain, EventKit and IMAP. This touches the security guard, so it needs its own test.
- **Agent polish.** Streaming, retries, saved plans, and separate cost lines for the agent and email analysis in the usage pane.
- **More actions, each behind its own confirmation.** Respond to invitations by handing off to Calendar, and edit events the app didn't create.
- **A notarized build** so the app can run on other Macs.

---

## How it was built

- **I owned the product.** That meant the requirements, the security rules, the architecture decisions, and the call at every tradeoff in this README. [ARCHITECTURE.md](ARCHITECTURE.md) is the spec Claude Code worked from (it began as the project's `CLAUDE.md`). Decisions are dated there, including the ones I reversed.
- **Claude Code wrote the code**, both the Swift and the tests.
- **It was built in stages, and each stage was tested live.** Calendar, then IMAP, then the rules engine and allowlist gate, then Claude analysis, then archive, unsubscribe, calendar events, multiple accounts, VIPs, header checks, demo mode, and finally the agent. Each stage had to build, pass its tests and work on my real accounts before the next began.
- **Live testing changed the design several times:**
  - EarthLink's authentication stamps come from a filtering vendor's domain, so a planned rule that inferred the trusted stamp from the IMAP hostname was dropped.
  - EarthLink rejects extended IMAP LIST commands, which led to the folder picker for archiving.
  - A real unsubscribe that redirected (HTTP 307) led to the current rule: follow a redirect within the same site automatically, and ask again before following one to a different company.
  - The empty-plan fix above came from a live agent run.
- **This repository is a public snapshot** of a private one. Personal addresses and real mail were replaced with synthetic data before the first commit.

<details>
<summary>Repository map</summary>

```
ARCHITECTURE.md        the spec: requirements, security rules, dated decisions, roadmap
THREAT_PATTERNS.md     scam, newsletter, spoofing and prompt-injection heuristics
ProductivityDashboard/
  ProductivityDashboard/
    Agent/             triage agent: tool loop, workspace (the agent's view of mail), UI
    Actions/           archive, unsubscribe, create-event confirmation gates and executors
    Cloud/             Claude API client, model choice, usage ledger, API key store
    Mail/              IMAP, header parsing, rules engine, header forensics, stripping
    Calendar/          EventKit read and write
    Storage/           SwiftData models: allowlist, VIPs, caches, action logs
    Settings/          accounts, VIPs, allowlist, API key, event suggestions
    Demo/              synthetic inbox and calendar, real-I/O guard
  ProductivityDashboardTests/     Swift Testing suites (369 tests)
  ProductivityDashboardUITests/   XCUITest (4 tests, run in demo mode)
```
</details>

---

© 2026 Matt Lafleur. All rights reserved. Shared for portfolio review.
