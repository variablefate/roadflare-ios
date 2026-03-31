# SDK/App Boundary Checklist

This checklist defines the intended ownership split between `RidestrSDK` and `RoadFlare` for ride runtime behavior.

## SDK Owns

- Ride state-machine invariants and legal stage transitions.
- Offer publication validity, including rejecting duplicate or non-idle offer sends.
- Confirmation recovery and subscription reconciliation after restore/reconnect.
- Driver-state, cancellation, and PIN-processing protocol behavior.
- Terminal outcomes for timeout, cancellation, completion, and brute-force PIN enforcement.

## App Owns

- Mapping SDK session state into UI state, navigation, chat/location coordinators, and persisted view-model data.
- User-facing copy for terminal outcomes surfaced by the SDK.
- Payment preference selection and fare/pickup/destination presentation.
- History recording and non-protocol UX cleanup once the SDK reports terminal outcomes.

## Must Stay True

- A public SDK client cannot publish a ride offer unless the session is idle.
- A final bad PIN attempt must end the ride even if rider-state publication fails.
- Restore/reconnect must emit the same stage transitions the live flow would emit.
- Runtime timeout configuration and persisted restore windows must stay aligned.
- App cleanup must not erase terminal semantics the SDK already computed.

## Regression Coverage

- `RiderRideSessionTests.sendOfferFromNonIdleDoesNotPublishGhostOffer`
- `RiderRideSessionTests.bruteForcePinCancelsEvenWhenRiderStatePublishFails`
- `RiderRideSessionTests.restoreSubscriptionsRecoveryFiresStageChangeAndStartsConfirmedSubscriptions`
- `RideCoordinatorTests.restoreRideStateRespectsConfiguredTimeoutWindow`
- `RideCoordinatorTests.sessionDidReachTerminalCancelledByDriverSurfacesMessage`
- `RideCoordinatorTests.sessionDidReachTerminalExpiredSetsTimeoutMessage`
- `RideCoordinatorTests.sessionDidReachTerminalBruteForcePinSetsMessage`
