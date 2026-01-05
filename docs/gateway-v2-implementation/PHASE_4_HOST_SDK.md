# Phase 4: Host Chain & SDK Updates

**Duration**: 2-3 weeks  
**Dependencies**: Phase 1-3 (V2 pipeline working)  
**Outcome**: Cold path support + SDK signature verification

---

## Objective

1. Enable cold path (bypass Gateway/Relayer entirely)
2. Ensure SDK verifies signatures for user decryption
3. Verify existing Host Chain verifiers work with V2

---

## Component: DecryptionFallback Contract

### Location
```
host-contracts/contracts/DecryptionFallback.sol
```

### Purpose
Cold path entry point on Host Chain. Users can submit decryption requests
directly, bypassing Gateway and Relayer.

### Interface
```
requestUserDecryption(handles, contractAddresses, publicKey, signature) → requestId
requestPublicDecryption(handles) → requestId
getRequest(requestId) → (handles, requester, publicKey, type, timestamp)
```

### Events
```
DecryptionRequested(requestId, handles, requester, publicKey, decryptionType, timestamp)
```

**Note**: KMS must listen to this event in addition to Gateway events.

### Request ID Format
```
Cold path prefix: 0x03 << 248 | counter
```
This distinguishes cold path requests from Gateway requests (0x01, 0x02 prefixes).

### Payment
- Uses native token (ETH) instead of ZAMA token
- BASE_FEE constant covers worker processing cost
- No dispute mechanism (direct payment, immediate)

### Invariants
- Request ID globally unique across Gateway + Host Chain
- KMS treats cold path requests identically to Gateway requests
- Users poll KMS directly (no Relayer involvement)

---

## Component: KMS Cold Path Listener

### Location
```
kms-connector/crates/gw-listener/src/
```

### Change
Add Host Chain event listener alongside Gateway listener.

### Architecture
```
┌─────────────────────────────────────────────────────────┐
│                    KMS LISTENER                          │
│                                                          │
│  ┌─────────────────┐      ┌─────────────────────┐       │
│  │ Gateway Listener│      │ Host Chain Listener │       │
│  │ (existing)      │      │ (new)               │       │
│  └────────┬────────┘      └──────────┬──────────┘       │
│           │                          │                   │
│           └──────────┬───────────────┘                   │
│                      │                                   │
│                      ▼                                   │
│              ┌───────────────┐                          │
│              │ Event Queue   │ ◀── Same processing      │
│              │ (unified)     │     for both sources     │
│              └───────────────┘                          │
└─────────────────────────────────────────────────────────┘
```

### Configuration
```toml
[host_chains]
enabled = true

[[host_chains.chains]]
chain_id = 1
rpc_url = "wss://eth-mainnet.example.com"
decryption_fallback_address = "0x..."

[[host_chains.chains]]
chain_id = 11155111
rpc_url = "wss://eth-sepolia.example.com"
decryption_fallback_address = "0x..."
```

### Invariants
- Same finality rules apply (wait finality_lag blocks)
- Same event processing logic (no special cases)
- Both listeners run in parallel

---

## Component: SDK Signature Verification

### Location
External repository: `relayer-sdk` (`@zama-fhe/relayer-sdk` package)

### Requirement
SDK MUST verify KMS signatures before using user decryption results.

### Verification Flow
```
┌─────────────────────────────────────────────────────────────┐
│                SDK SIGNATURE VERIFICATION                    │
│                                                              │
│  1. Receive shares from Relayer                             │
│                                                              │
│  2. For each share:                                         │
│     a. Compute EIP-712 typed data hash                      │
│     b. Recover signer from signature                        │
│     c. Check signer is in MPC context                       │
│     d. Check signer not already seen (no duplicates)        │
│                                                              │
│  3. Check: valid_shares.length >= threshold                 │
│                                                              │
│  4. If pass: proceed to decrypt                             │
│     If fail: throw error                                    │
└─────────────────────────────────────────────────────────────┘
```

### EIP-712 Domain
```
{
  name: "FHEVM",
  version: "2",
  chainId: <request chain id>,
  verifyingContract: <Decryption contract address>
}
```

### Invariants
- NEVER use shares without verification
- Reject if fewer than threshold valid signatures
- Reject duplicate signers
- Fetch MPC context from GatewayConfig or cached registry

---

## Component: Endpoint Discovery (Cold Path)

### Purpose
Cold path users need to discover KMS API endpoints without Relayer.

### Option A: Query GatewayConfig
```
GatewayConfig.getKmsNode(index) → {signerAddress, txSenderAddress, storageUrl, apiUrl}
```

SDK fetches all KMS nodes, extracts apiUrl, polls each.

### Option B: Static Registry
Distribute `kms-endpoints.json` with SDK:
```json
{
  "mainnet": {
    "kmsNodes": ["https://kms1.zama.ai", ...],
    "threshold": 2
  }
}
```

### Recommendation
- Use Option A (GatewayConfig) as primary
- Provide Option B as fallback for offline scenarios

---

## Verification: Existing Verifiers

### InputVerifier (host-contracts/contracts/InputVerifier.sol)

**V2 Compatibility**: ✅ Should work unchanged

| What V2 Changes | InputVerifier Impact |
|-----------------|---------------------|
| Signatures come via HTTP | None - verifies signature bytes |
| Commitment on Gateway | None - verifies against handles |

**Test**: Submit V2 input → use handles on Host Chain → InputVerifier accepts

### KMSVerifier (host-contracts/contracts/KMSVerifier.sol)

**V2 Compatibility**: ✅ Should work unchanged

| What V2 Changes | KMSVerifier Impact |
|-----------------|-------------------|
| Shares come via HTTP | None - verifies signature bytes |
| No on-chain aggregation | None - verifies individual signatures |

**Test**: Submit V2 public decrypt → use result on Host Chain → KMSVerifier accepts

---

## Testing Strategy

### Cold Path Tests
| Test | Assertion |
|------|-----------|
| Submit via DecryptionFallback | Event emitted, KMS observes |
| Poll KMS directly | Shares returned |
| Use result on Host Chain | KMSVerifier accepts |

### SDK Verification Tests
| Test | Assertion |
|------|-----------|
| Valid signatures | Verification passes |
| Invalid signature | Rejected |
| Duplicate signer | Rejected |
| Below threshold | Rejected |

### E2E Tests
| Test | Assertion |
|------|-----------|
| Cold path user decrypt | Full flow works without Relayer |
| Cold path public decrypt | Full flow works |
| V2 input → InputVerifier | Handles accepted |
| V2 public decrypt → KMSVerifier | Result accepted |

---

## Deliverables

| Component | Location | Status |
|-----------|----------|--------|
| DecryptionFallback | `host-contracts/contracts/DecryptionFallback.sol` | ⏳ |
| KMS Host Chain Listener | `kms-connector/crates/gw-listener/` | ⏳ |
| SDK Verification | External SDK repo | ⏳ |
| Endpoint Discovery | SDK + GatewayConfig | ⏳ |
| Integration Tests | Various | ⏳ |

---

## Acceptance Criteria

- [ ] DecryptionFallback deployed on supported Host Chains
- [ ] KMS listens to both Gateway and Host Chain events
- [ ] Cold path decryption works end-to-end
- [ ] SDK verifies KMS signatures before using shares
- [ ] SDK provides endpoint discovery for cold path
- [ ] InputVerifier accepts V2 input verification results
- [ ] KMSVerifier accepts V2 public decryption results
- [ ] All tests pass
