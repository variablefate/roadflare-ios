# RideStatePersistence SDK Migration — Implementation Plan (v3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate ride state persistence domain logic (expiration, stage filtering, legacy migration) from the iOS app layer to the SDK, following the proven UserSettingsRepository pattern. Also extract Nostr key derivation from PasskeyManager into the SDK.

**Architecture:** SDK owns the persistence contract (`PersistedRideState`), validation/expiration logic (`RideStateRepository`), and abstract storage interface (`RideStatePersistence` protocol). App provides the iOS-specific `UserDefaultsRideStatePersistence` implementation. `RideCoordinator` constructs `RideStateRepository` internally from its `stageTimeouts`, deriving the restoration policy — matching the current pattern where timeouts influence persistence behavior.

**Tech Stack:** Swift, RidestrSDK (SPM package), Swift Testing framework, `@unchecked Sendable` + `NSLock` pattern

---

## Review Findings Incorporated (v2)

Issues found by three focused review agents and fixes applied:

| Issue | Severity | Fix |
|---|---|---|
| `PersistedRideState: Equatable` won't compile (`RiderRideAction` not Equatable) | Critical | Remove `Equatable` conformance |
| `import CryptoKit` missing from Task 4 code | Critical | Added to code block |
| Tasks 5+6 commit broken build between them | Critical | Merged into single task |
| Custom `stageTimeouts` no longer influences restore policy | Important | RideCoordinator constructs RideStateRepository internally with policy from stageTimeouts |
| ~16 coordinator test lines call nonexistent `RideStatePersistence.load()` | Important | `makeCoordinator` returns persistence; tests assert via persistence/repo |
| `RideStatePersistence.RestorePolicy` in coordinator tests | Important | Updated to `RideStateRestorationPolicy` |
| Tests calling `save(session:...)` need helper | Important | Added `makePersistedState()` test helper |
| Missing exact boundary timestamp test | Important | Added |
| Test suite rename not in plan | Important | Added |
| Protocol naming inconsistency | Design | Use `RideStatePersistence` (no Protocol suffix) |
| `migrated()` verbose reinit | Design | Use copy-with-changes pattern |
| `load()` policy param vs init-time | Design | Init-time (RideCoordinator constructs repo with derived policy) |
| `prepareForIdentityReplacement` called before coordinator exists — nil reach-through silently skips clear | Important (Codex) | AppState owns a direct persistence handle for cleanup |
| Unknown/corrupt stage passes SDK validation, never cleared | Medium (Codex) | SDK `load()` validates stage is a known `RiderStage` raw value |
| Derivation test only checks length, not known output | Medium (Codex) | Compute actual SHA256 of test input and assert exact pubkey |
| Expiration boundary tests flaky — two separate `Date.now` reads | Medium (Codex) | Pass explicit fixed `now:` to `repo.load(now:)` in boundary tests |

## File Structure

| File | Change | Responsibility |
|------|--------|---------------|
| `RidestrSDK/.../Ride/PersistedRideState.swift` | CREATE | 28-field Codable struct + `migrated()` legacy normalization |
| `RidestrSDK/.../Ride/RideStateRepository.swift` | CREATE | Repository class + `RideStatePersistence` protocol + `RideStateRestorationPolicy` + `InMemoryRideStatePersistence` |
| `RidestrSDK/.../Nostr/NostrKeypair.swift` | MODIFY | Add `deriveFromSymmetricKey()` static method |
| `RidestrSDK/Tests/.../Ride/RideStateRepositoryTests.swift` | CREATE | Expiration, stage filtering, legacy migration, boundary tests |
| `RidestrSDK/Tests/.../Nostr/NostrKeypairTests.swift` | MODIFY | Add derivation determinism + known-output test |
| `RoadFlare/.../Services/RideStatePersistence.swift` | REWRITE | Thin UserDefaults wrapper implementing SDK protocol |
| `RoadFlare/.../ViewModels/RideCoordinator.swift` | MODIFY | Accept persistence via init, construct RideStateRepository internally |
| `RoadFlare/.../ViewModels/AppState.swift` | MODIFY | Create and pass persistence to RideCoordinator |
| `RoadFlare/.../Services/PasskeyManager.swift` | MODIFY | Call `NostrKeypair.deriveFromSymmetricKey()` |
| `RoadFlare/RoadFlareTests/RoadFlareTests.swift` | MODIFY | Rename suite, split: expiration → SDK, UserDefaults → app |
| `RoadFlare/RoadFlareTests/RideCoordinatorTests.swift` | MODIFY | Use injected persistence, return from helper, update all 16 call sites |

---

## Task 1: Create PersistedRideState in SDK

