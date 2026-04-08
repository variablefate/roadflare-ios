# RideStatePersistence SDK Migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate ride state persistence domain logic (expiration, stage filtering, legacy migration) from the iOS app layer to the SDK, following the proven UserSettingsRepository pattern. Also extract Nostr key derivation from PasskeyManager into the SDK.

**Architecture:** SDK owns the persistence contract (`PersistedRideState`), validation/expiration logic (`RideStateRepository`), and abstract storage interface (`RideStatePersistence` protocol). App provides the iOS-specific `UserDefaultsRideStatePersistence` implementation. `RideCoordinator` receives an injected `RideStateRepository` instead of calling static methods.

**Tech Stack:** Swift, RidestrSDK (SPM package), Swift Testing framework, `@unchecked Sendable` + `NSLock` pattern for thread safety

---

## File Structure

| File | Change | Responsibility |
|------|--------|---------------|
| `RidestrSDK/.../Ride/PersistedRideState.swift` | CREATE | 24-field Codable struct + `migrated()` legacy normalization |
| `RidestrSDK/.../Ride/RideStateRepository.swift` | CREATE | Repository class + `RideStatePersistence` protocol + `RideStateRestorationPolicy` + `InMemoryRideStatePersistence` |
| `RidestrSDK/.../Nostr/NostrKeypair.swift` | MODIFY | Add `deriveFromSymmetricKey()` static method |
| `RidestrSDK/Tests/.../RideStateRepositoryTests.swift` | CREATE | Expiration, stage filtering, legacy migration, round-trip tests |
| `RidestrSDK/Tests/.../NostrKeypairTests.swift` | MODIFY | Add derivation determinism test |
| `RoadFlare/.../Services/RideStatePersistence.swift` | REWRITE | Thin UserDefaults wrapper implementing SDK protocol |
| `RoadFlare/.../ViewModels/RideCoordinator.swift` | MODIFY | Accept injected `RideStateRepository`, remove static calls |
| `RoadFlare/.../ViewModels/AppState.swift` | MODIFY | Create and inject `RideStateRepository` |
| `RoadFlare/.../Services/PasskeyManager.swift` | MODIFY | Call `NostrKeypair.deriveFromSymmetricKey()` |
| `RoadFlare/RoadFlareTests/RoadFlareTests.swift` | MODIFY | Split persistence tests: expiration → SDK, UserDefaults → app |
| `RoadFlare/RoadFlareTests/RideCoordinatorTests.swift` | MODIFY | Use injected persistence via `InMemoryRideStatePersistence` |

---

## Task 1: Create PersistedRideState in SDK

**Files:**
- Create: `RidestrSDK/Sources/RidestrSDK/Ride/PersistedRideState.swift`

Move the 24-field Codable struct from the app to the SDK. Add the `migrated()` method for legacy PIN timestamp normalization.

- [ ] **Step 1: Create the file with the struct and migration method**

```swift
// RidestrSDK/Sources/RidestrSDK/Ride/PersistedRideState.swift
import Foundation

/// Canonical persistence contract for active ride state.
/// Both platforms (iOS/Android) agree on this shape.
public struct PersistedRideState: Codable, Sendable, Equatable {
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
        offerEventId: String?,
        acceptanceEventId: String?,
        confirmationEventId: String?,
        driverPubkey: String?,
        pin: String?,
        pinVerified: Bool,
        paymentMethodRaw: String?,
        fiatPaymentMethodsRaw: [String],
        pickupLat: Double?,
        pickupLon: Double?,
        pickupAddress: String?,
        destLat: Double?,
        destLon: Double?,
        destAddress: String?,
        fareUSD: String?,
        fareDistanceMiles: Double?,
        fareDurationMinutes: Double?,
        savedAt: Int,
        processedPinActionKeys: [String]?,
        processedPinTimestamps: [Int]?,
        pinAttempts: Int?,
        precisePickupShared: Bool?,
        preciseDestinationShared: Bool?,
        lastDriverStatus: String?,
        lastDriverStateTimestamp: Int?,
        lastDriverActionCount: Int?,
        riderStateHistory: [RiderRideAction]?
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
        if processedPinActionKeys == nil, let timestamps = processedPinTimestamps {
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
        return self
    }
}
```

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

