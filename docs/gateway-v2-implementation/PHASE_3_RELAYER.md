# Phase 3: Relayer Updates

**Duration**: 4-6 weeks  
**Dependencies**: Phase 1 (Worker APIs), Phase 2 (V2 contracts)  
**Outcome**: Relayer polls worker APIs instead of listening to Gateway events

---

## Objective

Transform Relayer from passive event listener to active orchestrator.

---

## Architecture Change

### V1 Flow (Event-Driven)
```
User ──▶ Relayer ──▶ Gateway TX ──▶ Workers post on-chain ──▶ Gateway event ──▶ Relayer ──▶ User
                                         (bottleneck)
```

### V2 Flow (Polling)
```
User ──▶ Relayer ──▶ Gateway TX ──▶ Workers process ──▶ Relayer polls APIs ──▶ Relayer ──▶ User
                                    (no on-chain response)
```

---

## Component: Worker Polling Module

### Location
```
console/apps/relayer/src/gateway/worker_polling/
├── mod.rs
├── poller.rs           # Main polling logic with backoff
├── kms_client.rs       # KMS API client
├── coprocessor_client.rs
├── aggregator.rs       # Response aggregation
└── config.rs
```

### Polling Strategy
```
┌─────────────────────────────────────────────────────────────┐
│                    POLLING STATE MACHINE                     │
│                                                              │
│  ┌─────────┐    poll    ┌─────────┐   threshold   ┌──────┐ │
│  │ WAITING │──────────▶│ POLLING │──────────────▶│ DONE │ │
│  └─────────┘            └────┬────┘               └──────┘ │
│       │                      │                              │
│       │                      │ not ready                    │
│       │                      ▼                              │
│       │              ┌──────────────┐                       │
│       │              │ BACKOFF      │                       │
│       │              │ delay *= 1.5 │                       │
│       │              │ + jitter     │                       │
│       │              └──────┬───────┘                       │
│       │                     │                               │
│       │                     ▼                               │
│       │              timeout exceeded?                      │
│       │              ┌─────┴─────┐                         │
│       │              │           │                         │
│       │              ▼           ▼                         │
│       │           ┌──────┐  ┌─────────┐                   │
│       │           │FAILED│  │ retry   │───────────────────│
│       │           └──────┘  └─────────┘                   │
└───────┴─────────────────────────────────────────────────────┘
```

### Configuration
| Parameter | Default | Description |
|-----------|---------|-------------|
| `initial_delay_ms` | 100 | First poll delay |
| `max_delay_ms` | 5000 | Backoff cap |
| `backoff_factor` | 1.5 | Delay multiplier |
| `timeout_secs` | 60 | Max wait time |
| `jitter_percent` | 20 | Random jitter |