**Files:**
- Create: `RidestrSDK/Sources/RidestrSDK/Ride/PersistedRideState.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

/// Canonical persistence contract for active ride state.
/// Both platforms (iOS/Android) agree on this shape.
public struct PersistedRideState: Codable, Sendable {
    public let stage: String
    public let offerEventId: String?
    public let acceptanceEventId: String?
    public let confirmationEventId: String?
    public let driverPubkey: String?
    public let pin: String?
    public let pinVerified: Bool
    public let paymentMethodRaw: String?
    public let fiatPaymentMethodsRaw: [String]
    public let pickupLat: Double?
    public let pickupLon: Double?
    public let pickupAddress: String?
    public let destLat: Double?
    public let destLon: Double?
    public let destAddress: String?
    public let fareUSD: String?
    public let fareDistanceMiles: Double?
    public let fareDurationMinutes: Double?
    public let savedAt: Int
    public let processedPinActionKeys: [String]?
    public let processedPinTimestamps: [Int]?
    public let pinAttempts: Int?
    public let precisePickupShared: Bool?
    public let preciseDestinationShared: Bool?
    public let lastDriverStatus: String?
    public let lastDriverStateTimestamp: Int?
    public let lastDriverActionCount: Int?
    public let riderStateHistory: [RiderRideAction]?

    public init(
        stage: String,
        offerEventId: String? = nil,
        acceptanceEventId: String? = nil,
        confirmationEventId: String? = nil,
        driverPubkey: String? = nil,
        pin: String? = nil,
        pinVerified: Bool = false,
        paymentMethodRaw: String? = nil,
        fiatPaymentMethodsRaw: [String] = [],
        pickupLat: Double? = nil,
        pickupLon: Double? = nil,
        pickupAddress: String? = nil,
        destLat: Double? = nil,
        destLon: Double? = nil,
        destAddress: String? = nil,
        fareUSD: String? = nil,
        fareDistanceMiles: Double? = nil,
        fareDurationMinutes: Double? = nil,
        savedAt: Int = Int(Date.now.timeIntervalSince1970),
        processedPinActionKeys: [String]? = nil,
        processedPinTimestamps: [Int]? = nil,
        pinAttempts: Int? = nil,
        precisePickupShared: Bool? = nil,
        preciseDestinationShared: Bool? = nil,
        lastDriverStatus: String? = nil,
        lastDriverStateTimestamp: Int? = nil,
        lastDriverActionCount: Int? = nil,
        riderStateHistory: [RiderRideAction]? = nil
    ) {
        self.stage = stage
        self.offerEventId = offerEventId
        self.acceptanceEventId = acceptanceEventId
        self.confirmationEventId = confirmationEventId
        self.driverPubkey = driverPubkey
        self.pin = pin
        self.pinVerified = pinVerified
        self.paymentMethodRaw = paymentMethodRaw
        self.fiatPaymentMethodsRaw = fiatPaymentMethodsRaw
        self.pickupLat = pickupLat
        self.pickupLon = pickupLon
        self.pickupAddress = pickupAddress
        self.destLat = destLat
        self.destLon = destLon
        self.destAddress = destAddress
        self.fareUSD = fareUSD
        self.fareDistanceMiles = fareDistanceMiles
        self.fareDurationMinutes = fareDurationMinutes
        self.savedAt = savedAt
        self.processedPinActionKeys = processedPinActionKeys
        self.processedPinTimestamps = processedPinTimestamps
        self.pinAttempts = pinAttempts
        self.precisePickupShared = precisePickupShared
        self.preciseDestinationShared = preciseDestinationShared
        self.lastDriverStatus = lastDriverStatus
        self.lastDriverStateTimestamp = lastDriverStateTimestamp
        self.lastDriverActionCount = lastDriverActionCount
        self.riderStateHistory = riderStateHistory
    }

    /// Normalize legacy fields. Converts old `processedPinTimestamps` to
    /// `processedPinActionKeys` format. Called by `RideStateRepository.load()`.
    public func migrated() -> PersistedRideState {
        guard processedPinActionKeys == nil, let timestamps = processedPinTimestamps else {
            return self
        }
        return PersistedRideState(
            stage: stage, offerEventId: offerEventId,
            acceptanceEventId: acceptanceEventId, confirmationEventId: confirmationEventId,
            driverPubkey: driverPubkey, pin: pin, pinVerified: pinVerified,
            paymentMethodRaw: paymentMethodRaw, fiatPaymentMethodsRaw: fiatPaymentMethodsRaw,
            pickupLat: pickupLat, pickupLon: pickupLon, pickupAddress: pickupAddress,
            destLat: destLat, destLon: destLon, destAddress: destAddress,
            fareUSD: fareUSD, fareDistanceMiles: fareDistanceMiles,
            fareDurationMinutes: fareDurationMinutes, savedAt: savedAt,
            processedPinActionKeys: timestamps.map { "pin_submit:\($0)" },
            processedPinTimestamps: processedPinTimestamps,
            pinAttempts: pinAttempts, precisePickupShared: precisePickupShared,
            preciseDestinationShared: preciseDestinationShared,
            lastDriverStatus: lastDriverStatus,
            lastDriverStateTimestamp: lastDriverStateTimestamp,
            lastDriverActionCount: lastDriverActionCount,
            riderStateHistory: riderStateHistory
        )
    }
}
```

Note: `Equatable` is intentionally omitted — `RiderRideAction` does not conform to `Equatable`. Init uses default parameter values to reduce boilerplate at test call sites.

- [ ] **Step 2: Verify SDK builds**

Run: `cd RidestrSDK && swift build 2>&1 | tail -5`
Expected: Build complete

- [ ] **Step 3: Commit**

```bash
git add RidestrSDK/Sources/RidestrSDK/Ride/PersistedRideState.swift
git commit -m "feat: add PersistedRideState to SDK as persistence contract"
```

---

## Task 2: Create RideStateRepository, protocol, policy, and test double in SDK

