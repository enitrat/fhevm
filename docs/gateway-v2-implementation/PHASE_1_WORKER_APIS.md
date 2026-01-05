# Phase 1: Worker HTTP API Endpoints

**Duration**: 4-6 weeks  
**Dependencies**: Phase 0 (API spec)  
**Outcome**: KMS and Coprocessors expose HTTP APIs for response retrieval

---

## Objective

Add HTTP API output channel to workers. Existing response storage and on-chain
submission remain unchanged (dual-mode operation).

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         KMS CONNECTOR                            │
│                                                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐       │
│  │  gw-listener │───▶│  kms-worker  │───▶│  DB Storage  │       │
│  └──────────────┘    └──────────────┘    └──────┬───────┘       │
│                                                  │               │
│                      ┌───────────────────────────┼───────────┐  │
│                      │                           ▼           │  │
│                      │  ┌──────────────┐   ┌──────────┐     │  │
│                      │  │  tx-sender   │   │ API Server│◀────┼──┼── Relayer
│                      │  │  (V1 path)   │   │ (V2 path) │     │  │
│                      │  └──────────────┘   └──────────┘     │  │
│                      │         │                             │  │
│                      └─────────┼─────────────────────────────┘  │
│                                ▼                                 │
│                           Gateway                                │
└─────────────────────────────────────────────────────────────────┘
```

---

## Component: KMS API Server

### Location
```
kms-connector/crates/kms-worker/src/api/
├── mod.rs
├── server.rs
├── handlers.rs
├── types.rs
└── middleware.rs
```

### Responsibilities
1. Expose `GET /v1/share/{requestId}` endpoint
2. Query existing DB tables (`public_decryption_responses`, `user_decryption_responses`)
3. Return share data with signature and metadata
4. Rate limiting per IP/requestId
5. Metrics collection

### Data Flow
```
Request ──▶ Rate Limiter ──▶ Handler ──▶ DB Query ──▶ Response
                                              │
                                              ▼
                              Existing tables (no schema change)
```

### Invariants
- API returns ONLY data already in DB (no computation on request)
- Request ID prefix determines table to query (public vs user)
- Response includes anchoring block info for reorg detection
- Rate limiting keyed by requestId prevents duplicate work

### Assertions
- `GET /share/{id}` for known ID returns 200 with share OR 202 pending
- `GET /share/{id}` for unknown ID returns 404
- Response signature matches DB-stored signature exactly
- Health endpoint responds within 100ms

---

## Component: Coprocessor API Server

### Location
```
coprocessor/fhevm-engine/api-server/  (new crate)
├── Cargo.toml
└── src/
    ├── lib.rs
    ├── server.rs
    └── handlers/
```

### Responsibilities
1. Expose `POST /v1/verify-input` endpoint
2. Verify commitment matches on-chain registration
3. Queue verification job (existing zkproof-worker flow)
4. Expose `GET /v1/ciphertext/{handle}` for KMS fetch
5. Sign responses with coprocessor key

### Commitment Verification Flow
```
┌─────────┐     ┌─────────────┐     ┌──────────────┐
│ Relayer │────▶│ API Server  │────▶│ Gateway RPC  │
└─────────┘     └──────┬──────┘     └──────────────┘
                       │                    │
                       │  commitment        │ on-chain commitment
                       │  from payload      │
                       ▼                    ▼
                 ┌─────────────────────────────┐
                 │   hash(payload) == on-chain │
                 │        commitment?          │
                 └─────────────┬───────────────┘
                               │
              ┌────────────────┴────────────────┐
              │                                 │
              ▼                                 ▼
         ✅ Process                        ❌ Reject
