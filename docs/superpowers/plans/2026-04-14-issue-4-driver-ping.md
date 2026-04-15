# Driver Ping (Kind 3189) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a rider-to-driver ping feature (Kind 3189) that lets riders nudge offline trusted drivers to come online, breaking the cold-start deadlock in the decentralized ridesharing model.

**Architecture:** New dedicated Nostr event kind 3189 (`driverPingRequest`) — NIP-44 encrypted to driver, carrying a RoadFlare HMAC auth proof so the driver app can authenticate the sender without walking the Kind 30011 list. Sender-side rate limiting (10 min cooldown per driver) lives in `AppState`. UI: bell button on offline driver cards in `DriversTab`, plus a "Ping a Driver" CTA in the `RideRequestView` empty state.

**Tech Stack:** Swift, SwiftUI, CryptoKit (HMAC<SHA256>), Swift Testing framework (`@Test`/`@Suite`/`#expect`), existing `RideshareEventBuilder` pattern, existing `ToastModifier` system.

---

## Pre-flight: Verification Notes (Read Before Coding)

These were confirmed by research before writing this plan — don't re-verify them, just trust them:

- **CryptoKit is already imported** in `RidestrSDK/Sources/RidestrSDK/Nostr/NostrKeypair.swift`. Adding `import CryptoKit` to `RideshareEventBuilder.swift` is safe and correct.
- **`FollowedDriver.hasKey`** is computed as `roadflareKey != nil` (`RoadflareModels.swift:94`). This is the visibility gate for the bell button.
- **`RoadflareKey.privateKeyHex`** is a `public let` 64-char hex string. This is the material used for HMAC.
- **Drivers tab is `selectedTab = 1`** (`MainTabView.swift`). Use `appState.selectedTab = 1` to navigate there.
- **Toast system**: `.toast($message, isError: false)` view modifier — `message` is `@State private var pingToastMessage: String?`. A non-error toast shows a green checkmark.
- **No rate-limiter utility exists** — implement from scratch with a dictionary in `AppState`.
- **No CHANGELOG.md exists** — skip that doc task; PRD and ANDROID_DEEP_DIVE updates are sufficient.
- **Next ADR number is 0008**, but the spec calls for ADR-0009. Use **0009** as specified (0008 is reserved for an in-flight decision).
- **Test framework is Swift Testing** (`@Suite`, `@Test`, `#expect`), not XCTest. Match existing test style in `RideshareEventBuilderTests.swift`.

---

## Branching

- **roadflare-ios**: work happens on `claude/issue-4-driver-ping`. Confirm with `git branch --show-current` before starting. This plan assumes the worktree is already on that branch.
- **ridestr (Android)**: create a parallel `feature/issue-4-driver-ping` branch in the ridestr repo. That work is tracked in a separate plan in the ridestr repo; the spec it needs is Section 1 and Task 7.4's `ANDROID_DEEP_DIVE.md` additions from this plan.
- **Release coordination**: see "Release Coordination" section below.

## Release Coordination

The ping feature has two sides that ship together:

- **roadflare-ios** (this plan): rider-side sender. Bell button, `sendDriverPing`, SDK builder, HMAC auth, UI entry points.
- **ridestr drivestr app**: driver-side receiver. Kind 3189 subscription, HMAC validation (±1 window check), deduplication (30s per-rider, 2 per 10 min global), local notification display. Tracked in a parallel plan in the ridestr repo on branch `feature/issue-4-driver-ping`. The protocol spec in Section 1 and the validation pseudo-code in `ANDROID_DEEP_DIVE.md` (Task 7.4 additions) are the authoritative input for that plan.

Both plans execute in parallel; both PRs merge in lockstep; both apps ship in the same release cycle. If one side lags by a few hours or days, the feature still degrades gracefully — pings sent with no receiver are indistinguishable from offline drivers not responding, because the feature is inherently speculative (see ADR-0009 "Graceful degradation" note).

---

## 1. Protocol Specification (for drivestr cross-platform mirror)

This section is the canonical spec. Implement exactly this on both iOS and Android.

### 1.1 Event Kind

| Field | Value |
|---|---|
| Kind number | **3189** |
| Name | `driverPingRequest` |
| Semantics | Regular (non-replaceable). One event per ping. |
| Visibility | Sent to specific driver pubkey only (NIP-44 encrypted). |

### 1.2 Event Structure

```
kind: 3189
pubkey: <rider's Nostr pubkey (hex)>
content: <NIP-44 encrypted JSON — see 1.3>
tags:
  ["p",          "<driver pubkey hex>"]
  ["t",          "roadflare-ping"]
  ["auth",       "<HMAC hex — see 1.4>"]
  ["expiration", "<unix epoch + 1800>"]
```

> **Tag ordering** is builder convention, not protocol-mandated. The Android receiver (and any future iOS consumer) locates tags by name using `.find { $0[0] == "auth" }` — insertion order does not affect correctness.

### 1.3 Content (NIP-44 Encrypted JSON)

Encrypted to the **driver's Nostr identity pubkey** using the **rider's Nostr keypair** (same pattern as all other protocol events).

```json
{
  "action":    "ping",
  "riderName": "<rider's display name from their profile>",
  "timestamp": <unix epoch integer>
}
```

There is **no `message` field**. Sender-controlled text must not be displayed directly on the driver's lock screen — NIP-44 encryption and the HMAC auth proof establish that the sender is an approved follower, but they do not guarantee the sender is honest about arbitrary text content. The receiver builds its own notification body locally (e.g. `"<riderName> is hoping you come online"`). See `ANDROID_DEEP_DIVE.md` §"Driver Ping (Kind 3189)" for the full security rationale and receiver implementation guidance.

### 1.4 HMAC Auth Proof

The `auth` tag value is a lowercase hex-encoded **HMAC-SHA256** that proves the sender is a known follower holding the driver's RoadFlare private key.

**Inputs:**

```
key:     driver's RoadFlare private key bytes (32 bytes, from the 64-char hex privateKeyHex)
message: UTF-8 encoding of the string:
           driverPubkey + riderPubkey + String(timeWindow)
         where timeWindow = floor(currentEpochSeconds / 300)
```

**`timeWindow`** is the current **5-minute bucket** (integer division by 300). The driver app computes the expected HMAC using the same `timeWindow` at validation time. A ±1 bucket tolerance (check `timeWindow`, `timeWindow - 1`, `timeWindow + 1`) accounts for clock skew and window boundaries. This provides replay protection: an intercepted ping is useless outside the 10–15 minute validity window, and the 30-minute event expiry is the outer bound.

**Pseudo-code for both iOS and Android:**

```
timeWindow  = epochNow / 300            // integer division
riderPubkey = nostrKeypair.publicKeyHex
message     = driverPubkey + riderPubkey + str(timeWindow)
hmac        = HMAC-SHA256(key=hexToData(roadflareKey.privateKeyHex), message=message.utf8)
authTag     = hex(hmac)                 // lowercase
```

### 1.5 Rate Limits & Deduplication