**Files:**
- Create: `RidestrSDK/Sources/RidestrSDK/Ride/RideStateRepository.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

// MARK: - Persistence Protocol

/// Abstract storage for ride state. iOS implements with UserDefaults;
/// tests use InMemoryRideStatePersistence.
public protocol RideStatePersistence: Sendable {
    func saveRaw(_ state: PersistedRideState)
    func loadRaw() -> PersistedRideState?
    func clear()
}

// MARK: - Restoration Policy

/// Defines how long each ride stage remains valid for restoration.
/// The SDK is the single authority on ride state expiration.
public struct RideStateRestorationPolicy: Sendable, Equatable {
    public let waitingForAcceptance: Int
    public let driverAccepted: Int
    public let postConfirmation: Int

    public init(waitingForAcceptance: Int, driverAccepted: Int, postConfirmation: Int) {
        self.waitingForAcceptance = waitingForAcceptance
        self.driverAccepted = driverAccepted
        self.postConfirmation = postConfirmation
    }

    /// Default policy using protocol constants.
    public static let `default` = RideStateRestorationPolicy(
        waitingForAcceptance: Int(RideConstants.broadcastTimeoutSeconds),
        driverAccepted: Int(RideConstants.confirmationTimeoutSeconds),
        postConfirmation: Int(EventExpiration.rideConfirmationHours * 3600)
    )

    /// Max restore age in seconds for a given stage.
    public func maxRestoreAge(for stage: String) -> Int {
        switch stage {
        case RiderStage.waitingForAcceptance.rawValue:
            waitingForAcceptance
        case RiderStage.driverAccepted.rawValue:
            driverAccepted
        default:
            postConfirmation
        }
    }
}

// MARK: - Repository

/// Manages ride state persistence with SDK-owned validation.
/// The app never sees expired, idle, or legacy-format data.
public final class RideStateRepository: @unchecked Sendable {
    private let persistence: RideStatePersistence
    private let policy: RideStateRestorationPolicy

    public init(
        persistence: RideStatePersistence,
        policy: RideStateRestorationPolicy = .default
    ) {
        self.persistence = persistence
        self.policy = policy
    }

    public func save(_ state: PersistedRideState) {
        persistence.saveRaw(state)
    }

    /// Load validated ride state. Returns nil if expired, idle, completed,
    /// or has an unknown/corrupt stage. Applies legacy field migration.
    public func load(now: Date = .now) -> PersistedRideState? {
        guard let raw = persistence.loadRaw() else { return nil }

        // Reject unknown/corrupt stages — SDK owns the full validation
        guard let stage = RiderStage(rawValue: raw.stage) else {
            persistence.clear()
            return nil
        }

        let age = Int(now.timeIntervalSince1970) - raw.savedAt
        guard age < policy.maxRestoreAge(for: raw.stage) else {
            persistence.clear()
            return nil
        }

        guard stage != .idle, stage != .completed else {
            persistence.clear()
            return nil
        }

        return raw.migrated()
    }

    public func clear() {
        persistence.clear()
    }
}

// MARK: - In-Memory Test Double

public final class InMemoryRideStatePersistence: RideStatePersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PersistedRideState?

    public init() {}

    public func saveRaw(_ state: PersistedRideState) {
        lock.withLock { stored = state }
    }

    public func loadRaw() -> PersistedRideState? {
        lock.withLock { stored }
    }

    public func clear() {
        lock.withLock { stored = nil }
    }
}
```

- [ ] **Step 2: Verify SDK builds**

Run: `cd RidestrSDK && swift build 2>&1 | tail -5`
Expected: Build complete

- [ ] **Step 3: Commit**

```bash
git add RidestrSDK/Sources/RidestrSDK/Ride/RideStateRepository.swift
git commit -m "feat: add RideStateRepository with persistence protocol and expiration logic

SDK owns ride state validation: expiration by stage, idle/completed
rejection, and legacy field migration. App provides storage backend."
```

---

## Task 3: Add SDK tests for RideStateRepository

**Files:**
- Create: `RidestrSDK/Tests/RidestrSDKTests/Ride/RideStateRepositoryTests.swift`

- [ ] **Step 1: Create the test file**

