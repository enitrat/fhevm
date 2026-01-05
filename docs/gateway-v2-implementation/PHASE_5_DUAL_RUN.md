# Phase 5: Dual-Run Validation

**Duration**: 2-4 weeks  
**Dependencies**: Phase 1-4 complete  
**Outcome**: V1 and V2 running in parallel, validated equivalent

---

## Objective

Run V1 and V2 flows simultaneously to validate correctness before deprecating V1.

---

## Dual-Run Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        USER REQUEST                              │
│                             │                                    │
│              ┌──────────────┴──────────────┐                    │
│              │                             │                    │
│              ▼                             ▼                    │
│      ┌───────────────┐            ┌───────────────┐            │
│      │    V1 Flow    │            │    V2 Flow    │            │
│      │               │            │               │            │
│      │ • Gateway TX  │            │ • Gateway TX  │            │
│      │ • On-chain    │            │ • API polling │            │
│      │   response    │            │               │            │
│      └───────┬───────┘            └───────┬───────┘            │
│              │                             │                    │
│              └──────────────┬──────────────┘                    │
│                             │                                   │
│                             ▼                                   │
│                    ┌───────────────┐                           │
│                    │   COMPARATOR  │                           │
│                    │               │                           │
│                    │ • Same result?│                           │
│                    │ • Same timing?│                           │
│                    │ • Same errors?│                           │
│                    └───────────────┘                           │
└─────────────────────────────────────────────────────────────────┘
```

---

## Validation Strategy

### Mode: Shadow (Default)
- V1 is primary (user gets V1 response)
- V2 runs in background
- Results compared, discrepancies logged

### Mode: Canary
- X% of traffic uses V2 as primary
- 100-X% uses V1 as primary
- Gradual rollout

### Mode: V2 Primary
- V2 is primary (user gets V2 response)
- V1 runs in background for comparison

---

## Comparison Points

### Functional Correctness

| Check | V1 Source | V2 Source | Match Criteria |
|-------|-----------|-----------|----------------|
| Handles (input verif) | Gateway event | API response | Byte-equal |
| Shares (user decrypt) | Gateway event | API response | Signature-equal |
| Decrypted value (public) | Gateway event | API response | Byte-equal |
| Error cases | Gateway revert | API error | Same error type |

### Performance

| Metric | V1 | V2 | Expected |
|--------|----|----|----------|
| Latency (input verif) | ~10-30s | ~100-500ms | V2 faster |
| Latency (decryption) | ~10-30s | ~1-5s | V2 faster |
| Throughput | ~25/s | 200+/s | V2 higher |

### Reliability

| Metric | Threshold |
|--------|-----------|
| V1/V2 result match rate | >99.9% |
| V2 error rate | <0.1% |
| V2 timeout rate | <1% |

---

## Monitoring

### Metrics to Collect

```
# Comparison results
gateway_v2_comparison_match_total{flow="input_verification"}
gateway_v2_comparison_mismatch_total{flow="input_verification", reason="..."}

# Latency comparison
gateway_v1_latency_seconds{flow="...", quantile="..."}
gateway_v2_latency_seconds{flow="...", quantile="..."}

# Error rates
gateway_v1_error_total{flow="...", error_type="..."}
gateway_v2_error_total{flow="...", error_type="..."}
```

### Alerts

| Alert | Condition | Action |
|-------|-----------|--------|
| High mismatch rate | >1% mismatches in 5m | Investigate immediately |
| V2 latency spike | P99 > 10s | Check worker health |
| V2 error spike | >5% errors in 5m | Consider rollback |

### Dashboard

- Real-time V1/V2 comparison
- Latency percentiles side-by-side
- Error breakdown by type
- Throughput graphs

---

## Rollback Plan

### Triggers
- Mismatch rate > 5%
- V2 error rate > 10%
- Critical bug discovered

### Procedure
1. Set `v2.enabled = false` in Relayer config
2. Restart Relayer (or hot-reload config)
3. Verify V1 traffic restored
4. Investigate root cause
5. Fix and re-enable V2

### Invariant
- V1 contracts and flow UNCHANGED throughout dual-run
- Rollback takes < 5 minutes

---

## Test Scenarios

### Positive Cases
| Scenario | Expected |
|----------|----------|
| Simple input verification | V1 = V2 |
| Simple user decryption | V1 = V2 |
| Simple public decryption | V1 = V2 |
| Large input (max handles) | V1 = V2 |
| Concurrent requests (100) | V1 = V2 |

### Negative Cases
| Scenario | Expected |
|----------|----------|
| Invalid signature | Both reject |
| ACL denied | Both reject |
| Unknown handle | Both reject |
| Timeout | V2 may be faster to timeout |

### Edge Cases
| Scenario | Handling |
|----------|----------|
| Worker temporarily down | V2 retries, V1 may fail |
| Gateway congested | V2 unaffected, V1 slow |
| Network partition | Both may fail, V2 faster to detect |

---

## Duration & Criteria

### Minimum Dual-Run Period
- 2 weeks in shadow mode
- 1 week in canary mode (10% → 50% → 90%)
- 1 week in V2 primary mode

### Go/No-Go Criteria

| Criterion | Required |
|-----------|----------|
| Match rate | >99.9% |
| V2 error rate | <0.1% |
| V2 P99 latency | <5s |
| No critical bugs | Yes |
| Team sign-off | Yes |

---

## Deliverables

| Item | Owner | Status |
|------|-------|--------|
| Dual-run mode in Relayer | TBD | ⏳ |
| Comparator logic | TBD | ⏳ |
| Metrics + dashboard | TBD | ⏳ |
| Alerting rules | TBD | ⏳ |
| Rollback runbook | TBD | ⏳ |

---

## Acceptance Criteria

- [ ] Shadow mode operational
- [ ] Canary mode operational
- [ ] Comparison metrics collected
- [ ] Dashboard shows V1/V2 comparison
- [ ] Alerts configured
- [ ] Rollback tested
- [ ] 2+ weeks of successful dual-run
- [ ] Go/no-go criteria met
