# Phase 6: V1 Deprecation

**Duration**: 2-4 weeks  
**Dependencies**: Phase 5 (successful dual-run)  
**Outcome**: V1 deprecated, V2 is sole path

---

## Objective

Safely deprecate V1 components after V2 is validated.

---

## Deprecation Order

```
Week 1: Stop V1 response transactions
        │
        ▼
Week 2: Deprecate V1 Gateway contracts
        │
        ▼
Week 3: Remove CiphertextCommits dependency
        │
        ▼
Week 4: Remove MultichainACL dependency
        │
        ▼
Future: Archive V1 code (optional)
```

---

## Step 1: Stop V1 Response Transactions

### Components Affected
- KMS tx-sender (stops posting to Gateway)
- Coprocessor transaction-sender (stops posting to Gateway)

### Change
```
# KMS tx-sender config
[gateway]
post_responses = false  # NEW: disable on-chain responses
```

### Verification
- V2 API responses still work
- No new response transactions on Gateway
- Relayer uses V2 exclusively

### Rollback
- Set `post_responses = true`
- Workers resume on-chain posting

---

## Step 2: Deprecate V1 Gateway Contracts

### Contracts
- `Decryption.sol` → read-only (historical queries)
- `InputVerification.sol` → read-only

### Actions
1. Pause V1 contracts (no new requests)
2. Keep read functions for historical data
3. Update documentation
4. Remove V1 ABIs from Relayer

### Verification
- New requests go to V2 contracts only
- Historical queries still work
- No user impact (Relayer handles routing)

---

## Step 3: Remove CiphertextCommits Dependency

### Current State
- KMS fetches ciphertext from CiphertextCommits (V1)
- KMS can also fetch from Coprocessor API (V2)

### Change
- Remove CiphertextCommits query from KMS
- Coprocessor API is sole source

### Verification
- KMS successfully fetches all ciphertexts from Coprocessor API
- No queries to CiphertextCommits contract

### Contract Status
- `CiphertextCommits.sol` → frozen (no new writes)
- Keep for historical reference (or archive)

---

## Step 4: Remove MultichainACL Dependency

### Current State
- KMS queries MultichainACL on Gateway (V1)
- KMS can also query Host Chain ACL directly (V2)

### Change
- Remove MultichainACL query from KMS
- Host Chain ACL is sole source

### Verification
- KMS successfully validates ACL via Host Chain
- No queries to MultichainACL contract

### Contract Status
- `MultichainACL.sol` → frozen
- Keep for historical reference (or archive)

---

## Communication Plan

### Timeline
| Date | Action |
|------|--------|
| T-4 weeks | Announce deprecation timeline |
| T-2 weeks | Final reminder |
| T-0 | V1 response transactions stopped |
| T+1 week | V1 contracts paused |
| T+2 weeks | CiphertextCommits removed |
| T+3 weeks | MultichainACL removed |

### Channels
- GitHub release notes
- Documentation update
- Discord announcement
- Email to known integrators

### Message Template
```
Gateway V2 Migration Complete

V1 components are now deprecated:
- On-chain response transactions stopped
- Use V2 API endpoints for all operations
- Historical data remains queryable

No action required if using official SDK/Relayer.

Questions? Contact support@zama.ai
```

---

## Monitoring During Deprecation

### Metrics
```
# Should drop to zero
gateway_v1_response_transactions_total
gateway_v1_request_count

# Should be stable/increasing
gateway_v2_api_requests_total
gateway_v2_success_rate
```

### Alerts
| Alert | Condition | Action |
|-------|-----------|--------|
| V1 traffic detected | Any V1 request after deprecation | Investigate source |
| V2 error spike | Error rate > 1% | Pause deprecation |

---

## Cleanup Tasks

### Code Removal (Optional, Future)
| Item | Action | Priority |
|------|--------|----------|
| V1 response handlers in workers | Remove | Low |
| V1 event listeners in Relayer | Remove | Low |
| V1 contract ABIs | Archive | Low |
| V1 tests | Archive | Low |

### Documentation Updates
| Doc | Change |
|-----|--------|
| GATEWAY_V2_DESIGN.md | Mark as current |
| API docs | Remove V1 endpoints |
| Integration guides | Update for V2 |

---

## Rollback Scenarios

### Scenario: Critical V2 Bug Post-Deprecation

**Mitigation**:
1. V1 contracts still deployed (just paused)
2. Workers can re-enable on-chain responses
3. Relayer can switch back to event listening

**Procedure**:
1. Unpause V1 contracts
2. Set `post_responses = true` in workers
3. Set `v2.enabled = false` in Relayer
4. Announce temporary V1 restoration

### Time to Restore V1
- Configuration changes: ~5 minutes
- Full restoration: ~30 minutes

---

## Success Criteria

| Criterion | Measure |
|-----------|---------|
| Zero V1 transactions | No new V1 responses for 1 week |
| V2 stability | <0.1% error rate for 2 weeks |
| No user complaints | Support tickets related to migration |
| Documentation complete | All docs updated |
| Team sign-off | Engineering + Product approval |

---

## Deliverables

| Item | Owner | Status |
|------|-------|--------|
| Worker config for disabling V1 | TBD | ⏳ |
| V1 contract pause transactions | TBD | ⏳ |
| KMS CiphertextCommits removal | TBD | ⏳ |
| KMS MultichainACL removal | TBD | ⏳ |
| Communication materials | TBD | ⏳ |
| Documentation updates | TBD | ⏳ |

---

## Acceptance Criteria

- [ ] V1 response transactions stopped
- [ ] V1 contracts paused
- [ ] KMS uses only V2 dependencies
- [ ] Zero V1 traffic for 1 week
- [ ] V2 error rate < 0.1%
- [ ] Documentation updated
- [ ] Communication sent
- [ ] Team sign-off obtained