```swift
import Foundation
import Testing
@testable import RidestrSDK

@Suite("RideStateRepository Tests")
struct RideStateRepositoryTests {

    private func makeRepo(
        policy: RideStateRestorationPolicy = .default
    ) -> (RideStateRepository, InMemoryRideStatePersistence) {
        let persistence = InMemoryRideStatePersistence()
        let repo = RideStateRepository(persistence: persistence, policy: policy)
        return (repo, persistence)
    }

    private func makeState(
        stage: String = RiderStage.waitingForAcceptance.rawValue,
        savedAt: Int = Int(Date.now.timeIntervalSince1970),
        processedPinActionKeys: [String]? = nil,
        processedPinTimestamps: [Int]? = nil
    ) -> PersistedRideState {
        PersistedRideState(
            stage: stage, offerEventId: "offer123",
            driverPubkey: "driver_pubkey_hex", pin: "1234",
            paymentMethodRaw: "zelle", fiatPaymentMethodsRaw: ["zelle", "cash"],
            pickupLat: 40.71, pickupLon: -74.01, pickupAddress: "Penn Station",
            destLat: 40.76, destLon: -73.98, destAddress: "Central Park",
            fareUSD: "12.50", fareDistanceMiles: 5.5, fareDurationMinutes: 18,
            savedAt: savedAt,
            processedPinActionKeys: processedPinActionKeys,
            processedPinTimestamps: processedPinTimestamps
        )
    }

    // MARK: - Round-trip

    @Test func saveAndLoadRoundTrip() {
        let (repo, _) = makeRepo()
        let state = makeState()
        repo.save(state)
        let loaded = repo.load()
        #expect(loaded?.stage == state.stage)
        #expect(loaded?.offerEventId == "offer123")
        #expect(loaded?.pickupLat == 40.71)
        #expect(loaded?.fareUSD == "12.50")
    }

    @Test func loadReturnsNilWhenEmpty() {
        let (repo, _) = makeRepo()
        #expect(repo.load() == nil)
    }

    @Test func clearRemovesData() {
        let (repo, _) = makeRepo()
        repo.save(makeState())
        repo.clear()
        #expect(repo.load() == nil)
    }

    // MARK: - Stage filtering

    @Test func loadRejectsIdle() {
        let (repo, _) = makeRepo()
        repo.save(makeState(stage: RiderStage.idle.rawValue))
        #expect(repo.load() == nil)
    }

    @Test func loadRejectsCompleted() {
        let (repo, _) = makeRepo()
        repo.save(makeState(stage: RiderStage.completed.rawValue))
        #expect(repo.load() == nil)
    }

    @Test func loadAcceptsWaitingForAcceptance() {
        let (repo, _) = makeRepo()
        repo.save(makeState(stage: RiderStage.waitingForAcceptance.rawValue))
        #expect(repo.load() != nil)
    }

    @Test func loadAcceptsDriverAccepted() {
        let (repo, _) = makeRepo()
        repo.save(makeState(stage: RiderStage.driverAccepted.rawValue))
        #expect(repo.load() != nil)
    }

    @Test func loadAcceptsEnRoute() {
        let (repo, _) = makeRepo()
        repo.save(makeState(stage: RiderStage.enRoute.rawValue))
        #expect(repo.load() != nil)
    }

    // MARK: - Expiration

    @Test func waitingForAcceptanceExpiresAtExactBoundary() {
        let (repo, _) = makeRepo()
        let now = Date.now
        let savedAt = Int(now.timeIntervalSince1970) - Int(RideConstants.broadcastTimeoutSeconds)
        repo.save(makeState(stage: RiderStage.waitingForAcceptance.rawValue, savedAt: savedAt))
        #expect(repo.load(now: now) == nil)  // age == window → expired (strict less-than)
    }

    @Test func waitingForAcceptanceSurvivesOneSecondBeforeBoundary() {
        let (repo, _) = makeRepo()
        let now = Date.now
        let savedAt = Int(now.timeIntervalSince1970) - Int(RideConstants.broadcastTimeoutSeconds) + 1
        repo.save(makeState(stage: RiderStage.waitingForAcceptance.rawValue, savedAt: savedAt))
        #expect(repo.load(now: now) != nil)  // age == window - 1 → alive
    }

    @Test func waitingForAcceptanceSurvivesWithinWindow() {
        let (repo, _) = makeRepo()
        let recent = Int(Date.now.timeIntervalSince1970) - 60
        repo.save(makeState(stage: RiderStage.waitingForAcceptance.rawValue, savedAt: recent))
        #expect(repo.load() != nil)
    }

    @Test func driverAcceptedExpiresAtWindow() {
        let (repo, _) = makeRepo()
        let now = Date.now
        let past = Int(now.timeIntervalSince1970) - Int(RideConstants.confirmationTimeoutSeconds) - 1
        repo.save(makeState(stage: RiderStage.driverAccepted.rawValue, savedAt: past))
        #expect(repo.load(now: now) == nil)
    }

    @Test func postConfirmationExpiresAtEightHours() {
        let (repo, _) = makeRepo()
        let now = Date.now
        let past = Int(now.timeIntervalSince1970) - (8 * 3600 + 1)
        repo.save(makeState(stage: RiderStage.enRoute.rawValue, savedAt: past))
        #expect(repo.load(now: now) == nil)
    }

    @Test func postConfirmationSurvivesWithinWindow() {
        let (repo, _) = makeRepo()
        let now = Date.now
        let recent = Int(now.timeIntervalSince1970) - (4 * 3600)
        repo.save(makeState(stage: RiderStage.enRoute.rawValue, savedAt: recent))
        #expect(repo.load(now: now) != nil)
    }

    @Test func customPolicyOverridesDefaults() {
        let policy = RideStateRestorationPolicy(
            waitingForAcceptance: 10, driverAccepted: 5, postConfirmation: 60
        )
        let (repo, _) = makeRepo(policy: policy)
        let now = Date.now
        let past = Int(now.timeIntervalSince1970) - 11
        repo.save(makeState(stage: RiderStage.waitingForAcceptance.rawValue, savedAt: past))
        #expect(repo.load(now: now) == nil)
    }

    @Test func expirationClearsPersistence() {
        let (repo, persistence) = makeRepo()
        let now = Date.now
        let past = Int(now.timeIntervalSince1970) - 200
        repo.save(makeState(stage: RiderStage.waitingForAcceptance.rawValue, savedAt: past))
        _ = repo.load(now: now)
        #expect(persistence.loadRaw() == nil)
    }

    @Test func unknownStageIsRejected() {
        let (repo, persistence) = makeRepo()
        repo.save(makeState(stage: "corrupt_garbage"))
        #expect(repo.load() == nil)
        #expect(persistence.loadRaw() == nil)
    }

    @Test func idleRejectionClearsPersistence() {
        let (repo, persistence) = makeRepo()
        repo.save(makeState(stage: RiderStage.idle.rawValue))
        _ = repo.load()
        #expect(persistence.loadRaw() == nil)
    }

    // MARK: - Legacy migration

    @Test func migratesLegacyPinTimestamps() {
        let (repo, _) = makeRepo()
        repo.save(makeState(
            processedPinActionKeys: nil,
            processedPinTimestamps: [1000, 2000, 3000]
        ))
        let loaded = repo.load()
        #expect(loaded?.processedPinActionKeys == ["pin_submit:1000", "pin_submit:2000", "pin_submit:3000"])
    }

    @Test func preservesExistingPinActionKeys() {
        let (repo, _) = makeRepo()
        repo.save(makeState(
            processedPinActionKeys: ["existing_key"],
            processedPinTimestamps: [9999]
        ))
        let loaded = repo.load()
        #expect(loaded?.processedPinActionKeys == ["existing_key"])
    }

    @Test func noMigrationWhenBothNil() {
        let (repo, _) = makeRepo()
        repo.save(makeState())
        let loaded = repo.load()
        #expect(loaded?.processedPinActionKeys == nil)
    }
}
```

- [ ] **Step 2: Run tests**

Run: `cd RidestrSDK && swift test --filter RideStateRepository 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add RidestrSDK/Tests/RidestrSDKTests/Ride/RideStateRepositoryTests.swift
git commit -m "test: add RideStateRepository tests for expiration, filtering, and migration"
```

---