### Invariants
- Poll ALL workers in parallel (don't wait sequentially)
- Stop polling when threshold reached
- Jitter prevents thundering herd
- Timeout is hard limit (return error, don't hang)

---

## Component: Response Aggregator

### Purpose
Collect responses from multiple workers, determine when threshold is reached.

### Aggregation Logic
```
Results from N workers
         │
         ▼
┌────────────────────────┐
│ Count by status:       │
│ • ready: R             │
│ • pending: P           │
│ • rejected: X          │
│ • error: E             │
└──────────┬─────────────┘
           │
           ▼
    ┌──────────────┐
    │ R >= threshold│──── YES ──▶ COMPLETE (return shares)
    └──────┬───────┘
           │ NO
           ▼
    ┌──────────────┐
    │ X > 0        │──── YES ──▶ REJECTED (return reason)
    └──────┬───────┘
           │ NO
           ▼
      PENDING (continue polling)
```

### Invariants
- Same signer cannot contribute twice (dedupe by address)
- All ready shares must have valid signatures (basic check)
- Rejection from ANY worker propagates (fail fast)

---

## Component: Input Verification Handler V2

### Location
```
console/apps/relayer/src/gateway/input_handlers.rs
```

### V2 Flow
```
┌──────────────────────────────────────────────────────────────────────┐
│                     INPUT VERIFICATION V2 FLOW                        │
│                                                                       │
│  1. Compute commitment = keccak256(payload)                          │
│                                                                       │
│  2. Register on Gateway (commitment only)                            │
│     └──▶ InputVerificationRegistry.registerInputVerification()       │
│     └──▶ Get requestId                                               │
│                                                                       │
│  3. Broadcast payload to ALL coprocessors                            │
│     └──▶ POST /v1/verify-input to each                               │
│     └──▶ Coprocessors verify: hash(payload) == on-chain commitment   │
│                                                                       │
│  4. Poll coprocessors for verification results                       │
│     └──▶ Until threshold reached or timeout                          │
│                                                                       │
│  5. Return aggregated {handles, signatures} to user                  │
│     └──▶ User uses handles on Host Chain                             │
│     └──▶ InputVerifier validates signatures                          │
└──────────────────────────────────────────────────────────────────────┘
```

### Invariants
- Commitment computed BEFORE any network calls
- Gateway TX BEFORE coprocessor broadcast (ensures on-chain commitment exists)
- All coprocessors receive same payload (consistency)
- Polling timeout returns error (don't return partial results)

---

## Component: Decryption Handlers V2

### Location
```
console/apps/relayer/src/gateway/user_decrypt_handler.rs
console/apps/relayer/src/gateway/public_decrypt_handler.rs
```

### V2 Flow
```
┌──────────────────────────────────────────────────────────────────────┐
│                      DECRYPTION V2 FLOW                               │
│                                                                       │
│  1. Register on Gateway (same as V1)                                 │
│     └──▶ DecryptionRegistry.requestUserDecryption()                  │
│     └──▶ Event emitted, workers observe                              │
│                                                                       │
│  2. Poll KMS nodes for shares                                        │
│     └──▶ GET /v1/share/{requestId} to each                           │
│     └──▶ Until threshold reached or timeout                          │
│                                                                       │
│  3. Return aggregated shares to user                                 │
│     └──▶ SDK verifies signatures (user decrypt)                      │
│     └──▶ Or Host Chain verifies (public decrypt)                     │
└──────────────────────────────────────────────────────────────────────┘
```

### Difference from V1
| Aspect | V1 | V2 |
|--------|----|----|
| Request | Gateway TX | Gateway TX (same) |
| Response | Listen to Gateway events | Poll KMS APIs |
| Aggregation | On-chain (Gateway) | Off-chain (Relayer) |
| Verification | Gateway contract | SDK or Host Chain |

---

## Feature Flag

### Configuration
```toml
[v2]
enabled = true  # Feature flag for V2 flows

[v2.polling]
initial_delay_ms = 100
max_delay_ms = 5000
timeout_secs = 60
```

### Behavior
- `v2.enabled = false`: Use V1 contracts and event listening
- `v2.enabled = true`: Use V2 contracts and API polling
- Can run both simultaneously for comparison

---

## Database Changes

### New Tables
| Table | Purpose |
|-------|---------|
| `v2_input_verifications` | Track V2 input verification requests |
| `v2_decryptions` | Track V2 decryption requests |
| `v2_poll_state` | Track polling progress (for observability) |

### Schema
- Same columns as V1 equivalents
- Add `gateway_tx_hash` for linking
- Add `status` enum: pending, polling, complete, failed

---

## Testing Strategy

### Unit Tests
| Test | Assertion |
|------|-----------|
| Backoff calculation | Delay increases correctly with jitter |
| Threshold aggregation | Complete when threshold reached |
| Timeout handling | Error returned, not hung |
| Commitment computation | Deterministic, matches contract |

### Integration Tests
| Test | Assertion |
|------|-----------|
| V2 input verification | End-to-end flow works |
| V2 decryption | End-to-end flow works |
| Partial worker failure | Threshold still reached |
| V1 + V2 parallel | Both flows work |

### Load Tests
- 100 concurrent requests
- Measure: latency, success rate, worker load

---

## Deliverables

| Component | Location | Status |
|-----------|----------|--------|
| Worker Polling Module | `src/gateway/worker_polling/` | ⏳ |
| Updated Input Handler | `src/gateway/input_handlers.rs` | ⏳ |
| Updated Decrypt Handlers | `src/gateway/*_decrypt_handler.rs` | ⏳ |
| V2 Config | `src/config/settings.rs` | ⏳ |
| DB Migrations | `relayer-migrate/migrations/` | ⏳ |

---

## Acceptance Criteria

- [ ] V2 input verification uses commitment-only Gateway TX
- [ ] V2 decryption polls KMS APIs instead of listening to events
- [ ] Exponential backoff with jitter implemented
- [ ] Threshold aggregation works correctly
- [ ] Feature flag controls V1/V2 mode
- [ ] V1 flows unchanged
- [ ] Metrics for polling latency and success rate
- [ ] Integration tests pass
