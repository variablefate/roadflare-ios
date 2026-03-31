import Foundation

/// Manages the full rider ride lifecycle: subscriptions, timeouts, retries,
/// PIN deduplication, and state machine transitions.
///
/// The app creates a session, calls `sendOffer()`, observes state, and handles
/// terminal outcomes via the delegate. The session owns all protocol wiring;
/// the app owns UI data, chat/location coordinators, and persistence mapping.
@Observable
@MainActor
public final class RiderRideSession {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public struct StageTimeouts: Sendable, Equatable {
            public let waitingForAcceptance: Duration
            public let driverAccepted: Duration

            public init(waitingForAcceptance: Duration, driverAccepted: Duration) {
                self.waitingForAcceptance = waitingForAcceptance
                self.driverAccepted = driverAccepted
            }
        }

        public let stageTimeouts: StageTimeouts
        public let confirmationRetryDelays: [Duration]
        public let maxPinActionSetSize: Int

        public init(
            stageTimeouts: StageTimeouts,
            confirmationRetryDelays: [Duration],
            maxPinActionSetSize: Int
        ) {
            self.stageTimeouts = stageTimeouts
            self.confirmationRetryDelays = confirmationRetryDelays
            self.maxPinActionSetSize = maxPinActionSetSize
        }

        public static let `default` = Configuration(
            stageTimeouts: StageTimeouts(
                waitingForAcceptance: .seconds(120),
                driverAccepted: .seconds(30)
            ),
            confirmationRetryDelays: [.zero, .seconds(1), .seconds(3)],
            maxPinActionSetSize: 10
        )
    }

    // MARK: - Observable state (forwarded from state machine)

    public var stage: RiderStage { stateMachine.stage }
    public var pin: String? { stateMachine.pin }
    public var confirmationEventId: ConfirmationEventID? { stateMachine.confirmationEventId }
    public var offerEventId: EventID? { stateMachine.offerEventId }
    public var acceptanceEventId: EventID? { stateMachine.acceptanceEventId }
    public var driverPubkey: PublicKeyHex? { stateMachine.driverPubkey }
    public var pinVerified: Bool { stateMachine.pinVerified }
    public var pinAttempts: Int { stateMachine.pinAttempts }
    public var paymentMethod: String? { stateMachine.paymentMethod }
    public var fiatPaymentMethods: [String] { stateMachine.fiatPaymentMethods }
    public var precisePickupShared: Bool { stateMachine.precisePickupShared }
    public var preciseDestinationShared: Bool { stateMachine.preciseDestinationShared }
    public var riderStateHistory: [RiderRideAction] { stateMachine.riderStateHistory }

    // MARK: - Safe cursor

    // Diverges from the state machine's cursor intentionally. The state machine
    // always advances its cursor immediately when a driver state event is processed.
    // This session-owned cursor only advances once ALL PIN actions from that event
    // have been fully processed. This ensures that if the app is killed during PIN
    // processing, the persisted cursor doesn't skip past unprocessed PIN actions,
    // so on relaunch the driver state event is re-fetched and PINs re-processed.
    public private(set) var lastDriverStatus: String?
    public private(set) var lastDriverStateTimestamp: Int = 0
    public private(set) var lastDriverActionCount: Int = 0

    // MARK: - Session-owned state

    public private(set) var lastError: Error?
    public private(set) var precisePickup: Location?
    public private(set) var preciseDestination: Location?
    public var processedPinActionKeys: Set<String> { pinDeduplicator.processedKeys }

    // MARK: - Delegate

    public weak var delegate: (any RiderRideSessionDelegate)?

    // MARK: - Internal components

    let stateMachine: RideStateMachine
    let domainService: RiderRideDomainService
    let relayManager: any RelayManagerProtocol
    let configuration: Configuration
    var pinDeduplicator: PinActionDeduplicator

    // MARK: - Init

    public init(
        relayManager: any RelayManagerProtocol,
        keypair: NostrKeypair,
        configuration: Configuration = .default
    ) {
        self.stateMachine = RideStateMachine(riderPubkey: keypair.publicKeyHex)
        self.domainService = RiderRideDomainService(relayManager: relayManager, keypair: keypair)
        self.relayManager = relayManager
        self.configuration = configuration
        self.pinDeduplicator = PinActionDeduplicator(maxCombinedSize: configuration.maxPinActionSetSize)
    }

    // MARK: - Restore

    /// Restore session from persisted state after app relaunch.
    public func restore(
        stage: RiderStage,
        offerEventId: String?,
        acceptanceEventId: String?,
        confirmationEventId: String?,
        driverPubkey: String?,
        pin: String?,
        pinAttempts: Int = 0,
        pinVerified: Bool,
        paymentMethod: String?,
        fiatPaymentMethods: [String],
        precisePickupShared: Bool = false,
        preciseDestinationShared: Bool = false,
        lastDriverStatus: String? = nil,
        lastDriverStateTimestamp: Int = 0,
        lastDriverActionCount: Int = 0,
        riderStateHistory: [RiderRideAction] = [],
        processedPinActionKeys: Set<String> = [],
        precisePickup: Location? = nil,
        preciseDestination: Location? = nil,
        savedAt: Int = 0
    ) {
        stateMachine.restore(
            stage: stage,
            offerEventId: offerEventId,
            acceptanceEventId: acceptanceEventId,
            confirmationEventId: confirmationEventId,
            driverPubkey: driverPubkey,
            pin: pin,
            pinAttempts: pinAttempts,
            pinVerified: pinVerified,
            paymentMethod: paymentMethod,
            fiatPaymentMethods: fiatPaymentMethods,
            precisePickupShared: precisePickupShared,
            preciseDestinationShared: preciseDestinationShared,
            lastDriverStatus: lastDriverStatus,
            lastDriverStateTimestamp: lastDriverStateTimestamp,
            lastDriverActionCount: lastDriverActionCount,
            riderStateHistory: riderStateHistory
        )
        // If the state machine rejected the restore (e.g., nil driverPubkey for
        // a non-idle stage), it reset to idle. Clear session-owned state to match.
        guard stateMachine.stage == stage else {
            reset()
            return
        }
        self.pinDeduplicator = PinActionDeduplicator(
            processedKeys: processedPinActionKeys,
            maxCombinedSize: configuration.maxPinActionSetSize
        )
        self.lastDriverStatus = lastDriverStatus
        self.lastDriverStateTimestamp = lastDriverStateTimestamp
        self.lastDriverActionCount = lastDriverActionCount
        self.precisePickup = precisePickup
        self.preciseDestination = preciseDestination
        self.lastError = nil
        self.restoredSavedAt = savedAt
    }

    // Stored for timeout math during restoreSubscriptions().
    var restoredSavedAt: Int = 0

    // MARK: - Reset

    public func reset() {
        cancelStageTimeout()
        stateMachine.reset()
        clearSessionOwnedState()
    }

    /// Clears all session-owned state (PIN dedup, cursor, locations, error, savedAt).
    /// Does NOT reset the state machine — caller is responsible for that.
    private func clearSessionOwnedState() {
        pinDeduplicator.reset()
        lastDriverStatus = nil
        lastDriverStateTimestamp = 0
        lastDriverActionCount = 0
        precisePickup = nil
        preciseDestination = nil
        lastError = nil
        restoredSavedAt = 0
    }

    // MARK: - Subscription Management

    private struct ManagedSubscription {
        let subscriptionId: SubscriptionID
        let generation: UUID
        let task: Task<Void, Never>
    }

    private var activeSubscriptions: [RiderRideDomainService.LiveSubscription: ManagedSubscription] = [:]
    private var confirmationPublishInFlight = false

    /// Diff desired subscriptions against active ones. Stop extras, start missing.
    private func reconcileSubscriptions() async {
        let plan = domainService.runtimePlan(for: stateMachine)
        let desired = Set(plan.subscriptions)
        let active = Set(activeSubscriptions.keys)

        // Stop subscriptions no longer needed
        for sub in active.subtracting(desired) {
            await stopSubscription(sub)
        }
        // Start subscriptions not yet active
        for sub in desired.subtracting(active) {
            startSubscription(sub)
        }
        // Execute pending action if present
        if let action = plan.pendingAction {
            await executePendingAction(action)
        }
    }

    private func startSubscription(_ sub: RiderRideDomainService.LiveSubscription) {
        let filter = domainService.filter(for: sub)
        let subId = subscriptionId(for: sub)
        let generation = UUID()

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                // Only remove if the entry still belongs to THIS task generation.
                // Logical subscription IDs are stable across restarts.
                if self.activeSubscriptions[sub]?.generation == generation {
                    self.activeSubscriptions.removeValue(forKey: sub)
                }
            }
            guard !Task.isCancelled,
                  self.activeSubscriptions[sub]?.generation == generation else { return }
            do {
                let stream = try await self.relayManager.subscribe(filter: filter, id: subId)
                guard !Task.isCancelled,
                      self.activeSubscriptions[sub]?.generation == generation else { return }
                for await event in stream {
                    guard !Task.isCancelled,
                          self.activeSubscriptions[sub]?.generation == generation else { break }
                    await self.routeEvent(event, for: sub)
                }
            } catch {
                guard self.activeSubscriptions[sub]?.generation == generation else { return }
                self.delegate?.sessionDidEncounterError(error)
            }
        }
        activeSubscriptions[sub] = ManagedSubscription(
            subscriptionId: subId,
            generation: generation,
            task: task
        )
    }

    private func stopSubscription(_ sub: RiderRideDomainService.LiveSubscription) async {
        guard let managed = activeSubscriptions.removeValue(forKey: sub) else { return }
        managed.task.cancel()
        await relayManager.unsubscribe(managed.subscriptionId)
    }

    /// Tear down all active subscriptions.
    public func teardownAll() async {
        for sub in Array(activeSubscriptions.keys) {
            await stopSubscription(sub)
        }
    }

    private func subscriptionId(for sub: RiderRideDomainService.LiveSubscription) -> SubscriptionID {
        switch sub {
        case .acceptance(let offerEventId, _):
            return SubscriptionID("acceptance-\(offerEventId)")
        case .driverState(let confirmationEventId, _):
            return SubscriptionID("driver-state-\(confirmationEventId)")
        case .cancellation(let confirmationEventId, _):
            return SubscriptionID("cancel-\(confirmationEventId)")
        }
    }

    private func routeEvent(_ event: NostrEvent, for sub: RiderRideDomainService.LiveSubscription) async {
        switch sub {
        case .acceptance:
            await handleAcceptanceEvent(event)
        case .driverState(let confirmationEventId, _):
            await handleDriverStateEvent(event, confirmationEventId: confirmationEventId)
        case .cancellation(let confirmationEventId, _):
            await handleCancellationEvent(event, confirmationEventId: confirmationEventId)
        }
    }

    private func executePendingAction(_ action: RiderRideDomainService.PendingAction) async {
        switch action {
        case .recoverOrPublishConfirmation(let acceptanceEventId, let driverPubkey):
            let stageBefore = stateMachine.stage
            if let _ = try? await domainService.recoverExistingConfirmation(
                driverPubkey: driverPubkey,
                acceptanceEventId: acceptanceEventId,
                stateMachine: stateMachine
            ) {
                // Recovery succeeded — state machine advanced, reconcile for new subs.
                emitStageChangeIfNeeded(from: stageBefore)
                await reconcileSubscriptions()
                delegate?.sessionShouldPersist()
            } else {
                await ensureConfirmationPublished(driverPubkey: driverPubkey, acceptanceEventId: acceptanceEventId)
            }
        }
    }

    // MARK: - Public Ride Actions

    /// Start a new ride by publishing an offer to the specified driver.
    public func sendOffer(
        driverPubkey: PublicKeyHex,
        content: RideOfferContent,
        precisePickup: Location,
        preciseDestination: Location
    ) async {
        guard stateMachine.stage == .idle else {
            let error = RidestrError.ride(
                .stateMachineViolation(
                    from: stateMachine.stage.rawValue,
                    to: RiderStage.waitingForAcceptance.rawValue
                )
            )
            lastError = error
            delegate?.sessionDidEncounterError(error)
            return
        }

        self.precisePickup = precisePickup
        self.preciseDestination = preciseDestination

        let stageBefore = stateMachine.stage
        do {
            try await domainService.publishRideOffer(
                driverPubkey: driverPubkey,
                content: content,
                stateMachine: stateMachine
            )
            emitStageChangeIfNeeded(from: stageBefore)
            scheduleStageTimeout()
            await reconcileSubscriptions()
            delegate?.sessionShouldPersist()
        } catch {
            lastError = error
            delegate?.sessionDidEncounterError(error)
        }
    }

    /// Cancel the current ride. Best-effort publish of cancellation/deletion event.
    /// Pass `terminalOverride` to emit a different terminal outcome (e.g., `.bruteForcePin`).
    public func cancelRide(reason: String? = nil, terminalOverride: RideSessionTerminalOutcome? = nil) async {
        guard canFinalizeCancellation(terminalOverride: terminalOverride) else { return }
        let stageBefore = stateMachine.stage
        _ = try? await domainService.publishTermination(for: stateMachine, reason: reason)
        await teardownAll()
        stateMachine.reset()
        clearSessionOwnedState()
        emitStageChangeIfNeeded(from: stageBefore)
        delegate?.sessionDidReachTerminal(terminalOverride ?? .cancelledByRider(reason: reason))
        delegate?.sessionShouldPersist()
    }

    private func canFinalizeCancellation(terminalOverride: RideSessionTerminalOutcome?) -> Bool {
        if stateMachine.stage.canCancel {
            return true
        }
        guard case .bruteForcePin? = terminalOverride else {
            return false
        }
        return stateMachine.stage == .idle &&
            stateMachine.confirmationEventId != nil &&
            stateMachine.driverPubkey != nil
    }

    /// Dismiss a completed ride. Resets session to idle.
    /// Fires `sessionDidChangeStage(from: .completed, to: .idle)`.
    /// Does NOT fire `sessionDidReachTerminal` — terminal callbacks are for ride outcomes.
    public func dismissCompletedRide() async {
        guard stateMachine.stage == .completed else { return }
        await teardownAll()
        let stageBefore = stateMachine.stage
        stateMachine.reset()
        clearSessionOwnedState()
        emitStageChangeIfNeeded(from: stageBefore)
    }

    /// Manually submit an encrypted PIN (for cases where PIN arrives outside driver state).
    public func respondToPin(pinEncrypted: String) async {
        guard let driverPubkey = stateMachine.driverPubkey,
              let confirmationEventId = stateMachine.confirmationEventId else { return }
        let syntheticAction = DriverRideAction(
            type: "pin_submit",
            at: Int(Date.now.timeIntervalSince1970),
            status: nil,
            approxLocation: nil,
            finalFare: nil,
            invoice: nil,
            pinEncrypted: pinEncrypted
        )
        await processPinAction(syntheticAction, driverPubkey: driverPubkey, confirmationEventId: confirmationEventId)
    }

    /// Restore relay subscriptions for the current stage after app relaunch or reconnect.
    /// May fire `sessionDidChangeStage` if it advances state (e.g., confirmation recovery).
    /// Does NOT synthesize fake transitions.
    public func restoreSubscriptions() async {
        await teardownAll()
        await reconcileSubscriptions()
        // Schedule timeout for pre-confirmation stages, using savedAt from restore
        if stateMachine.stage == .waitingForAcceptance || stateMachine.stage == .driverAccepted {
            scheduleStageTimeout(savedAt: restoredSavedAt > 0 ? restoredSavedAt : nil)
        }
    }

    // MARK: - Private Event Handlers

    private func handleAcceptanceEvent(_ event: NostrEvent) async {
        guard let offerEventId = stateMachine.offerEventId else { return }
        let stageBefore = stateMachine.stage
        do {
            let resolution = try domainService.receiveAcceptanceEvent(
                event,
                expectedOfferEventId: offerEventId,
                expectedDriverPubkey: stateMachine.driverPubkey,
                stateMachine: stateMachine
            )
            emitStageChangeIfNeeded(from: stageBefore)
            scheduleStageTimeout() // Reschedule for driverAccepted timeout
            if resolution.shouldPublishConfirmation,
               let driverPubkey = stateMachine.driverPubkey,
               let acceptanceEventId = stateMachine.acceptanceEventId {
                await ensureConfirmationPublished(driverPubkey: driverPubkey, acceptanceEventId: acceptanceEventId)
            }
            delegate?.sessionShouldPersist()
        } catch {
            // Invalid acceptance event — skip silently (same as current coordinator behavior)
        }
    }

    private func handleDriverStateEvent(_ event: NostrEvent, confirmationEventId: ConfirmationEventID) async {
        let stageBefore = stateMachine.stage
        do {
            let resolution = try domainService.receiveDriverStateEvent(
                event,
                confirmationEventId: confirmationEventId,
                expectedDriverPubkey: stateMachine.driverPubkey,
                stateMachine: stateMachine
            )
            guard case .processed(let update) = resolution else { return }
            let stageAfter = stateMachine.stage

            // Terminal: cancelled — state machine already at .idle
            if update.terminalOutcome == .cancelled {
                await teardownAll()
                clearSessionOwnedState()
                emitStageChangeIfNeeded(from: stageBefore)
                delegate?.sessionDidReachTerminal(.cancelledByDriver(reason: nil))
                delegate?.sessionShouldPersist()
                return
            }

            // Terminal: completed — tear down subs, keep .completed stage
            if update.terminalOutcome == .completed && stageBefore != .completed {
                await reconcileSubscriptions() // empty plan for .completed → tears down subs
                emitStageChangeIfNeeded(from: stageBefore)
                delegate?.sessionDidReachTerminal(.completed)
                delegate?.sessionShouldPersist()
                return
            }

            // Duplicate .completed event (already completed) — ignore
            if update.terminalOutcome == .completed && stageBefore == .completed {
                return
            }

            // Non-terminal: process PIN actions, advance cursor
            var allPinsProcessed = true
            for action in update.pinActions {
                guard action.pinEncrypted != nil,
                      let driverPubkey = stateMachine.driverPubkey else { continue }
                await processPinAction(action, driverPubkey: driverPubkey, confirmationEventId: confirmationEventId)
                if !pinDeduplicator.hasProcessed(action) {
                    allPinsProcessed = false
                }
            }

            // Advance safe cursor only when all PIN actions are processed
            if allPinsProcessed {
                lastDriverStatus = update.status
                lastDriverStateTimestamp = event.createdAt
                lastDriverActionCount = update.content.history.count
            }

            // Emit stage change for non-terminal transitions (enRoute, driverArrived, inProgress)
            if stageBefore != stageAfter {
                emitStageChangeIfNeeded(from: stageBefore)
            }

            delegate?.sessionShouldPersist()
        } catch {
            // Invalid driver state event — skip
        }
    }

    private func handleCancellationEvent(_ event: NostrEvent, confirmationEventId: ConfirmationEventID) async {
        let stageBefore = stateMachine.stage
        do {
            let resolution = try domainService.receiveCancellationEvent(
                event,
                confirmationEventId: confirmationEventId,
                expectedDriverPubkey: stateMachine.driverPubkey,
                stateMachine: stateMachine
            )
            guard case .processed(let update) = resolution else { return }

            // State machine already transitioned to .idle via receiveCancellationEvent
            await teardownAll()
            clearSessionOwnedState()
            emitStageChangeIfNeeded(from: stageBefore)
            delegate?.sessionDidReachTerminal(.cancelledByDriver(reason: update.content.reason))
            delegate?.sessionShouldPersist()
        } catch {
            // Invalid cancellation event — skip
        }
    }

    // MARK: - Confirmation Flow

    private func ensureConfirmationPublished(driverPubkey: PublicKeyHex, acceptanceEventId: EventID) async {
        guard !confirmationPublishInFlight else { return }
        confirmationPublishInFlight = true
        defer { confirmationPublishInFlight = false }

        guard let pickup = precisePickup else {
            lastError = RidestrError.ride(.invalidEvent("Missing precisePickup for confirmation"))
            delegate?.sessionDidEncounterError(lastError!)
            return
        }

        let stageBefore = stateMachine.stage
        do {
            try await domainService.publishConfirmation(
                driverPubkey: driverPubkey,
                acceptanceEventId: acceptanceEventId,
                precisePickup: pickup,
                stateMachine: stateMachine
            )
            emitStageChangeIfNeeded(from: stageBefore)
            await reconcileSubscriptions()
            delegate?.sessionShouldPersist()
        } catch {
            await retryConfirmation(driverPubkey: driverPubkey, acceptanceEventId: acceptanceEventId)
        }
    }

    private func retryConfirmation(driverPubkey: PublicKeyHex, acceptanceEventId: EventID) async {
        guard let pickup = precisePickup else { return }

        for (index, delay) in configuration.confirmationRetryDelays.enumerated() {
            // Pre-sleep guard
            guard stateMachine.stage == .driverAccepted,
                  stateMachine.confirmationEventId == nil,
                  stateMachine.acceptanceEventId == acceptanceEventId,
                  stateMachine.driverPubkey == driverPubkey else { return }

            if index > 0 {
                try? await Task.sleep(for: delay)
            }

            // Post-sleep guard (state may have changed during sleep)
            guard stateMachine.stage == .driverAccepted,
                  stateMachine.confirmationEventId == nil,
                  stateMachine.acceptanceEventId == acceptanceEventId,
                  stateMachine.driverPubkey == driverPubkey else { return }

            let stageBefore = stateMachine.stage
            do {
                try await domainService.publishConfirmation(
                    driverPubkey: driverPubkey,
                    acceptanceEventId: acceptanceEventId,
                    precisePickup: pickup,
                    stateMachine: stateMachine
                )
                emitStageChangeIfNeeded(from: stageBefore)
                await reconcileSubscriptions()
                delegate?.sessionShouldPersist()
                return // Success
            } catch {
                // Continue to next retry
            }
        }

        // All retries failed
        lastError = RidestrError.ride(.invalidEvent("Confirmation publish failed after all retries"))
        delegate?.sessionDidEncounterError(lastError!)
    }

    // MARK: - PIN Processing

    private func canProcessPinSubmission(driverPubkey: PublicKeyHex, confirmationEventId: ConfirmationEventID) -> Bool {
        stateMachine.driverPubkey == driverPubkey &&
            stateMachine.confirmationEventId == confirmationEventId &&
            stateMachine.stage == .driverArrived &&
            !stateMachine.pinVerified &&
            !stateMachine.preciseDestinationShared
    }

    private func processPinAction(
        _ action: DriverRideAction,
        driverPubkey: PublicKeyHex,
        confirmationEventId: ConfirmationEventID
    ) async {
        guard canProcessPinSubmission(driverPubkey: driverPubkey, confirmationEventId: confirmationEventId) else { return }
        guard pinDeduplicator.beginProcessing(action) else { return }

        var processedSuccessfully = false
        defer { pinDeduplicator.finishProcessing(action, processed: processedSuccessfully) }

        let plan: RiderRideDomainService.PinVerificationPlan
        do {
            plan = try domainService.preparePinVerificationResponse(
                pinEncrypted: action.pinEncrypted ?? "",
                driverPubkey: driverPubkey,
                confirmationEventId: confirmationEventId,
                destination: preciseDestination,
                stateMachine: stateMachine
            )
        } catch {
            lastError = error
            delegate?.sessionDidEncounterError(error)
            return
        }

        let stageBefore = stateMachine.stage
        do {
            try await domainService.publishPinVerificationResponse(
                plan,
                stateMachine: stateMachine
            )
            emitStageChangeIfNeeded(from: stageBefore)
            processedSuccessfully = true

            if plan.shouldCancelForBruteForce {
                await cancelRide(reason: "PIN verification failed", terminalOverride: .bruteForcePin)
                return // cancelRide already persisted
            }

            delegate?.sessionShouldPersist()
        } catch {
            lastError = error
            delegate?.sessionDidEncounterError(error)
            if plan.shouldCancelForBruteForce {
                await cancelRide(reason: "PIN verification failed", terminalOverride: .bruteForcePin)
            }
        }
    }

    // MARK: - Stage Change Detection

    /// Compares captured stageBefore with current stage. If different, cancels any stage timeout
    /// and fires delegate callback. Used by most methods. Terminal paths (completed, cancelled)
    /// use manual ordering for deterministic teardown-before-callback.
    private func emitStageChangeIfNeeded(from stageBefore: RiderStage) {
        let stageAfter = stateMachine.stage
        guard stageBefore != stageAfter else { return }
        cancelStageTimeout()
        delegate?.sessionDidChangeStage(from: stageBefore, to: stageAfter)
    }

    // MARK: - Stage Timeout Scheduling

    private var stageTimeoutTask: Task<Void, Never>?

    /// Schedule a timeout for the current pre-confirmation stage.
    /// `savedAt` is used during restore to account for already-elapsed time.
    func scheduleStageTimeout(savedAt: Int? = nil) {
        cancelStageTimeout()

        let timeout: Duration
        switch stateMachine.stage {
        case .waitingForAcceptance:
            timeout = configuration.stageTimeouts.waitingForAcceptance
        case .driverAccepted:
            timeout = configuration.stageTimeouts.driverAccepted
        default:
            return // No timeout for post-confirmation stages
        }

        let expectedStage = stateMachine.stage

        // Calculate remaining time, accounting for elapsed time since savedAt
        var remaining = timeout
        if let savedAt, savedAt > 0 {
            let elapsed = Int(Date.now.timeIntervalSince1970) - savedAt
            let elapsedDuration = Duration.seconds(max(0, elapsed))
            remaining = timeout - elapsedDuration
            if remaining <= .zero {
                // Already expired — fire immediately
                Task { await handleStageTimeout(expectedStage: expectedStage) }
                return
            }
        }

        stageTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled else { return }
            await self?.handleStageTimeout(expectedStage: expectedStage)
        }
    }

    private func cancelStageTimeout() {
        stageTimeoutTask?.cancel()
        stageTimeoutTask = nil
    }

    private func handleStageTimeout(expectedStage: RiderStage) async {
        guard stateMachine.stage == expectedStage else { return }

        let stageBefore = stateMachine.stage
        _ = try? await domainService.publishTermination(for: stateMachine, reason: "stage timeout")
        await teardownAll()
        stateMachine.reset()
        clearSessionOwnedState()
        emitStageChangeIfNeeded(from: stageBefore)
        delegate?.sessionDidReachTerminal(.expired(stage: expectedStage))
        delegate?.sessionShouldPersist()
    }
}