## Task 4: Add NostrKeypair.deriveFromSymmetricKey() to SDK

**Files:**
- Modify: `RidestrSDK/Sources/RidestrSDK/Nostr/NostrKeypair.swift`
- Modify or create: NostrKeypair test file

- [ ] **Step 1: Add import and method to NostrKeypair.swift**

Add `import CryptoKit` at the top of the file (after `import Foundation` and `import NostrSDK`).

Add this method inside the `NostrKeypair` struct, after the existing factory methods:

```swift
/// Derive a Nostr keypair from arbitrary symmetric key material.
/// Uses SHA-256 to produce a 32-byte secp256k1 private key.
///
/// App developers can derive Nostr identities from authentication
/// mechanisms (passkeys, secure enclaves) without understanding
/// the underlying cryptography.
public static func deriveFromSymmetricKey(_ key: SymmetricKey) throws -> NostrKeypair {
    let rawBytes = key.withUnsafeBytes { Data($0) }
    let digest = SHA256.hash(data: rawBytes)
    let privateKeyHex = digest.compactMap { String(format: "%02x", $0) }.joined()
    return try fromHex(privateKeyHex)
}
```

- [ ] **Step 2: Add tests**

Find the existing NostrKeypair test file (`find RidestrSDK/Tests -name "*Keypair*"`) and add:

```swift
import CryptoKit

@Test func deriveFromSymmetricKeyIsDeterministic() throws {
    let keyData = Data(repeating: 0xAB, count: 32)
    let key = SymmetricKey(data: keyData)
    let keypair1 = try NostrKeypair.deriveFromSymmetricKey(key)
    let keypair2 = try NostrKeypair.deriveFromSymmetricKey(key)
    #expect(keypair1.publicKeyHex == keypair2.publicKeyHex)
    #expect(!keypair1.publicKeyHex.isEmpty)
}

@Test func deriveFromSymmetricKeyProducesKnownOutput() throws {
    // Known input: 32 bytes of 0xAB
    // SHA256(0xAB * 32) = 9a2db2e23f1504cd056606553ac049c5e718e8f9ce9233876df1a7a1821af885
    // This is the private key hex fed to secp256k1. We can construct the expected
    // keypair directly from this hex and compare public keys.
    let keyData = Data(repeating: 0xAB, count: 32)
    let key = SymmetricKey(data: keyData)
    let derived = try NostrKeypair.deriveFromSymmetricKey(key)
    let expected = try NostrKeypair.fromHex("9a2db2e23f1504cd056606553ac049c5e718e8f9ce9233876df1a7a1821af885")
    #expect(derived.publicKeyHex == expected.publicKeyHex)
}
```

- [ ] **Step 3: Run tests**

Run: `cd RidestrSDK && swift test --filter NostrKeypair 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add RidestrSDK/Sources/RidestrSDK/Nostr/NostrKeypair.swift
git add RidestrSDK/Tests/
git commit -m "feat: add NostrKeypair.deriveFromSymmetricKey() for key derivation

Allows app developers to derive Nostr keypairs from symmetric key
material without understanding SHA256/secp256k1 internals."
```

---

## Task 5: Rewrite app persistence + update all coordinator/AppState call sites (atomic)

**Files:**
- Rewrite: `RoadFlare/RoadFlare/Services/RideStatePersistence.swift`
- Modify: `RoadFlare/RoadFlare/ViewModels/RideCoordinator.swift`
- Modify: `RoadFlare/RoadFlare/ViewModels/AppState.swift`

This is a single atomic task — all three files must be updated together for the app to build.

- [ ] **Step 1: Rewrite RideStatePersistence.swift as thin UserDefaults wrapper**

```swift
import Foundation
import RidestrSDK

/// iOS-specific UserDefaults implementation of ride state persistence.
/// Domain logic (expiration, migration, stage filtering) lives in the SDK's
/// RideStateRepository. This class only handles storage.
final class UserDefaultsRideStatePersistence: RideStatePersistence, @unchecked Sendable {
    private static let key = "roadflare_active_ride_state"

    func saveRaw(_ state: PersistedRideState) {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func loadRaw() -> PersistedRideState? {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let state = try? JSONDecoder().decode(PersistedRideState.self, from: data) else {
            return nil
        }
        return state
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}
```

- [ ] **Step 2: Update RideCoordinator to construct RideStateRepository internally**

Key changes to `RideCoordinator.swift`:

1. Replace `rideRestorePolicy` property with `rideStateRepository`:
```swift
let rideStateRepository: RideStateRepository
```

2. Update init to accept persistence and construct the repo:
```swift
init(
    relayManager: any RelayManagerProtocol,
    keypair: NostrKeypair,
    driversRepository: FollowedDriversRepository,
    settings: UserSettingsRepository,
    rideHistory: RideHistoryRepository,
    bitcoinPrice: BitcoinPriceService? = nil,
    roadflareDomainService: RoadflareDomainService? = nil,
    roadflareSyncStore: RoadflareSyncStateStore? = nil,
    rideStatePersistence: RideStatePersistence,
    stageTimeouts: RideCoordinator.StageTimeouts = .interopDefault
) {
    // ... existing dependency assignment ...
    let policy = RideStateRestorationPolicy(
        waitingForAcceptance: max(0, Int(stageTimeouts.waitingForAcceptance.rounded(.up))),
        driverAccepted: max(0, Int(stageTimeouts.driverAccepted.rounded(.up))),
        postConfirmation: Int(EventExpiration.rideConfirmationHours * 3600)
    )
    self.rideStateRepository = RideStateRepository(persistence: rideStatePersistence, policy: policy)
    // ... rest of init ...
}
```

3. Update `StageTimeouts.interopDefault` to use SDK constants directly:
```swift
nonisolated static let interopDefault = StageTimeouts(
    waitingForAcceptance: RideConstants.broadcastTimeoutSeconds,
    driverAccepted: RideConstants.confirmationTimeoutSeconds
)
```

