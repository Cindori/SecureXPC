# Cindori transport maintenance

This fork starts at upstream SecureXPC 0.8.0 (`d6e439e2b805de8be9b584fff97cf2f6a839a656`). The MIT license and upstream attribution remain unchanged.

The client now offers terminal, idempotent `invalidate()`. Owners must call it when discarding a connected transport. It closes established and initializing connections, rejects future sends with `connectionInvalid`, and fails pending sequences once. In-flight replies already executing may complete. The strong event-handler lifetime is retained: making it weak caused callback-only sequences to lose replies when callers released the client after sending.

Connection ownership is synchronized. Old errors cannot clear a replacement connection, and a handshake removed during interruption cannot re-cache itself. Sequential handlers release on disconnect, invalidation, remote termination or local payload decoding failure; late replies after removal are ignored. Server identity validation, default trust policy, route authorization and wire contracts are unchanged.

The package test target excludes the launch-agent executable's `main.swift`, which otherwise prevents SwiftPM from compiling the test library. The helper and launch-agent integration tests remain available; the focused commands below do not run registration tests.

```sh
python3 Scripts/Tests/test-client-lifetime.py --output /absolute/owned/output
swift test --filter 'SequentialResultTests|RoundTripIntegrationTest|ServerIdentityTests|ErrorIntegrationTests'
```

The native runner checks replacement, complete callback-only replies, held requests, trust rejection, terminal uniqueness, malformed payloads and races. Race builds inject hooks into an owned copy only; production source has no test hook. No service is installed. This patch does not add transport backpressure, cancel native server work, or automatically invalidate owners that never call the API. It does not establish weeks of elapsed stability.

Sensei should pin an immutable reviewed revision and invalidate old clients outside its own lock after swapping. Late errors must be matched to their original transport to prevent replacement loops. Review is required before integration; this document is not evidence of approval.