```

### Invariants
- NEVER process request without on-chain payment verification
- Commitment verification MUST happen before ZKPoK verification
- Ciphertext endpoint signs response to prevent tampering
- Multiple coprocessors return same handles for same input

### Assertions
- `POST /verify-input` with valid commitment returns 200 or 202
- `POST /verify-input` with mismatched commitment returns 400
- `GET /ciphertext/{handle}` returns signed ciphertext material
- Digest in ciphertext response matches handle

---

## Component: KMS Direct ACL Query

### Location
```
kms-connector/crates/kms-worker/src/core/event_processor/decryption.rs
```

### Change
Replace MultichainACL query with direct Host Chain ACL query.

### Data Flow
```
Decrypt Request ──▶ Extract chain_id ──▶ Get Host RPC ──▶ Query ACL.isAllowed()
                                                                   │
                                                                   ▼
                                              ┌─────────────────────────────┐
                                              │ If allowed: proceed         │
                                              │ If denied: reject + store   │
                                              └─────────────────────────────┘
```

### Invariants
- ACL check uses finalized block (wait for finality_lag)
- All KMS nodes query same block height (use event's block)
- Cache Host Chain provider connections per chain_id
- Fallback to multiple RPCs on failure

### Assertions
- ACL check for allowed handle returns true
- ACL check for disallowed handle returns false and logs rejection
- RPC failure triggers retry with backoff

---

## Component: KMS Ciphertext Fetch from Coprocessor

### Location
```
kms-connector/crates/kms-worker/src/core/event_processor/coprocessor_client.rs (new)
```

### Change
Fetch ciphertext from Coprocessor HTTP API instead of S3/CiphertextCommits.

### Data Flow
```
Handle ──▶ Try Coprocessor 1 ──▶ Verify digest ──▶ Return
                │                      │
                ▼                      ▼
           Try Coprocessor 2     ❌ Mismatch: try next
                │
                ▼
           Try Coprocessor N
```

### Invariants
- Try ALL coprocessors until one succeeds (byzantine tolerance)
- ALWAYS verify `keccak256(ciphertext) == digest_from_handle`
- Cache successful fetches (ciphertexts are immutable)
- Timeout per coprocessor attempt

### Assertions
- Fetch succeeds if at least one coprocessor is available
- Digest mismatch triggers next coprocessor attempt
- All coprocessors down returns error (not stale data)

---

## Component: GatewayConfig API URLs

### Location
```
gateway-contracts/contracts/GatewayConfig.sol
gateway-contracts/contracts/shared/Structs.sol
```

### Change
Add `apiUrl` field to KmsNode and Coprocessor structs.

### Interface Change
```
KmsNode {
  signerAddress, txSenderAddress, storageUrl, apiUrl  // apiUrl is NEW
}

Coprocessor {
  signerAddress, txSenderAddress, s3BucketUrl, apiUrl  // apiUrl is NEW
}
```

### Invariants
- apiUrl is optional (empty string for V1-only nodes)
- Registration functions updated to accept apiUrl
- Events include apiUrl for indexing

---

## Testing Strategy

### Unit Tests
- Handler logic with mocked DB
- Commitment verification
- Digest verification

### Integration Tests
- Full flow: register request → poll API → get response
- Rate limiting behavior
- Error cases (not found, rejected, timeout)

### E2E Tests
- V1 on-chain flow still works
- V2 API flow works
- Both flows work simultaneously

---

## Deliverables

| Component | Location | Owner |
|-----------|----------|-------|
| KMS API Server | `kms-connector/crates/kms-worker/src/api/` | TBD |
| Coprocessor API Server | `coprocessor/fhevm-engine/api-server/` | TBD |
| KMS Direct ACL | `kms-connector/.../decryption.rs` | TBD |
| KMS Coprocessor Client | `kms-connector/.../coprocessor_client.rs` | TBD |
| GatewayConfig Update | `gateway-contracts/contracts/` | TBD |

---

## Acceptance Criteria

- [ ] KMS API returns shares from existing DB storage
- [ ] Coprocessor API verifies commitment before processing
- [ ] KMS queries Host Chain ACL directly
- [ ] KMS fetches ciphertext from Coprocessor API with digest verification
- [ ] GatewayConfig stores API URLs
- [ ] V1 on-chain response flow unchanged
- [ ] All endpoints have rate limiting and metrics
- [ ] Integration tests pass
