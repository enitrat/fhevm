# Phase 0: Design Specification Completion

**Duration**: 1 week  
**Dependencies**: None  
**Outcome**: Complete GATEWAY_V2_DESIGN.md with remaining protocol specifications  
**Status**: ✅ COMPLETE

---

## Objective

Finalize the design document before implementation begins. Most concerns are
already addressed in V1 (see Appendix C). This phase adds the remaining specs.

---

## Tasks

### 0.1 Epoch Grace Period Specification ✅

**Gap**: `defineNewContext()` exists but no grace period during MPC rotation.

**Added to Section 5.6.1**:
- State machine: `EPOCH_N_ACTIVE` → `TRANSITION_PERIOD` → `EPOCH_N+1_ACTIVE`
- Grace period duration (configurable, default 100 blocks)
- Rules for signature validity during transition
- Contract changes for KMSVerifier with `isValidSigner()` and `getEffectiveThreshold()`
- `extraData` field epoch binding specification

**Invariants defined**:
- IN-1: During transition, signatures from BOTH epochs are valid
- IN-2: After grace period, only new epoch signatures are valid
- IN-3: Requests started in epoch N can complete with epoch N signatures
- IN-4: Grace period has configurable duration with minimum

---

### 0.2 Worker API Specification ✅

**Created**: `docs/gateway-v2-implementation/WORKER_API_SPEC.md`

**KMS Endpoints**:
| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v1/share/{requestId}` | GET | Retrieve decryption share |
| `/v1/health` | GET | Health check |

**Coprocessor Endpoints**:
| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v1/verify-input` | POST | Submit input for verification |
| `/v1/ciphertext/{handle}` | GET | Fetch ciphertext for KMS |
| `/v1/health` | GET | Health check |

**Included**:
- Complete request/response schemas with all fields documented
- Response states: `ready`, `pending`, `not_found`, `rejected`, `verified`, `found`
- EIP-712 signature formats for all response types
- Error codes and HTTP status codes
- Rate limiting specification
- Security considerations (TLS, replay protection, block anchoring)
- Example flows for user decryption and input verification

---

### 0.3 GatewayConfig API URL Extension ✅

**Added to Section 5.4.1**:
- New `apiUrl` field for `KmsNode` and `Coprocessor` structs
- Discovery flow for Relayer and cold-path users
- URL requirements (HTTPS, base path format)
- New getter functions: `getKmsNodesWithApis()`, `getCoprocessorsWithApis()`
- Migration notes for existing deployments

---

## Deliverables

| Deliverable | Location | Status |
|-------------|----------|--------|
| Epoch grace period spec | GATEWAY_V2_DESIGN.md §5.6.1 | ✅ Complete |
| Worker API spec | WORKER_API_SPEC.md | ✅ Complete |
| GatewayConfig extension spec | GATEWAY_V2_DESIGN.md §5.4.1 | ✅ Complete |

---

## Acceptance Criteria

- [x] Design doc contains all protocol specifications needed for implementation
- [x] API spec defines all endpoints, request/response formats, error codes
- [x] Epoch transition rules are unambiguous
- [ ] Team review and approval

---

## Next Steps

With Phase 0 complete, implementation can proceed:

1. **Phase 1**: Add HTTP APIs to KMS and Coprocessors
   - See `PHASE_1_WORKER_APIS.md`
2. **Phase 2**: Deploy new Gateway contracts
   - See `PHASE_2_GATEWAY_CONTRACTS.md`