| Side | Rule |
|---|---|
| Sender (rider iOS) | Max 1 ping per driver per 10 minutes. Enforced in `AppState.pingCooldowns`. In-memory only; resets on app restart. |
| Receiver (driver Android) | 30-second dedup window per rider pubkey. |
| Receiver (driver Android) | Global cap: 2 authenticated pings per 10-minute window across all senders. Applied after HMAC auth. |
| Mute | Driver can mute rider pubkeys; muted pings discarded after HMAC auth, before notification. |

Unauthenticated pings (HMAC mismatch) are silently discarded on the driver side.

### 1.6 Expiry

Event carries `["expiration", "<epoch + 1800>"]` (30 minutes). Relay will not store or forward expired events. A rider can re-ping after cooldown expiry regardless of event expiry.

---

## 2. File Map

| File | Action | What changes |
|---|---|---|
| `RidestrSDK/Sources/RidestrSDK/Nostr/EventKind.swift` | Modify | Add `case driverPingRequest = 3189`; add `EventExpiration.driverPingMinutes = 30` (enum lives here at line 90) |
| `RidestrSDK/Sources/RidestrSDK/Nostr/Constants.swift` | Modify | Add `NostrTags.auth` and `NostrTags.roadflarePingTag` |
| `RidestrSDK/Sources/RidestrSDK/Nostr/RideshareEventBuilder.swift` | Modify | Add `driverPingRequest(driverPubkey:riderName:roadflareKey:keypair:)` builder + internal `hexToData` helper |
| `RidestrSDK/Tests/RidestrSDKTests/Nostr/RideshareEventBuilderTests.swift` | Modify | Add 4 tests for Kind 3189 builder |
| `RoadFlare/RoadFlareCore/ViewModels/AppState.swift` | Modify | Add `pingCooldowns`, `canPingDriver(_:)` instance method, `canPingDriver(_:using:)` static overload (for testability), `sendDriverPing(driverPubkey:)` |
| `RoadFlare/RoadFlareTests/AppState/CanPingDriverTests.swift` | Create | 5 unit tests covering `canPingDriver(_:using:)` static overload (no key / stale / online / on_ride / eligible) |
| `RoadFlare/RoadFlare/Views/Drivers/DriversTab.swift` | Modify | Add `onPing` to `DriverCard`, bell button, toast state on `DriversTab` |
| `RoadFlare/RoadFlare/Views/Ride/RideRequestView.swift` | Modify | Add "Ping a Driver" button to empty state |
| `decisions/0009-driver-ping-kind-3189.md` | Create | ADR for Kind 3189 and HMAC auth scheme |
| `PRD.md` | Modify | Add Kind 3189 to Appendix A event kinds table and local notifications table |
| `ANDROID_DEEP_DIVE.md` | Modify | Add Kind 3189 section for drivestr implementors |

---

## Task 1: SDK — EventKind and Constants

**Files:**
- Modify: `RidestrSDK/Sources/RidestrSDK/Nostr/EventKind.swift`
- Modify: `RidestrSDK/Sources/RidestrSDK/Nostr/Constants.swift`

- [ ] **Step 1.1: Add `driverPingRequest` to EventKind**

In `EventKind.swift`, add the new case in the "RoadFlare (regular events)" section, after `keyAcknowledgement`:

```swift
// RoadFlare (regular events)
case keyShare = 3186
case followNotification = 3187  // Real-time nudge only — Kind 30011 p-tags are source of truth
case keyAcknowledgement = 3188
case driverPingRequest = 3189   // Rider → driver availability nudge with HMAC auth proof
```

In the `defaultExpirationSeconds` switch, add:
```swift
case .driverPingRequest: EventExpiration.driverPingMinutes * 60
```

- [ ] **Step 1.2: Add `EventExpiration.driverPingMinutes` to EventKind.swift and tag constants to Constants.swift**

**`EventKind.swift`** — `EventExpiration` is declared as `public enum EventExpiration` at line 90 of this file (not in Constants.swift). Add after `roadflareFollowNotifyMinutes`:
```swift
public static let driverPingMinutes: TimeInterval = 30
```

**`Constants.swift`** — `NostrTags` lives here. Add after the existing hashtag values:
```swift
// Ping auth
public static let auth = "auth"
public static let roadflarePingTag = "roadflare-ping"
```

- [ ] **Step 1.3: Build SDK to verify no compile errors**

```bash
cd /path/to/repo/RidestrSDK && swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 1.4: Commit**

```bash
git add RidestrSDK/Sources/RidestrSDK/Nostr/EventKind.swift \
        RidestrSDK/Sources/RidestrSDK/Nostr/Constants.swift
git commit -m "feat(sdk): add Kind 3189 driverPingRequest event kind and constants"
```

---

## Task 2: SDK — Builder (TDD)

**Files:**
- Modify: `RidestrSDK/Tests/RidestrSDKTests/Nostr/RideshareEventBuilderTests.swift`
- Modify: `RidestrSDK/Sources/RidestrSDK/Nostr/RideshareEventBuilder.swift`

### Step 2.1 — Write failing tests first

- [ ] **Step 2.1: Add 4 tests to RideshareEventBuilderTests.swift**

Open `RidestrSDK/Tests/RidestrSDKTests/Nostr/RideshareEventBuilderTests.swift`. First, add `import CryptoKit` to the existing imports at the top of the file (after `import Foundation`). Then, at the end of the `@Suite("RideshareEventBuilder Tests")` struct (before the closing `}`), add:

```swift
// MARK: - Kind 3189 Driver Ping Request

@Test func buildDriverPingRequest_eventShape() async throws {
    let rider = try NostrKeypair.generate()
    let driver = try NostrKeypair.generate()
    let roadflareKey = RoadflareKey(
        privateKeyHex: String(repeating: "a", count: 64),
        publicKeyHex: String(repeating: "b", count: 64),
        version: 1,
        keyUpdatedAt: nil
    )

    let event = try await RideshareEventBuilder.driverPingRequest(
        driverPubkey: driver.publicKeyHex,
        riderName: "Alice",
        roadflareKey: roadflareKey,
        keypair: rider
    )

    // Event shape
    #expect(event.kind == EventKind.driverPingRequest.rawValue)
    #expect(event.pubkey == rider.publicKeyHex)
    #expect(EventSigner.verify(event))

    // Required tags
    #expect(event.referencedPubkeys.contains(driver.publicKeyHex))
    #expect(event.tagValues("t").contains("roadflare-ping"))
    #expect(event.tag("auth") != nil)
    #expect(event.expirationTimestamp != nil)

    // Expiry is roughly 30 minutes from now
    let now = Int(Date.now.timeIntervalSince1970)
    let expiry = try #require(event.expirationTimestamp)
    #expect(expiry > now + 1700)  // at least 28 minutes
    #expect(expiry < now + 1900)  // at most 32 minutes

    // Content is encrypted (not readable as plain JSON)
    #expect(!event.content.contains("\"action\""))
}