4. Remove: `restorePolicy(for:)` method, `legacyPinActionKey()` method, `rideRestorePolicy` property.

5. Update `restoreRideState()`:
   - Change `RideStatePersistence.load(restorePolicy:)` → `rideStateRepository.load()`
   - Change `RideStatePersistence.clear()` → `rideStateRepository.clear()`
   - The `RiderStage(rawValue:)` guard on the loaded state can stay as a safety check, but the SDK now rejects unknown stages in `load()` so it will never return corrupt data. Keep it as belt-and-suspenders.
   - Remove `legacyPinActionKey` conversion from line 131 — migration now happens in SDK's `load()`. Change to: `processedPinActionKeys: Set(saved.processedPinActionKeys ?? [])`

6. Update `persistRideState()` to construct `PersistedRideState` and call `rideStateRepository.save()`:
```swift
func persistRideState() {
    let pickup = pickupLocation ?? session.precisePickup
    let destination = destinationLocation ?? session.preciseDestination
    let state = PersistedRideState(
        stage: session.stage.rawValue,
        offerEventId: session.offerEventId,
        acceptanceEventId: session.acceptanceEventId,
        confirmationEventId: session.confirmationEventId,
        driverPubkey: session.driverPubkey,
        pin: session.pin,
        pinVerified: session.pinVerified,
        paymentMethodRaw: session.paymentMethod,
        fiatPaymentMethodsRaw: session.fiatPaymentMethods,
        pickupLat: pickup?.latitude,
        pickupLon: pickup?.longitude,
        pickupAddress: pickup?.address,
        destLat: destination?.latitude,
        destLon: destination?.longitude,
        destAddress: destination?.address,
        fareUSD: currentFareEstimate.map { "\($0.fareUSD)" },
        fareDistanceMiles: currentFareEstimate?.distanceMiles,
        fareDurationMinutes: currentFareEstimate?.durationMinutes,
        savedAt: Int(Date.now.timeIntervalSince1970),
        processedPinActionKeys: session.processedPinActionKeys.isEmpty ? nil : Array(session.processedPinActionKeys),
        processedPinTimestamps: nil,
        pinAttempts: session.pinAttempts > 0 ? session.pinAttempts : nil,
        precisePickupShared: session.precisePickupShared ? true : nil,
        preciseDestinationShared: session.preciseDestinationShared ? true : nil,
        lastDriverStatus: session.lastDriverStatus,
        lastDriverStateTimestamp: session.lastDriverStateTimestamp > 0 ? session.lastDriverStateTimestamp : nil,
        lastDriverActionCount: session.lastDriverActionCount > 0 ? session.lastDriverActionCount : nil,
        riderStateHistory: session.riderStateHistory.isEmpty ? nil : session.riderStateHistory
    )
    rideStateRepository.save(state)
}
```

7. Update `forceEndRide()`: `RideStatePersistence.clear()` → `rideStateRepository.clear()`

8. Update `sessionShouldPersist()`: `RideStatePersistence.clear()` → `rideStateRepository.clear()`

- [ ] **Step 3: Update AppState**

Add a stored property on AppState for direct persistence access:

```swift
private let rideStatePersistence = UserDefaultsRideStatePersistence()
```

At both `RideCoordinator(` call sites (~lines 303 and 350), pass this shared instance:

```swift
let coordinator = RideCoordinator(
    relayManager: rm, keypair: keypair,
    driversRepository: repo, settings: settings,
    rideHistory: rideHistory, bitcoinPrice: bitcoinPrice,
    roadflareDomainService: service,
    roadflareSyncStore: sync.roadflareSyncStore,
    rideStatePersistence: rideStatePersistence
)
```

Update `prepareForIdentityReplacement()` (line ~391): change `RideStatePersistence.clear()` → `rideStatePersistence.clear()`

This works even when `rideCoordinator` is nil (during `generateNewKey`/`importKey` before a coordinator exists). The persistence handle is app-owned, not reached through an optional coordinator.

- [ ] **Step 4: Verify app builds**

Run: `cd RoadFlare && xcodebuild build -scheme RoadFlare -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -5`