This file contains: the `RideStatePersistenceProtocol`, `RideStateRestorationPolicy`, `RideStateRepository` class, and `InMemoryRideStatePersistence` test double.

- [ ] **Step 1: Create the file**

```swift
// RidestrSDK/Sources/RidestrSDK/Ride/RideStateRepository.swift
import Foundation

// MARK: - Persistence Protocol

/// Abstract storage for ride state. iOS implements with UserDefaults;
/// tests use InMemoryRideStatePersistence.
public protocol RideStatePersistenceProtocol: Sendable {
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
    private let persistence: RideStatePersistenceProtocol
    private let policy: RideStateRestorationPolicy

    public init(
        persistence: RideStatePersistenceProtocol,
        policy: RideStateRestorationPolicy = .default
    ) {
        self.persistence = persistence
        self.policy = policy
    }

    /// Save ride state. Delegates to persistence.
    public func save(_ state: PersistedRideState) {
        persistence.saveRaw(state)
    }

    /// Load validated ride state. Returns nil if:
    /// - No data stored
    /// - State has expired (age > policy window for its stage)
    /// - Stage is idle or completed (not restorable)
    /// Applies legacy field migration before returning.
    public func load(now: Date = .now) -> PersistedRideState? {
        guard let raw = persistence.loadRaw() else { return nil }

        let age = Int(now.timeIntervalSince1970) - raw.savedAt
        guard age < policy.maxRestoreAge(for: raw.stage) else {
            persistence.clear()
            return nil
        }

        guard raw.stage != RiderStage.idle.rawValue,
              raw.stage != RiderStage.completed.rawValue else {
            persistence.clear()
            return nil
        }

        return raw.migrated()
    }

    /// Clear persisted ride state.
    public func clear() {
        persistence.clear()
    }
}

// MARK: - In-Memory Test Double

/// In-memory persistence for testing. Thread-safe via NSLock.
public final class InMemoryRideStatePersistence: RideStatePersistenceProtocol, @unchecked Sendable {
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
            acceptanceEventId: nil, confirmationEventId: nil,
            driverPubkey: "driver_pubkey_hex", pin: "1234", pinVerified: false,
            paymentMethodRaw: "zelle", fiatPaymentMethodsRaw: ["zelle", "cash"],
            pickupLat: 40.71, pickupLon: -74.01, pickupAddress: "Penn Station",
            destLat: 40.76, destLon: -73.98, destAddress: "Central Park",
            fareUSD: "12.50", fareDistanceMiles: 5.5, fareDurationMinutes: 18,
            savedAt: savedAt,
            processedPinActionKeys: processedPinActionKeys,
            processedPinTimestamps: processedPinTimestamps,
            pinAttempts: nil, precisePickupShared: nil, preciseDestinationShared: nil,
            lastDriverStatus: nil, lastDriverStateTimestamp: nil,
            lastDriverActionCount: nil, riderStateHistory: nil
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

    @Test func waitingForAcceptanceExpiresAtWindow() {
        let (repo, _) = makeRepo()
        let past = Int(Date.now.timeIntervalSince1970) - 121  // 121s ago, window is 120s
        repo.save(makeState(stage: RiderStage.waitingForAcceptance.rawValue, savedAt: past))
        #expect(repo.load() == nil)
    }

    @Test func waitingForAcceptanceSurvivesWithinWindow() {
        let (repo, _) = makeRepo()
        let recent = Int(Date.now.timeIntervalSince1970) - 60  // 60s ago, window is 120s
        repo.save(makeState(stage: RiderStage.waitingForAcceptance.rawValue, savedAt: recent))
        #expect(repo.load() != nil)
    }

    @Test func driverAcceptedExpiresAtWindow() {
        let (repo, _) = makeRepo()
        let past = Int(Date.now.timeIntervalSince1970) - 31  // 31s ago, window is 30s
        repo.save(makeState(stage: RiderStage.driverAccepted.rawValue, savedAt: past))
        #expect(repo.load() == nil)
    }

    @Test func postConfirmationExpiresAtEightHours() {
        let (repo, _) = makeRepo()
        let past = Int(Date.now.timeIntervalSince1970) - (8 * 3600 + 1)  // 8h + 1s ago
        repo.save(makeState(stage: RiderStage.enRoute.rawValue, savedAt: past))
        #expect(repo.load() == nil)
    }

    @Test func postConfirmationSurvivesWithinWindow() {
        let (repo, _) = makeRepo()
        let recent = Int(Date.now.timeIntervalSince1970) - (4 * 3600)  // 4h ago
        repo.save(makeState(stage: RiderStage.enRoute.rawValue, savedAt: recent))
        #expect(repo.load() != nil)
    }

    @Test func customPolicyOverridesDefaults() {
        let policy = RideStateRestorationPolicy(
            waitingForAcceptance: 10, driverAccepted: 5, postConfirmation: 60
        )
        let (repo, _) = makeRepo(policy: policy)
        let past = Int(Date.now.timeIntervalSince1970) - 11  // 11s ago, custom window is 10s
        repo.save(makeState(stage: RiderStage.waitingForAcceptance.rawValue, savedAt: past))
        #expect(repo.load() == nil)
    }

    @Test func expirationClearsPersistence() {
        let (repo, persistence) = makeRepo()
        let past = Int(Date.now.timeIntervalSince1970) - 200
        repo.save(makeState(stage: RiderStage.waitingForAcceptance.rawValue, savedAt: past))
        _ = repo.load()  // triggers expiration
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
        repo.save(makeState(processedPinActionKeys: nil, processedPinTimestamps: nil))
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
- Modify: `RidestrSDK/Tests/RidestrSDKTests/Nostr/NostrKeypairTests.swift` (or create if needed)

- [ ] **Step 1: Add the derivation method to NostrKeypair**

Append to the existing `NostrKeypair` struct, after the existing factory methods:

```swift
import CryptoKit