@Test func buildDriverPingRequest_contentDecryptable() async throws {
    let rider = try NostrKeypair.generate()
    let driver = try NostrKeypair.generate()
    let roadflareKey = RoadflareKey(
        privateKeyHex: String(repeating: "c", count: 64),
        publicKeyHex: String(repeating: "d", count: 64),
        version: 1,
        keyUpdatedAt: nil
    )

    let event = try await RideshareEventBuilder.driverPingRequest(
        driverPubkey: driver.publicKeyHex,
        riderName: "Bob",
        roadflareKey: roadflareKey,
        keypair: rider
    )

    // Driver can decrypt and read the content
    let decrypted = try NIP44.decrypt(
        ciphertext: event.content,
        receiverKeypair: driver,
        senderPublicKeyHex: rider.publicKeyHex
    )
    let json = try JSONSerialization.jsonObject(with: Data(decrypted.utf8)) as? [String: Any]
    let parsed = try #require(json)

    #expect(parsed["action"] as? String == "ping")
    #expect(parsed["riderName"] as? String == "Bob")
    let message = try #require(parsed["message"] as? String)
    #expect(message.contains("Bob"))
    let ts = try #require(parsed["timestamp"] as? Int)
    let nowEpoch = Int(Date.now.timeIntervalSince1970)
    #expect(ts > nowEpoch - 5 && ts < nowEpoch + 5, "timestamp should be within 5 s of now")
}

@Test func buildDriverPingRequest_hmacDeterministic() async throws {
    // Same inputs → same HMAC; different inputs → different HMAC.
    // Uses fixed keypairs and date to pin the 5-minute bucket.
    // Catches a wrong HMAC key source by recomputing the expected HMAC with
    // CryptoKit inside the test — if the builder uses the wrong key (e.g. the
    // rider's Nostr private key instead of roadflareKey.privateKeyHex), the
    // CryptoKit value won't match and the test fails.
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)  // bucket 3333
    let rider  = try NostrKeypair.fromHex(String(repeating: "bb", count: 32))
    let driver = try NostrKeypair.fromHex(String(repeating: "aa", count: 32))
    let roadflareKey = RoadflareKey(
        privateKeyHex: String(repeating: "ee", count: 32),
        publicKeyHex: String(repeating: "ff", count: 32),
        version: 1,
        keyUpdatedAt: nil
    )

    let event1 = try await RideshareEventBuilder.driverPingRequest(
        driverPubkey: driver.publicKeyHex,
        riderName: "Carol",
        roadflareKey: roadflareKey,
        keypair: rider,
        currentDate: fixedDate
    )
    let event2 = try await RideshareEventBuilder.driverPingRequest(
        driverPubkey: driver.publicKeyHex,
        riderName: "Carol",
        roadflareKey: roadflareKey,
        keypair: rider,
        currentDate: fixedDate
    )

    // Determinism: same inputs → same auth tag within one bucket
    #expect(event1.tag("auth") == event2.tag("auth"))

    // Correctness: recompute expected HMAC with CryptoKit using the same
    // message format the builder uses: driverPubkey + riderPubkey + str(timeWindow)
    let timeWindow = Int(fixedDate.timeIntervalSince1970) / 300  // 3333
    let message = Data((driver.publicKeyHex + rider.publicKeyHex + String(timeWindow)).utf8)
    let keyBytes = SymmetricKey(data: RideshareEventBuilder.hexToData(roadflareKey.privateKeyHex)!)
    let mac = HMAC<SHA256>.authenticationCode(for: message, using: keyBytes)
    let expectedHex = Data(mac).map { String(format: "%02x", $0) }.joined()
    #expect(event1.tag("auth") == expectedHex,
            "auth tag mismatch — wrong HMAC key source or message format?")

    // Key-sensitivity: different driver pubkey → different HMAC
    let driver2 = try NostrKeypair.fromHex(String(repeating: "cc", count: 32))
    let event3 = try await RideshareEventBuilder.driverPingRequest(
        driverPubkey: driver2.publicKeyHex,
        riderName: "Carol",
        roadflareKey: roadflareKey,
        keypair: rider,
        currentDate: fixedDate
    )
    #expect(event1.tag("auth") != event3.tag("auth"))
}

@Test func buildDriverPingRequest_rejectsInvalidDriverPubkey() async throws {
    let rider = try NostrKeypair.generate()
    let roadflareKey = RoadflareKey(
        privateKeyHex: String(repeating: "a", count: 64),
        publicKeyHex: String(repeating: "b", count: 64),
        version: 1,
        keyUpdatedAt: nil
    )

    await #expect(throws: RidestrError.self) {
        _ = try await RideshareEventBuilder.driverPingRequest(
            driverPubkey: "not-a-valid-pubkey",
            riderName: "Dave",
            roadflareKey: roadflareKey,
            keypair: rider
        )
    }
}
```

- [ ] **Step 2.2: Run tests to confirm they fail (builder not yet written)**

```bash
cd /path/to/repo/RidestrSDK && swift test --filter "buildDriverPingRequest" 2>&1 | tail -20
```
Expected: compile error — `driverPingRequest` not found on `RideshareEventBuilder`.

### Step 2.3 — Implement the builder

- [ ] **Step 2.3: Add `driverPingRequest` to RideshareEventBuilder.swift**

Open `RidestrSDK/Sources/RidestrSDK/Nostr/RideshareEventBuilder.swift`.

Add `import CryptoKit` at the top (after `import Foundation`):
```swift
import Foundation
import CryptoKit
```

Add the private hex-to-Data helper just before the closing `}` of the `enum RideshareEventBuilder` body:

```swift
// MARK: - Internal Helpers

/// Convert a lowercase hex string to raw bytes. Returns nil for odd-length or invalid chars.
/// Internal (not `private`) so `@testable import RidestrSDK` tests can call it
/// when recomputing HMAC-SHA256 values in-test.
static func hexToData(_ hex: String) -> Data? {
    guard hex.count % 2 == 0 else { return nil }
    var data = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let nextIndex = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
        data.append(byte)
        index = nextIndex
    }
    return data
}
```

Then add the builder method after the `// MARK: - Key Acknowledgement (Kind 3188)` section (the current last MARK in the file, at `RideshareEventBuilder.swift:454`), so kind numbers stay in ascending order:

```swift
// MARK: - Driver Ping Request (Kind 3189)

/// Build and sign a driver ping request event (Kind 3189).
///
/// Sent by a rider to an offline driver as an availability nudge.
/// Content is NIP-44 encrypted to the driver's identity pubkey.
/// Carries an HMAC-SHA256 auth proof so the driver app can authenticate
/// the sender without walking the Kind 30011 follower list.
///
/// Auth proof: HMAC-SHA256(key=hexToData(roadflareKey.privateKeyHex),
///                         msg=driverPubkey+riderPubkey+String(epoch/300))
///
/// - Parameters:
///   - driverPubkey: The driver's 64-character hex Nostr identity public key.
///   - riderName: The rider's display name (shown in the driver's notification).
///   - roadflareKey: The driver's RoadFlare key (held by the rider after approval).
///   - keypair: The rider's Nostr signing keypair.
///   - currentDate: Timestamp source for the HMAC time window, content timestamp,
///                  and event expiry. Defaults to `Date.now`. Inject a fixed date in
///                  tests (same pattern as `EventSigner.sign(createdAt:)`).
/// - Returns: A signed, encrypted Nostr event (Kind 3189).
/// - Throws: `RidestrError.crypto` if HMAC inputs are invalid or encryption fails.
public static func driverPingRequest(
    driverPubkey: String,
    riderName: String,
    roadflareKey: RoadflareKey,
    keypair: NostrKeypair,
    currentDate: Date = .now
) async throws -> NostrEvent {
    try validatePubkey(driverPubkey, label: "Driver pubkey")

    let nowEpoch = Int(currentDate.timeIntervalSince1970)

    // --- HMAC auth proof ---
    let timeWindow = nowEpoch / 300
    let hmacMessage = driverPubkey + keypair.publicKeyHex + String(timeWindow)
    guard let keyData = hexToData(roadflareKey.privateKeyHex) else {
        throw RidestrError.crypto(.invalidKey("RoadFlare key is not valid hex"))
    }
    let symmetricKey = SymmetricKey(data: keyData)
    let mac = HMAC<SHA256>.authenticationCode(
        for: Data(hmacMessage.utf8),
        using: symmetricKey
    )
    let authHex = Data(mac).map { String(format: "%02x", $0) }.joined()

    // --- Content ---
    let message = "\(riderName) is currently hoping you come online!"
    let contentDict: [String: Any] = [
        "action": "ping",
        "riderName": riderName,
        "message": message,
        "timestamp": nowEpoch
    ]
    guard let json = try? JSONSerialization.data(withJSONObject: contentDict),
          let plaintext = String(data: json, encoding: .utf8) else {
        throw RidestrError.crypto(.encryptionFailed(
            underlying: NSError(domain: "JSON", code: 0, userInfo: nil)
        ))
    }
    let encrypted = try NIP44.encrypt(
        plaintext: plaintext,
        senderKeypair: keypair,
        recipientPublicKeyHex: driverPubkey
    )

    // --- Tags ---
    let expiry = nowEpoch + Int(EventExpiration.driverPingMinutes * 60)
    let tags: [[String]] = [
        [NostrTags.pubkeyRef,   driverPubkey],
        [NostrTags.hashtag,     NostrTags.roadflarePingTag],
        [NostrTags.auth,        authHex],
        [NostrTags.expiration,  String(expiry)],
    ]

    return try await EventSigner.sign(
        kind: .driverPingRequest, content: encrypted, tags: tags,
        keypair: keypair, createdAt: currentDate
    )
}
```

- [ ] **Step 2.4: Run the 4 ping tests**

```bash
cd /path/to/repo/RidestrSDK && swift test --filter "buildDriverPingRequest" 2>&1 | tail -20
```
Expected: 4 tests pass. All 4 should be deterministic — `buildDriverPingRequest_hmacDeterministic` uses a pinned `currentDate` so bucket boundaries cannot cause flakiness.

- [ ] **Step 2.5: Run the full SDK test suite to check for regressions**

```bash
cd /path/to/repo/RidestrSDK && swift test 2>&1 | tail -20
```
Expected: All existing tests pass, 4 new tests pass.

- [ ] **Step 2.6: Commit**

```bash
git add RidestrSDK/Sources/RidestrSDK/Nostr/RideshareEventBuilder.swift \
        RidestrSDK/Tests/RidestrSDKTests/Nostr/RideshareEventBuilderTests.swift
git commit -m "feat(sdk): implement Kind 3189 driverPingRequest builder with HMAC auth"
```

---

## Task 3: App — AppState sendDriverPing (TDD)

**Files:**
- Modify: `RoadFlare/RoadFlareCore/ViewModels/AppState.swift`

### What to add

A `sendDriverPing(driverPubkey:)` method that:
1. Looks up the driver's `RoadflareKey` from `driversRepository`
2. Checks the per-driver cooldown (`pingCooldowns`)
3. Calls the SDK builder
4. Publishes via `relayManager`
5. Returns a `DriverPingResult` for the view to handle (toast)

A `pingCooldowns: [String: Date]` dictionary (not `@Observable` public state, just a private mutable dict — rate limiting is UI-invisible).

A `DriverPingResult` enum.

> **Note on testability:** `AppState` is `@MainActor` and depends on `relayManager`, making unit tests impractical without refactoring beyond this feature's scope. The rate-limit logic is the testable part — but since `pingCooldowns` is a simple dictionary check, the correct test strategy is an isolated helper test. For now, the rate-limit cutoff logic is simple enough to verify in a targeted integration test or manual verification. If a future refactor extracts a `PingCoordinator`, add unit tests then.

- [ ] **Step 3.1: Add `DriverPingResult` and `pingCooldowns` to AppState.swift**

In `AppState.swift`, add the enum just before the `AppState` class declaration:

```swift
/// Result of a driver ping attempt.
public enum DriverPingResult: Sendable {
    case sent
    case rateLimited(retryAfter: Date)
    case missingKey          // Driver hasn't approved the follow yet
    case publishFailed(String)
}
```

Inside the new `// MARK: - Driver Ping` block (see Step 3.3 for placement), add:

```swift
/// Per-driver last-ping timestamps for sender-side rate limiting.
/// Lives in memory for the lifetime of the process (survives backgrounding).
/// Cleared on logout / identity replacement via `prepareForIdentityReplacement()`,
/// so rider B cannot inherit rider A's cooldowns in the same session.
/// Intentionally not persisted — resets on app restart to avoid stale state.
private var pingCooldowns: [String: Date] = [:]
private static let pingCooldownSeconds: TimeInterval = 600  // 10 minutes
```

- [ ] **Step 3.2: Clear `pingCooldowns` inside `prepareForIdentityReplacement`**

`prepareForIdentityReplacement` (`AppState.swift:377`) resets UI state in section 5. Add the cooldown reset there so rider B cannot inherit rider A's per-driver cooldowns after logout, key import, or key generation flows in the same session.

Find the `// 5. UI state` comment block and add the reset alongside the other transient state:

```swift
// 5. UI state
requestRideDriverPubkey = nil
selectedTab = 0
pingCooldowns = [:]   // ← add this
```

- [ ] **Step 3.3: Add `canPingDriver` helper to AppState.swift**

This helper centralises the ping eligibility rule so the bell button, and any future UI that asks "can I ping this driver?", share a single source of truth. It is **not** the cooldown check — cooldown lives in `sendDriverPing`. This is purely structural eligibility.

Insert a new `// MARK: - Driver Ping` block directly after the `sendFollowNotification` method (search for `func sendFollowNotification` — it is in the `// MARK: - Driver Key Management` section, AppState.swift:185, ending around line 229). Place `pingCooldowns`, `pingCooldownSeconds`, `canPingDriver`, and `sendDriverPing` all inside this single new block. Add:

```swift
/// Returns `true` when `driver` is a valid ping target.
///
/// Checks: has a current RoadFlare key, key is not stale, driver is not online,
/// driver is not on a ride. Independent of the per-driver cooldown — use
/// `sendDriverPing` for the full send-with-cooldown flow.
/// Delegates to the `nonisolated static` overload, which tests can call synchronously
/// without `await` or MainActor context.
public func canPingDriver(_ driver: FollowedDriver) -> Bool {
    guard let repo = driversRepository else { return false }
    return AppState.canPingDriver(driver, using: repo)
}

/// Extracted for unit testability. `nonisolated` so tests can call it synchronously
/// without `await` or `@MainActor` — safe because the method never touches `self` or
/// any AppState property; it only reads from its `FollowedDriversRepository` parameter,
/// which is `@unchecked Sendable`.
nonisolated static func canPingDriver(_ driver: FollowedDriver, using repo: FollowedDriversRepository) -> Bool {
    guard driver.hasKey else { return false }
    guard !repo.staleKeyPubkeys.contains(driver.pubkey) else { return false }
    let status = repo.driverLocations[driver.pubkey]?.status
    return status != "online" && status != "on_ride"
}
```

- [ ] **Step 3.4: Write and run `canPingDriver` unit tests**

Create `RoadFlare/RoadFlareTests/AppState/CanPingDriverTests.swift`:

```swift
import Testing
@testable import RoadFlareCore
import RidestrSDK

// Use the SDK's own InMemoryFollowedDriversPersistence (FollowedDriversRepository.swift:459)
// rather than a hand-rolled fake — it satisfies the same protocol with the same semantics.
private let testPubkey = String(repeating: "a", count: 64)
private let testKey = RoadflareKey(
    privateKeyHex: String(repeating: "b", count: 64),
    publicKeyHex:  String(repeating: "c", count: 64),
    version: 1, keyUpdatedAt: nil
)

private func makeRepo(driver: FollowedDriver) -> FollowedDriversRepository {
    let repo = FollowedDriversRepository(persistence: InMemoryFollowedDriversPersistence())
    repo.addDriver(driver)
    return repo
}

@Suite("AppState.canPingDriver")
struct CanPingDriverTests {

    @Test func noKey_returnsFalse() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: nil)
        let repo = makeRepo(driver: driver)
        #expect(AppState.canPingDriver(driver, using: repo) == false)
    }

    @Test func staleKey_returnsFalse() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        repo.markKeyStale(pubkey: testPubkey)
        #expect(AppState.canPingDriver(driver, using: repo) == false)
    }

    @Test func online_returnsFalse() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        _ = repo.updateDriverLocation(pubkey: testPubkey, latitude: 0, longitude: 0,
                                      status: "online", timestamp: 1_000_000, keyVersion: 1)
        #expect(AppState.canPingDriver(driver, using: repo) == false)
    }

    @Test func onRide_returnsFalse() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        _ = repo.updateDriverLocation(pubkey: testPubkey, latitude: 0, longitude: 0,
                                      status: "on_ride", timestamp: 1_000_000, keyVersion: 1)
        #expect(AppState.canPingDriver(driver, using: repo) == false)
    }

    @Test func offlineWithCurrentKey_returnsTrue() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        // No location update → driver is offline (nil status)
        #expect(AppState.canPingDriver(driver, using: repo) == true)
    }
}
```

Run to confirm all 5 pass:

```bash
xcodebuild -project /path/to/repo/RoadFlare/RoadFlare.xcodeproj \
           -scheme RoadFlareTests \
           -destination 'platform=iOS Simulator,name=iPhone 16' \
           test -only-testing:RoadFlareTests/CanPingDriverTests \
           2>&1 | grep -E "Test.*passed|Test.*failed|error:" | tail -10
```
Expected: 5 tests pass.

- [ ] **Step 3.5: Add `sendDriverPing` method to AppState.swift**

After the `sendFollowNotification` method (around line 229), add:

```swift
/// Send Kind 3189 driver ping request to an offline driver.
///
/// Enforces a 10-minute per-driver cooldown locally. Returns `.rateLimited` if the
/// cooldown has not elapsed. Returns `.missingKey` if the driver has not shared their
/// RoadFlare key (ping cannot be authenticated without it). Returns `.sent` on success.
///
/// Non-fatal publish failures return `.publishFailed` — the rider is informed but the app
/// continues normally.
@discardableResult
public func sendDriverPing(driverPubkey: String) async -> DriverPingResult {
    // 1. Check cooldown
    if let lastPing = pingCooldowns[driverPubkey] {
        let retryAt = lastPing.addingTimeInterval(Self.pingCooldownSeconds)
        if Date.now < retryAt {
            return .rateLimited(retryAfter: retryAt)
        }
    }

    // 2. Require RoadFlare key (needed for HMAC auth)
    guard let roadflareKey = driversRepository?.getRoadflareKey(driverPubkey: driverPubkey) else {
        return .missingKey
    }

    // 3. Require rider identity
    guard let kp = keypair, let rm = relayManager,
          !settings.profileName.isEmpty else {
        return .publishFailed("Not logged in")
    }

    // 4. Build and publish
    // Claim the cooldown slot BEFORE any await. sendDriverPing runs on @MainActor,
    // but each `await` is a suspension point — a second tap during the async call
    // would see an empty pingCooldowns and launch a duplicate publish. Claiming
    // eagerly prevents that. Roll back on failure so the user can retry.
    pingCooldowns[driverPubkey] = Date.now
    do {
        let event = try await RideshareEventBuilder.driverPingRequest(
            driverPubkey: driverPubkey,
            riderName: settings.profileName,
            roadflareKey: roadflareKey,
            keypair: kp
        )
        _ = try await rm.publish(event)
        AppLogger.auth.info("Sent driver ping to \(driverPubkey.prefix(8))")
        return .sent
    } catch {
        pingCooldowns[driverPubkey] = nil  // rollback so user can retry
        return .publishFailed(error.localizedDescription)
    }
}
```

- [ ] **Step 3.6: Build the RoadFlareCore target to check for compile errors**

```bash
xcodebuild -project /path/to/repo/RoadFlare/RoadFlare.xcodeproj \
           -scheme RoadFlare \
           -destination 'generic/platform=iOS Simulator' \
           build 2>&1 | grep -E "error:|Build succeeded|Build FAILED" | tail -10
```
Expected: `Build succeeded`

- [ ] **Step 3.7: Commit**

```bash
git add RoadFlare/RoadFlareCore/ViewModels/AppState.swift \
        RoadFlare/RoadFlareTests/AppState/CanPingDriverTests.swift
git commit -m "feat(app): add canPingDriver eligibility check and sendDriverPing with 10-min cooldown"
```

---

## Task 4: App — DriverCard Bell Button

**Files:**
- Modify: `RoadFlare/RoadFlare/Views/Drivers/DriversTab.swift`

### What to add

1. `onPing: () -> Void` callback on `DriverCard` (same pattern as `onShare`)
2. Bell button `bell` icon (`bell` SF Symbol), positioned LEFT of the share button
3. Visibility gate: show bell only when `appState.canPingDriver(driver)` returns `true` (defined in Task 3, Step 3.3)
4. Toast state on `DriversTab` for ping feedback
5. `pingDriver(_ driver:)` method on `DriversTab` that calls `appState.sendDriverPing`