Expected: BUILD SUCCEEDED (tests may not compile yet — that's Task 7)

- [ ] **Step 5: Commit**

```bash
git add RoadFlare/RoadFlare/Services/RideStatePersistence.swift
git add RoadFlare/RoadFlare/ViewModels/RideCoordinator.swift
git add RoadFlare/RoadFlare/ViewModels/AppState.swift
git commit -m "refactor: wire RideCoordinator to SDK RideStateRepository

Replace all static RideStatePersistence calls with injected repository.
Coordinator constructs RideStateRepository internally from stageTimeouts,
preserving the current policy-from-timeouts derivation pattern.
App's RideStatePersistence rewritten as thin UserDefaults wrapper."
```

---

## Task 6: Update PasskeyManager to use SDK key derivation

**Files:**
- Modify: `RoadFlare/RoadFlare/Services/PasskeyManager.swift`

- [ ] **Step 1: Replace inline derivation with SDK call**

Remove the private `deriveNostrKey(from:)` method. Replace both call sites:

```swift
// In createPasskeyAndDeriveKey():
let prfKey = try await createPasskey()
return try NostrKeypair.deriveFromSymmetricKey(prfKey)

// In authenticateAndDeriveKey():
let prfKey = try await authenticateWithPasskey()
return try NostrKeypair.deriveFromSymmetricKey(prfKey)
```

Ensure `import CryptoKit` is present (needed for `SymmetricKey` type in method signatures).

- [ ] **Step 2: Verify app builds**

Run: `cd RoadFlare && xcodebuild build -scheme RoadFlare -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add RoadFlare/RoadFlare/Services/PasskeyManager.swift
git commit -m "refactor: use SDK NostrKeypair.deriveFromSymmetricKey() in PasskeyManager"
```

---

## Task 7: Migrate app tests

**Files:**
- Modify: `RoadFlare/RoadFlareTests/RoadFlareTests.swift`
- Modify: `RoadFlare/RoadFlareTests/RideCoordinatorTests.swift`

This is the largest task. Two test files need updating with ~40 call site changes.

- [ ] **Step 1: Rename and update RideStatePersistenceTests in RoadFlareTests.swift**

1. Rename the suite struct from `RideStatePersistenceTests` to `UserDefaultsRideStatePersistenceTests`. Also update the `@Suite("...")` display name to `@Suite("UserDefaultsRideStatePersistence Tests")`.

2. Update `init()`: `RideStatePersistence.clear()` → `UserDefaultsRideStatePersistence().clear()`

3. The persistence tests that test **UserDefaults round-trips** stay in the app (they test iOS storage, not domain logic):
   - `saveAndLoad`, `savePersistsDriverStateCursorFromSession`, `clearRemovesData`, `saveWithoutLocations`, `pinSurvivesPersistence`, `pinAttemptsSurvivePersistence`

4. The persistence tests that test **expiration/stage filtering** move to SDK Task 3 (already done). Remove from app tests:
   - `loadIgnoresIdle`, `loadIgnoresCompleted`, `loadAcceptsWaitingForAcceptance`, `waitingForAcceptanceSurvivesShortRelaunchWithinOfferLifetime`, `waitingForAcceptanceExpiresWithDriverOfferVisibilityWindow`, `loadAcceptsDriverAccepted`, `driverAcceptedExpiresWithDriverConfirmationTimeout`, `loadAcceptsDriverArrived`, `loadAcceptsInProgress`

5. Update remaining tests: replace all `RideStatePersistence.` calls with `UserDefaultsRideStatePersistence()` or `RideStateRepository` as appropriate.

6. The `save(session:...)` convenience is gone. Tests that used it need to construct `PersistedRideState` manually and call `persistence.saveRaw()`. Add a helper:

```swift
private func makePersistedState(
    session: RiderRideSession,
    pickup: Location? = nil,
    destination: Location? = nil,
    fare: FareEstimate? = nil,
    savedAt: Int = Int(Date.now.timeIntervalSince1970)
) -> PersistedRideState {
    let p = pickup ?? session.precisePickup
    let d = destination ?? session.preciseDestination
    return PersistedRideState(
        stage: session.stage.rawValue,
        offerEventId: session.offerEventId,
        acceptanceEventId: session.acceptanceEventId,
        confirmationEventId: session.confirmationEventId,
        driverPubkey: session.driverPubkey,
        pin: session.pin,
        pinVerified: session.pinVerified,
        paymentMethodRaw: session.paymentMethod,
        fiatPaymentMethodsRaw: session.fiatPaymentMethods,
        pickupLat: p?.latitude, pickupLon: p?.longitude, pickupAddress: p?.address,
        destLat: d?.latitude, destLon: d?.longitude, destAddress: d?.address,
        fareUSD: fare.map { "\($0.fareUSD)" },
        fareDistanceMiles: fare?.distanceMiles,
        fareDurationMinutes: fare?.durationMinutes,
        savedAt: savedAt,
        processedPinActionKeys: session.processedPinActionKeys.isEmpty ? nil : Array(session.processedPinActionKeys),
        processedPinTimestamps: nil,
        pinAttempts: session.pinAttempts > 0 ? session.pinAttempts : nil,
        precisePickupShared: session.precisePickupShared ? true : nil,
        preciseDestinationShared: session.preciseDestinationShared ? true : nil,
        lastDriverStatus: session.lastDriverStatus,
        lastDriverStateTimestamp: session.lastDriverStateTimestamp > 0 ? session.lastDriverStateTimestamp : nil,
        lastDriverActionCount: session.lastDriverActionCount > 0 ? session.lastDriverActionCount : nil,
        riderStateHistory: session.riderStateHistory.isEmpty ? nil : session.riderStateHistory
    )
}
```

- [ ] **Step 2: Update RideCoordinatorTests**

1. Update `makeCoordinator()` to accept and return persistence:

```swift
@MainActor
private func makeCoordinator(
    keypair existingKeypair: NostrKeypair? = nil,
    keepSubscriptionsAlive: Bool = false,
    clearRidePersistence: Bool = true,
    roadflarePaymentMethods: [String] = ["zelle"],
    rideStatePersistence: InMemoryRideStatePersistence? = nil,
    stageTimeouts: RideCoordinator.StageTimeouts = .interopDefault
) async throws -> (RideCoordinator, FakeRelayManager, NostrKeypair, RideHistoryRepository, InMemoryRideStatePersistence) {
    let persistence = rideStatePersistence ?? InMemoryRideStatePersistence()
    if clearRidePersistence {
        persistence.clear()
    }
    let keypair = try existingKeypair ?? NostrKeypair.generate()
    let fake = FakeRelayManager()
    fake.keepSubscriptionsAlive = keepSubscriptionsAlive
    try await fake.connect(to: DefaultRelays.all)

    let repo = FollowedDriversRepository(persistence: InMemoryFollowedDriversPersistence())
    let settings = UserSettingsRepository(persistence: InMemoryUserSettingsPersistence())
    settings.setRoadflarePaymentMethods(roadflarePaymentMethods)
    let history = RideHistoryRepository(persistence: InMemoryRideHistoryPersistence())
    let bitcoinPrice = BitcoinPriceService()
    bitcoinPrice.btcPriceUsdForTesting = 100_000

    let coordinator = RideCoordinator(
        relayManager: fake,
        keypair: keypair,
        driversRepository: repo,
        settings: settings,
        rideHistory: history,
        bitcoinPrice: bitcoinPrice,
        rideStatePersistence: persistence,
        stageTimeouts: stageTimeouts
    )
    return (coordinator, fake, keypair, history, persistence)
}
```

2. Add `makePersistedState()` helper (same as RoadFlareTests version above).

3. Update ALL existing `makeCoordinator()` call sites to destructure 5-tuple:
   - `let (coordinator, fake, keypair, history, _) = try await makeCoordinator(...)` — most tests don't need persistence
   - `let (coordinator, fake, keypair, history, persistence) = try await makeCoordinator(...)` — restore/persist tests need it

4. Update **restore tests** (lines 318-456): Replace `RideStatePersistence.save(session:...)` with:
```swift
let state = makePersistedState(session: savedSession, pickup: pickup, destination: destination, fare: fare)
let persistence = InMemoryRideStatePersistence()
persistence.saveRaw(state)
let (coordinator, ..., _) = try await makeCoordinator(
    keypair: keypair, clearRidePersistence: false,
    rideStatePersistence: persistence
)
```

5. Update **custom timeout test** (line 346): Replace `RideStatePersistence.RestorePolicy(...)` with custom `stageTimeouts`:
```swift
// The stageTimeouts: .init(waitingForAcceptance: 1, driverAccepted: 30) already drives
// the policy via RideCoordinator's internal RideStateRestorationPolicy construction.
// The test just needs to pass the custom stageTimeouts and use pre-populated persistence.
let persistence = InMemoryRideStatePersistence()
let state = makePersistedState(session: savedSession, ..., savedAt: Int(Date.now.timeIntervalSince1970) - 2)
persistence.saveRaw(state)
let (coordinator, ..., _) = try await makeCoordinator(
    keypair: keypair, clearRidePersistence: false,
    rideStatePersistence: persistence,
    stageTimeouts: .init(waitingForAcceptance: 1, driverAccepted: 30)
)
#expect(coordinator.session.stage == .idle)
```

6. Update **assertion-side persistence checks** (7 call sites):
   - `RideStatePersistence.load()?.stage` → `persistence.loadRaw()?.stage` or `coordinator.rideStateRepository.load()?.stage`
   - `RideStatePersistence.load() == nil` → `persistence.loadRaw() == nil`

7. Update **cleanup calls**:
   - `RideStatePersistence.clear()` → `persistence.clear()` (where persistence is available)
   - `defer { RideStatePersistence.clear() }` → `defer { persistence.clear() }`

- [ ] **Step 3: Run all tests**

Run: `cd RidestrSDK && swift test 2>&1 | tail -10`
Run: `cd RoadFlare && xcodebuild build -scheme RoadFlare -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -5`

Expected: All SDK tests pass, app builds

- [ ] **Step 4: Commit**

```bash
git add RoadFlare/RoadFlareTests/
git commit -m "test: migrate persistence tests to SDK types and injected persistence

Rename suite to UserDefaultsRideStatePersistenceTests. Expiration tests
now in SDK. Coordinator tests use injected InMemoryRideStatePersistence.
Add makePersistedState() helper for 28-field construction."
```

---

## Task 8: Final verification and cleanup

**Files:**
- No new files — verification only

- [ ] **Step 1: Run full SDK test suite**

Run: `cd RidestrSDK && swift test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 2: Run full Xcode build**

Run: `cd RoadFlare && xcodebuild build -scheme RoadFlare -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Verify no remaining references to old API**

Run: `grep -r "RideStatePersistence\.\(load\|save\|clear\|RestorePolicy\|interop\)" RoadFlare/ --include="*.swift"`
Expected: No results (all old static calls eliminated)

Run: `grep -r "legacyPinActionKey\|interopOfferVisibilitySeconds\|interopConfirmationWaitSeconds" RoadFlare/ --include="*.swift"`
Expected: No results (constants moved to SDK)

- [ ] **Step 4: Verify SDK protocol naming is clean**

Run: `grep -r "RideStatePersistenceProtocol" RidestrSDK/ RoadFlare/ --include="*.swift"`
Expected: No results (we use `RideStatePersistence` without `Protocol` suffix)

- [ ] **Step 5: Commit if any cleanup needed**

```bash
git commit -m "refactor: cleanup remaining old RideStatePersistence references" --allow-empty
```

---

## Verification Checklist

After all tasks:

- [ ] `PersistedRideState` lives in SDK (no `Equatable` — `RiderRideAction` doesn't conform)
- [ ] `RideStateRepository` owns expiration, stage filtering, legacy migration
- [ ] `RideStatePersistence` protocol (no `Protocol` suffix) is the abstract storage interface
- [ ] `UserDefaultsRideStatePersistence` is the thin iOS implementation
- [ ] `InMemoryRideStatePersistence` exists for SDK and coordinator tests
- [ ] `RideCoordinator` accepts `RideStatePersistence` via init, constructs `RideStateRepository` internally with policy derived from `stageTimeouts`
- [ ] `AppState` owns a stored `rideStatePersistence` property and passes it to coordinator
- [ ] `NostrKeypair.deriveFromSymmetricKey()` exists in SDK with `import CryptoKit`
- [ ] `PasskeyManager` uses SDK derivation, no inline crypto
- [ ] No remaining `RideStatePersistence.load/save/clear()` static calls in app
- [ ] All SDK tests pass (including exact boundary timestamp tests)
- [ ] Full Xcode build succeeds
- [ ] Existing coordinator tests pass with injected persistence + 5-tuple destructure
- [ ] Test suite renamed to `UserDefaultsRideStatePersistenceTests`
- [ ] Expiration tests live in SDK, not app
- [ ] `makePersistedState()` helper in both test files