// Add to NostrKeypair:

/// Derive a Nostr keypair from arbitrary symmetric key material.
/// Uses SHA-256 to produce a 32-byte secp256k1 private key.
///
/// This allows app developers to derive Nostr identities from
/// authentication mechanisms (passkeys, secure enclaves) without
/// needing to understand the underlying cryptography.
public static func deriveFromSymmetricKey(_ key: SymmetricKey) throws -> NostrKeypair {
    let rawBytes = key.withUnsafeBytes { Data($0) }
    let digest = SHA256.hash(data: rawBytes)
    let privateKeyHex = digest.compactMap { String(format: "%02x", $0) }.joined()
    return try fromHex(privateKeyHex)
}
```

Note: `CryptoKit` may already be imported. If not, add `import CryptoKit` at the top of the file.

- [ ] **Step 2: Add a determinism test**

Add to the existing NostrKeypair test file (find it with `find RidestrSDK/Tests -name "*Keypair*"`):

```swift
@Test func deriveFromSymmetricKeyIsDeterministic() throws {
    let keyData = Data(repeating: 0xAB, count: 32)
    let key = SymmetricKey(data: keyData)
    let keypair1 = try NostrKeypair.deriveFromSymmetricKey(key)
    let keypair2 = try NostrKeypair.deriveFromSymmetricKey(key)
    #expect(keypair1.publicKeyHex == keypair2.publicKeyHex)
    #expect(!keypair1.publicKeyHex.isEmpty)
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

## Task 5: Rewrite app RideStatePersistence as thin UserDefaults wrapper

**Files:**
- Rewrite: `RoadFlare/RoadFlare/Services/RideStatePersistence.swift`

This file becomes a pure storage adapter implementing the SDK's `RideStatePersistenceProtocol`. No domain logic, no expiration, no migration.

- [ ] **Step 1: Rewrite the file**

```swift
import Foundation
import RidestrSDK

/// iOS-specific UserDefaults implementation of ride state persistence.
/// Domain logic (expiration, migration, stage filtering) lives in the SDK's
/// RideStateRepository. This class only handles storage.
final class UserDefaultsRideStatePersistence: RideStatePersistenceProtocol, @unchecked Sendable {
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

- [ ] **Step 2: Verify app builds**

Run: `cd RoadFlare && xcodebuild build -scheme RoadFlare -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -5`

Expected: This will initially FAIL because RideCoordinator and AppState still reference the old `RideStatePersistence` type. That's expected — Task 6 fixes those call sites.

- [ ] **Step 3: Commit (WIP — will break build until Task 6)**

```bash
git add RoadFlare/RoadFlare/Services/RideStatePersistence.swift
git commit -m "refactor: rewrite RideStatePersistence as thin UserDefaults wrapper

WIP: RideCoordinator and AppState still reference old static API.
Next commit updates call sites."
```

---

## Task 6: Update RideCoordinator to use injected RideStateRepository

**Files:**
- Modify: `RoadFlare/RoadFlare/ViewModels/RideCoordinator.swift`

Replace all static `RideStatePersistence.load/save/clear()` calls with the injected `RideStateRepository`.

- [ ] **Step 1: Add RideStateRepository to init and update all call sites**

Changes to RideCoordinator:

1. Add `rideStateRepository` property:
```swift
let rideStateRepository: RideStateRepository
```

2. Update `init` to accept it (add parameter after `stageTimeouts`):
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
    rideStateRepository: RideStateRepository,
    stageTimeouts: RideCoordinator.StageTimeouts = .interopDefault
)
```

3. Remove: `rideRestorePolicy` property and `Self.restorePolicy(for:)` method and `legacyPinActionKey()` — all moved to SDK.

4. Remove: `StageTimeouts` interop constants referencing `RideStatePersistence.interopOfferVisibilitySeconds` — these now come from `RideConstants` directly. Update `StageTimeouts.interopDefault`:
```swift
nonisolated static let interopDefault = StageTimeouts(
    waitingForAcceptance: RideConstants.broadcastTimeoutSeconds,
    driverAccepted: RideConstants.confirmationTimeoutSeconds
)
```

5. Update `restoreRideState()`:
```swift
func restoreRideState() {
    guard let saved = rideStateRepository.load(),
          let restoredStage = RiderStage(rawValue: saved.stage) else {
        return
    }
    // ... rest unchanged, but remove the legacyPinActionKey conversion from
    // the processedPinActionKeys line — migration now happens in SDK's load()
    // Change line 131 from:
    //   processedPinActionKeys: Set(saved.processedPinActionKeys ?? saved.processedPinTimestamps?.map(Self.legacyPinActionKey) ?? []),
    // To:
    //   processedPinActionKeys: Set(saved.processedPinActionKeys ?? []),
}
```

6. Update `persistRideState()` to construct `PersistedRideState` and call `rideStateRepository.save()`:
```swift
func persistRideState() {
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
        pickupLat: (pickupLocation ?? session.precisePickup)?.latitude,
        pickupLon: (pickupLocation ?? session.precisePickup)?.longitude,
        pickupAddress: (pickupLocation ?? session.precisePickup)?.address,
        destLat: (destinationLocation ?? session.preciseDestination)?.latitude,
        destLon: (destinationLocation ?? session.preciseDestination)?.longitude,
        destAddress: (destinationLocation ?? session.preciseDestination)?.address,
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

7. Update `forceEndRide()`: change `RideStatePersistence.clear()` → `rideStateRepository.clear()`

8. Update `sessionShouldPersist()`: change `RideStatePersistence.clear()` → `rideStateRepository.clear()`

- [ ] **Step 2: Update AppState to create and inject RideStateRepository**

In `AppState.swift`, at both `RideCoordinator(` call sites (lines ~303 and ~350):

```swift
let rideStatePersistence = UserDefaultsRideStatePersistence()
let rideStateRepo = RideStateRepository(persistence: rideStatePersistence)

let coordinator = RideCoordinator(
    relayManager: rm, keypair: keypair,
    driversRepository: repo, settings: settings,
    rideHistory: rideHistory, bitcoinPrice: bitcoinPrice,
    roadflareDomainService: service,
    roadflareSyncStore: sync.roadflareSyncStore,
    rideStateRepository: rideStateRepo
)
```

Update `prepareForIdentityReplacement()`: change `RideStatePersistence.clear()` → `rideCoordinator?.rideStateRepository.clear()` (or keep a reference to the repo).

- [ ] **Step 3: Verify app builds**

Run: `cd RoadFlare && xcodebuild build -scheme RoadFlare -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add RoadFlare/RoadFlare/ViewModels/RideCoordinator.swift
git add RoadFlare/RoadFlare/ViewModels/AppState.swift
git commit -m "refactor: update RideCoordinator and AppState to use injected RideStateRepository

Replace all static RideStatePersistence calls with injected repository.
Remove RestorePolicy, legacyPinActionKey, and interop constants from
coordinator — all moved to SDK."
```

---

## Task 7: Update PasskeyManager to use SDK key derivation

**Files:**
- Modify: `RoadFlare/RoadFlare/Services/PasskeyManager.swift`

- [ ] **Step 1: Replace inline derivation with SDK call**

Remove the private `deriveNostrKey(from:)` method (lines 115-121). Replace both call sites:

```swift
// In createPasskeyAndDeriveKey():
let prfKey = try await createPasskey()
return try NostrKeypair.deriveFromSymmetricKey(prfKey)

// In authenticateAndDeriveKey():
let prfKey = try await authenticateWithPasskey()
return try NostrKeypair.deriveFromSymmetricKey(prfKey)
```

Add `import RidestrSDK` if not already present (it likely already is for `NostrKeypair`).

- [ ] **Step 2: Verify app builds**

Run: `cd RoadFlare && xcodebuild build -scheme RoadFlare -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add RoadFlare/RoadFlare/Services/PasskeyManager.swift
git commit -m "refactor: use SDK NostrKeypair.deriveFromSymmetricKey() in PasskeyManager

Remove inline key derivation. App developers no longer need to
understand SHA256/secp256k1 internals for Nostr key derivation."
```

---

## Task 8: Migrate app tests

**Files:**
- Modify: `RoadFlare/RoadFlareTests/RoadFlareTests.swift`
- Modify: `RoadFlare/RoadFlareTests/RideCoordinatorTests.swift`

- [ ] **Step 1: Update RideStatePersistenceTests in RoadFlareTests.swift**

The `RideStatePersistenceTests` suite needs to:
1. Rename references from `RideStatePersistence.PersistedRideState` → `PersistedRideState` (now SDK type)
2. Replace `RideStatePersistence.RestorePolicy` → `RideStateRestorationPolicy`
3. The expiration tests that test domain logic (age windows, stage filtering) now live in SDK Task 3. The app tests should focus on UserDefaults round-trips only.
4. Update `RideStatePersistence.save(session:...)` calls → construct `PersistedRideState` manually and call `UserDefaultsRideStatePersistence().saveRaw()`
5. Update `RideStatePersistence.load()` → `UserDefaultsRideStatePersistence().loadRaw()` for raw storage tests, or use `RideStateRepository` for validated tests
6. Update `RideStatePersistence.clear()` → `UserDefaultsRideStatePersistence().clear()`

The helper `setupAndSave()` needs to construct `PersistedRideState` directly instead of passing a `RiderRideSession`.

- [ ] **Step 2: Update RideCoordinatorTests makeCoordinator()**

Change `makeCoordinator()` to inject `InMemoryRideStatePersistence`:

```swift
private func makeCoordinator(
    keypair existingKeypair: NostrKeypair? = nil,
    keepSubscriptionsAlive: Bool = false,
    clearRidePersistence: Bool = true,
    roadflarePaymentMethods: [String] = ["zelle"],
    stageTimeouts: RideCoordinator.StageTimeouts = .interopDefault,
    rideStatePersistence: InMemoryRideStatePersistence? = nil
) async throws -> (RideCoordinator, FakeRelayManager, NostrKeypair, RideHistoryRepository) {
    let persistence = rideStatePersistence ?? InMemoryRideStatePersistence()
    let rideStateRepo = RideStateRepository(persistence: persistence)
    if clearRidePersistence {
        rideStateRepo.clear()
    }
    // ... rest of setup ...
    let coordinator = RideCoordinator(
        relayManager: fake,
        keypair: keypair,
        driversRepository: repo,
        settings: settings,
        rideHistory: history,
        bitcoinPrice: bitcoinPrice,
        rideStateRepository: rideStateRepo,
        stageTimeouts: stageTimeouts
    )
    return (coordinator, fake, keypair, history)
}
```

Tests that pre-populate persistence for restore testing need to save via the `InMemoryRideStatePersistence` instance before creating the coordinator.

- [ ] **Step 3: Run all tests**

Run: `cd RidestrSDK && swift test 2>&1 | tail -10`
Run: `cd RoadFlare && xcodebuild build -scheme RoadFlare -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -5`

Expected: All SDK tests pass, app builds

- [ ] **Step 4: Commit**

```bash
git add RoadFlare/RoadFlareTests/
git commit -m "test: migrate persistence tests to use SDK types and injected persistence

Expiration/migration tests live in SDK. App tests focus on
UserDefaults round-trips and coordinator integration."
```

---

## Task 9: Final verification and cleanup

**Files:**
- No new files — verification only

- [ ] **Step 1: Run full SDK test suite**

Run: `cd RidestrSDK && swift test 2>&1 | tail -20`

Expected: All tests pass (existing + new RideStateRepository + new keypair derivation)

- [ ] **Step 2: Run full Xcode build**

Run: `cd RoadFlare && xcodebuild build -scheme RoadFlare -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Verify no remaining references to old API**

Run: `grep -r "RideStatePersistence\." RoadFlare/RoadFlare/ --include="*.swift" | grep -v UserDefaultsRideStatePersistence`

Expected: No results (all static calls eliminated)

Run: `grep -r "legacyPinActionKey\|interopOfferVisibilitySeconds\|interopConfirmationWaitSeconds" RoadFlare/ --include="*.swift"`

Expected: No results (constants moved to SDK)

- [ ] **Step 4: Commit any cleanup**

```bash
git commit -m "refactor: cleanup remaining old RideStatePersistence references" --allow-empty
```

---

## Verification Checklist

After all tasks:

- [ ] `PersistedRideState` lives in SDK, not app
- [ ] `RideStateRepository` owns expiration, stage filtering, legacy migration
- [ ] `RideStatePersistenceProtocol` is the abstract storage interface in SDK
- [ ] `UserDefaultsRideStatePersistence` is the thin iOS implementation in app
- [ ] `InMemoryRideStatePersistence` exists for SDK and coordinator tests
- [ ] `RideCoordinator` receives `RideStateRepository` via injection
- [ ] `AppState` creates and injects the repository
- [ ] `NostrKeypair.deriveFromSymmetricKey()` exists in SDK
- [ ] `PasskeyManager` uses SDK derivation, no inline crypto
- [ ] No remaining static `RideStatePersistence.load/save/clear()` calls in app
- [ ] All SDK tests pass
- [ ] Full Xcode build succeeds
- [ ] Existing coordinator tests pass with injected persistence