### Bell button visibility logic

The eligibility rule is centralised in `AppState.canPingDriver(_:)` (defined in Task 3, Step 3.3). The four conditions it encapsulates:
- `driver.hasKey` → required for HMAC auth; no key means the follow is still pending
- `!staleKeyPubkeys.contains(driver.pubkey)` → stale-key drivers silently discard the ping (HMAC mismatch) and burn the rider's 10-min cooldown
- `status != "online"` → ping makes no sense when the driver is already available
- `status != "on_ride"` → actively driving; no point interrupting

So the condition is: `appState.canPingDriver(driver)`

This covers:
- Offline with a current key ✓ (show bell — this is the target state)
- On a ride with a key ✗ (hide bell — actively driving, no point interrupting)
- No key (pending approval) ✗ (hide bell — can't auth anyway)
- Stale key ✗ (hide bell — driver would silently discard; HMAC mismatch on their end)
- Online ✗ (hide bell — already available)

- [ ] **Step 4.1: Add `onPing` callback and bell button to DriverCard**

In `DriversTab.swift`, find the `DriverCard` struct definition.

First, add `@Environment(AppState.self)` and `onPing` to `DriverCard` (the environment access is needed to call `canPingDriver`):
```swift
struct DriverCard: View {
    @Environment(AppState.self) private var appState   // ← add this
    let driver: FollowedDriver
    let repo: FollowedDriversRepository
    let onRequest: () -> Void
    let onShare: () -> Void
    let onPing: () -> Void      // ← add this
    let onDelete: () -> Void
    let onTap: () -> Void
```

Next, find the right-side action area in `var body: some View` — the share button block that starts at the comment `// Share button (right side, larger touch target)`. Replace that block:

```swift
// Action buttons (right side) — bell (if pingable) then share
HStack(spacing: 8) {
    if appState.canPingDriver(driver) {
        Button(action: onPing) {
            Image(systemName: "bell")
                .font(.system(size: 16))
                .foregroundColor(Color.rfOnSurfaceVariant)
                .frame(width: 44, height: 44)
                .background(Color.rfSurfaceContainerHigh)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ping driver")
        .accessibilityHint("Sends a notification asking the driver to come online")
    }

    Button(action: onShare) {
        Image(systemName: "square.and.arrow.up")
            .font(.system(size: 16))
            .foregroundColor(Color.rfOnSurfaceVariant)
            .frame(width: 44, height: 44)
            .background(Color.rfSurfaceContainerHigh)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    .buttonStyle(.plain)
}
```

- [ ] **Step 4.2: Wire onPing at the call site in DriversTab.body**

In `DriversTab.body`, find the `ForEach(sortedDrivers(repo: repo)) { driver in` block and add the `onPing` argument to `DriverCard`:

```swift
DriverCard(
    driver: driver,
    repo: repo,
    onRequest: {
        appState.requestRideDriverPubkey = driver.pubkey
        appState.selectedTab = 0
    },
    onShare: { shareDriver(driver) },
    onPing: { pingDriver(driver) },   // ← add this
    onDelete: { removeDriver(driver) },
    onTap: { selectedDriver = driver }
)
```

- [ ] **Step 4.3: Add toast state and pingDriver method to DriversTab**

In `DriversTab`, add two state variables alongside the existing ones — one for the message, one to carry the error/success styling:

```swift
@State private var pingToastMessage: String?
@State private var pingToastIsError = false
```

`ToastView` routes its icon and color entirely through `isError` (green checkmark when `false`, warning triangle when `true`). Rate-limited and publish-failed outcomes need `isError: true`; only `.sent` gets the green checkmark.

Add the `pingDriver` method alongside `shareDriver` and `removeDriver`:

```swift
private func pingDriver(_ driver: FollowedDriver) {
    // Capture pubkey as a plain String (Sendable) before the task boundary so
    // `driver` (a struct that may not be Sendable) doesn't need to cross the
    // isolation boundary. `appState.driversRepository` is @MainActor-isolated,
    // so `cachedDriverName` must be called inside `MainActor.run`, not before it.
    let driverPubkey = driver.pubkey
    Task {
        let result = await appState.sendDriverPing(driverPubkey: driverPubkey)
        await MainActor.run {
            let name = appState.driversRepository?.cachedDriverName(pubkey: driverPubkey)
                ?? String(driverPubkey.prefix(8)) + "..."
            switch result {
            case .sent:
                pingToastMessage = "Ping sent to \(name)"
                pingToastIsError = false
            case .rateLimited(let retryAt):
                let remaining = Int(retryAt.timeIntervalSinceNow / 60) + 1
                pingToastMessage = "Wait \(remaining) min before pinging \(name) again"
                pingToastIsError = true
            case .missingKey:
                // Bell is hidden when no key — this shouldn't happen in practice
                break
            case .publishFailed:
                pingToastMessage = "Couldn't send ping — check your connection"
                pingToastIsError = true
            }
        }
    }
}
```

- [ ] **Step 4.4: Wire toast onto the NavigationStack**

Find the end of `DriversTab.body`'s `NavigationStack { ... }` block. After the `.task {}` modifier (which follows any `.sheet(...)` and `.refreshable {}` modifiers) and before the closing `}` of the `NavigationStack`, add:

```swift
.toast($pingToastMessage, isError: pingToastIsError)
```

`pingToastIsError` and `pingToastMessage` are both set inside the same `MainActor.run` block, so SwiftUI sees them as a single atomic state update and re-renders once with both values. Order of assignment within the block doesn't matter.

- [ ] **Step 4.5: Build to verify no compile errors**

```bash
xcodebuild -project /path/to/repo/RoadFlare/RoadFlare.xcodeproj \
           -scheme RoadFlare \
           -destination 'generic/platform=iOS Simulator' \
           build 2>&1 | grep -E "error:|Build succeeded|Build FAILED" | tail -10
```
Expected: `Build succeeded`

- [ ] **Step 4.6: Commit**

```bash
git add RoadFlare/RoadFlare/Views/Drivers/DriversTab.swift
git commit -m "feat(ui): add bell ping button to offline driver cards in DriversTab"
```

---

## Task 5: App — RideRequestView Empty State CTA

**Files:**
- Modify: `RoadFlare/RoadFlare/Views/Ride/RideRequestView.swift`

### What to add

A "Ping a Driver" button in the "No Drivers Online" empty state that navigates to the Drivers tab (`appState.selectedTab = 1`).

The button is shown whenever the rider has followed drivers but none are online (i.e., within the `onlineDrivers.isEmpty` branch). Even if all followed drivers are pending-approval (no key), the button navigates there, which is fine — the Drivers tab accurately shows the state.

> **Why not gate on `canPingDriver` here?** The CTA navigates to the Drivers tab, not to a specific driver. The question is "does the rider have any drivers to visit?" not "is a specific driver currently pingable?" — `canPingDriver` is a per-driver check. If none of the followed drivers are eligible right now, the rider lands on the Drivers tab and sees no bell buttons, which is the correct feedback. Iterating all drivers on the Ride tab just to decide whether to show the CTA would be O(n) in the wrong place.

- [ ] **Step 5.1: Add the CTA button to the empty state in RideRequestView.swift**

Find the `if onlineDrivers.isEmpty { VStack(spacing: 24) { ... } }` block (lines 45–57). Replace it:

```swift
if onlineDrivers.isEmpty {
    VStack(spacing: 24) {
        Spacer().frame(height: 80)
        Image(systemName: "car.side")
            .font(.system(size: 48))
            .foregroundColor(Color.rfOnSurfaceVariant)
        Text("No Drivers Online")
            .font(RFFont.headline(20))
            .foregroundColor(Color.rfOnSurface)
        Text("Check back later, or ping a driver to let them know you need a ride.")
            .font(RFFont.body(15))
            .foregroundColor(Color.rfOnSurfaceVariant)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
        if let repo = appState.driversRepository, repo.hasDrivers {
            Button("Ping a Driver") {
                appState.selectedTab = 1
            }
            .buttonStyle(RFPrimaryButtonStyle())
            .padding(.horizontal, 48)
        }
    }
}
```

The `repo.hasDrivers` guard means the button only appears when the rider actually has followed drivers to ping. If they have zero followed drivers, the existing empty state on the Drivers tab ("No Drivers Yet") handles that.

- [ ] **Step 5.2: Build to verify**

```bash
xcodebuild -project /path/to/repo/RoadFlare/RoadFlare.xcodeproj \
           -scheme RoadFlare \
           -destination 'generic/platform=iOS Simulator' \
           build 2>&1 | grep -E "error:|Build succeeded|Build FAILED" | tail -10
```
Expected: `Build succeeded`

- [ ] **Step 5.3: Commit**

```bash
git add RoadFlare/RoadFlare/Views/Ride/RideRequestView.swift
git commit -m "feat(ui): add Ping a Driver CTA to No Drivers Online empty state"
```

---

## Task 6: ADR-0009

**Files:**
- Create: `decisions/0009-driver-ping-kind-3189.md`

- [ ] **Step 6.1: Write ADR-0009**

Create `decisions/0009-driver-ping-kind-3189.md` with:

```markdown
# ADR-0009: Kind 3189 Driver Ping Request with HMAC Auth

**Date:** 2026-04-14
**Status:** Accepted
**Issue:** #4 — Ping feature to notify offline drivers

## Context

The trusted-driver ridesharing model has a cold-start deadlock: drivers won't run the app unless they have customers, and riders can't get rides unless drivers are online. Riders need a way to nudge a specific offline driver they trust.

The existing Kind 3187 (`followNotification`) handles follow announcements and is still active in drivestr. Routing availability nudges through 3187 would mix two different intents on a single subscription stream, and would require adding an HMAC auth mechanism to a protocol that predates the HMAC design — breaking backward compatibility with existing 3187 consumers on both platforms.

## Decision

Introduce **Kind 3189 `driverPingRequest`** — a dedicated event kind for rider-to-driver availability nudges.

**Why a new kind (not extend Kind 3187):**
- **Different semantics**: Kind 3187 is a follow-announcement; Kind 3189 is an availability nudge. Conflating them would pollute the drivestr Kind 3187 subscription stream with a different intent.
- **No HMAC path on 3187**: Kind 3187 carries no `auth` tag in its protocol definition. Adding HMAC validation to 3187 events would break backward compatibility with existing 3187 consumers on both platforms.
- **Distinct handling path**: Kind 3189 belongs in the drivestr foreground-service listener alongside ride offers and key material events, where HMAC validation is cheap and the RoadFlare key is already in scope. Kind 3187 has a separate handling path with different assumptions.

**Why HMAC auth (not just rely on NIP-44 sender identity):**
The driver app needs to verify the sender is a known follower before delivering a notification — anonymous pings from strangers must be rejected silently. Walking the Kind 30011 list on every ping is slow and relay-dependent. HMAC using the RoadFlare private key (which the rider holds after key share) proves follower status in O(1) without network I/O.

The RoadFlare key rotation mechanism provides natural revocation: when a driver rotates their key (e.g., after removing a muted follower), old HMAC proofs computed with the old key become invalid.

**Why a 5-minute time window (epoch / 300) for HMAC:**
Prevents replay attacks — a captured ping event cannot be replayed outside the ±1 bucket (~10–15 minute validity window). The 30-minute event expiry tag is an additional outer bound. The driver app checks `timeWindow`, `timeWindow - 1`, and `timeWindow + 1` to handle clock skew and window boundaries.

## Rationale Over Alternatives

| Alternative | Rejected because |
|---|---|
| Extend Kind 3187 with `action: "ping"` | Mixed semantics; no HMAC path without breaking existing 3187 consumers; wrong handling path in drivestr |
| NIP-04/44 DM (Kind 4) | Pollutes DM inbox; no semantic meaning for driver apps |
| Standard Nostr `["nip"]` zap-style signal | Not specific to rideshare; no auth proof |
| No auth (trust NIP-44 sender) | Any Nostr user could spam drivers with pings |
| Ephemeral Kind 20xxx | Not stored by relays — driver app must be live at the exact moment the event arrives; NIP-40 expiry tag is moot; deduplication across reconnects is impossible |
| Replaceable Kind 30xxx | Each new ping overwrites the previous one, collapsing the dedup window to a single event per rider-driver pair; a rapid double-tap would silently drop the first ping |

## Consequences

- **New SDK constant**: `EventKind.driverPingRequest = 3189`
- **New constants**: `EventExpiration.driverPingMinutes = 30`, `NostrTags.roadflarePingTag`, `NostrTags.auth`
- **New builder**: `RideshareEventBuilder.driverPingRequest(driverPubkey:riderName:roadflareKey:keypair:)`
- **Android requirement**: drivestr must add Kind 3189 subscription and HMAC validation. Protocol spec is in `ANDROID_DEEP_DIVE.md`.
- **Delivery caveat**: Event delivery only works when the driver app is foregrounded or recently backgrounded. A future server-side push bridge (FCM/APNs relay) can extend delivery to truly dormant apps by subscribing to Kind 3189 and forwarding via push token. The event kind design is forward-compatible with this.

**Graceful degradation.** The feature is inherently speculative: a rider pings an offline driver and hopes they come online. If the drivestr side is temporarily behind (older build, delayed deployment, missing notification permission), the pinged driver simply won't come online — indistinguishable from the normal "driver saw it and didn't bite" state. There is no broken UI state, no error toast, no user-visible regression. This property is what makes lockstep-but-not-synchronous shipping acceptable.

## Affected Files

- `RidestrSDK/Sources/RidestrSDK/Nostr/EventKind.swift`
- `RidestrSDK/Sources/RidestrSDK/Nostr/Constants.swift`
- `RidestrSDK/Sources/RidestrSDK/Nostr/RideshareEventBuilder.swift`
- `RoadFlare/RoadFlareCore/ViewModels/AppState.swift`
- `RoadFlare/RoadFlare/Views/Drivers/DriversTab.swift`
- `RoadFlare/RoadFlare/Views/Ride/RideRequestView.swift`
```

- [ ] **Step 6.2: Commit**

```bash
git add decisions/0009-driver-ping-kind-3189.md
git commit -m "docs(adr): ADR-0009 Kind 3189 driver ping with HMAC auth"
```

---

## Task 7: Documentation Updates

**Files:**
- Modify: `PRD.md`
- Modify: `ANDROID_DEEP_DIVE.md`

### 7.1 PRD.md — Two locations

- [ ] **Step 7.1: Add Kind 3189 to Appendix A event kinds table**

Find the section in `PRD.md` that mentions `3173–3188` (around line 147, "Custom event kinds"). In Appendix A's event kind reference (search for "Appendix A"), locate the table listing event kinds. Add a row for Kind 3189:

```markdown
| 3189 | `driverPingRequest` | Rider → driver availability nudge. NIP-44 encrypted, HMAC auth tag. 30-min expiry. |
```

- [ ] **Step 7.2: Add Kind 3189 to the local notifications table**

Find the local notifications table (around line 1395, "| Notification | Trigger | Priority |"). Add:

```markdown
| Driver ping received | Kind 3189 received (after HMAC validation) | Default |
```

This entry is the driver-side perspective (for the drivestr app reference), but it belongs in the PRD for completeness.

- [ ] **Step 7.3: Update the custom event kinds range mention**

Find the line `Custom event kinds (3173–3188, 30011–30182)` (around line 147) and update it:
```markdown
Custom event kinds (3173–3189, 30011–30182)
```

### 7.2 ANDROID_DEEP_DIVE.md — New section for drivestr

- [ ] **Step 7.4: Add Kind 3189 section to ANDROID_DEEP_DIVE.md**

Find the section `### Follower Discovery (replacing deprecated Kind 3187)` (around line 304). After that section, insert:

```markdown
### Driver Ping (Kind 3189)

Riders can nudge offline drivers to come online via Kind 3189 `driverPingRequest`.

**Event structure:**
```
kind: 3189
content: NIP-44 encrypted JSON (to driver's identity pubkey)
tags:
  ["p",          "<driver pubkey hex>"]
  ["t",          "roadflare-ping"]
  ["auth",       "<HMAC-SHA256 hex>"]
  ["expiration", "<epoch + 1800>"]
```

**Decrypted content:**
```json
{
  "action":    "ping",
  "riderName": "<rider display name>",
  "message":   "<riderName> is currently hoping you come online!",
  "timestamp": <unix epoch>
}
```
Display `message` directly as the notification body.

**HMAC auth validation (driver side):**
```
currentWindow = epochNow / 300            // integer division
riderPubkey   = event.pubkey              // the Nostr event signer
authTag       = event.tag("auth")         // hex string on the event
hmac(window)  = HMAC-SHA256(key=hexDecode(currentRoadflareKey.privateKey),
                             msg=(driverPubkey + riderPubkey + str(window)).utf8)
valid         = hmac(currentWindow)     == authTag
             || hmac(currentWindow - 1) == authTag
             || hmac(currentWindow + 1) == authTag
```
All three calls use the same `driverPubkey` and `riderPubkey` — only the window integer changes.
Reject silently (no notification, no error response) if none of the three windows match.

**Driver-side rate limits (apply after HMAC validation):**
- 30-second dedup window per rider pubkey
- Global cap: 2 notifications per 10-minute window across all senders
- Muted rider pubkeys: discard after HMAC auth, before notification delivery

**Rider-side cooldown (enforced on iOS):** 1 ping per driver per 10 minutes.
```

- [ ] **Step 7.5: Commit**

```bash
git add PRD.md ANDROID_DEEP_DIVE.md
git commit -m "docs: add Kind 3189 driverPingRequest spec to PRD and Android deep dive"
```

---

## Task 8: Full Build Verification

- [ ] **Step 8.1: Run the full SDK test suite one more time**

```bash
cd /path/to/repo/RidestrSDK && swift test 2>&1 | tail -10
```
Expected: All tests pass (existing + 4 new ping tests).

- [ ] **Step 8.2: Run full Xcode build**

```bash
xcodebuild -project /path/to/repo/RoadFlare/RoadFlare.xcodeproj \
           -scheme RoadFlare \
           -destination 'generic/platform=iOS Simulator' \
           build 2>&1 | grep -E "error:|warning: |Build succeeded|Build FAILED" | grep -v "warning:" | tail -10
```
Expected: `Build succeeded`

- [ ] **Step 8.3: Run RoadFlareTests**

```bash
xcodebuild -project /path/to/repo/RoadFlare/RoadFlare.xcodeproj \
           -scheme RoadFlareTests \
           -destination 'platform=iOS Simulator,name=iPhone 16' \
           test 2>&1 | grep -E "Test.*passed|Test.*failed|error:" | tail -20
```
Expected: All tests pass.

---

## Open Questions & Assumptions

### Assumptions Made

1. **`NIP44.encrypt(plaintext:senderKeypair:recipientPublicKeyHex:)` overload exists — confirmed** (`NIP44.swift:85`). The builder uses this signature (same as `keyAcknowledgement` at `RideshareEventBuilder.swift:487`). No fallback to `senderPrivateKeyHex:` needed.

2. **`EventSigner.sign(kind:content:tags:keypair:)` accepts `EventKind` enum value.** Verified from other builders — the existing `sign(kind: .followNotification, ...)` pattern is reused.

3. **`AppLogger.auth` is the right log category for ping events.** It's the category used by `sendFollowNotification`. If a separate category is preferred, update in `sendDriverPing`.

4. **Drivers tab index is 1.** Confirmed from `MainTabView.swift` — `DriversTab` has `.tag(1)`.

5. **"Ping a Driver" button copy is final.** Stirling confirmed wording. If it needs to change, only `RideRequestView.swift:Step 5.1` changes.

6. **The `@discardableResult` on `sendDriverPing` is correct.** The view calls it in a `Task {}` and handles the result itself; callers that don't care about result (e.g., future background retry) can ignore it.

### Open Questions

1. **Build path for `xcodebuild` commands:** The plan uses `/path/to/repo` as a placeholder. Implementor must substitute the actual path: `/Users/stirling/Documents/Projects/roadflare-ios`.

2. **`HMAC<SHA256>` import:** CryptoKit is already used in `NostrKeypair.swift` but not yet in `RideshareEventBuilder.swift`. The plan adds `import CryptoKit` — verify there's no module isolation issue preventing it (there shouldn't be, since both are in the same SPM target).

3. **RateLimit toast copy for rateLimited case:** The plan uses "Wait N min before pinging X again." If Stirling prefers a different phrasing, update in `DriversTab.pingDriver()`.

4. **Resolved — drivestr implementation lives in a parallel plan.** The Android drivestr side ships in lockstep with this iOS plan. It is tracked in a separate plan file in the ridestr repo (branch `feature/issue-4-driver-ping`) that consumes this plan's Section 1 protocol spec and ANDROID_DEEP_DIVE.md Task 7.4 pseudo-code as its input. See "Release Coordination" above.
