# Phase 2: Gateway Contract Updates

**Duration**: 2-3 weeks  
**Dependencies**: Phase 0 (spec), Phase 1 (APIs testable)  
**Outcome**: Simplified Gateway contracts without response handling

---

## Objective

Deploy NEW V2 contracts alongside V1. V1 remains operational during transition.

---

## Contract Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      GATEWAY CHAIN                               │
│                                                                  │
│  V1 (unchanged)                    V2 (new)                     │
│  ┌────────────────────┐           ┌────────────────────────┐   │
│  │ InputVerification  │           │ InputVerificationRegistry│   │
│  │ • request()        │           │ • register() commitment  │   │
│  │ • response()       │           │ • NO response handling   │   │
│  └────────────────────┘           │ • dispute/reimburse      │   │
│                                   └────────────────────────────┘   │
│  ┌────────────────────┐           ┌────────────────────────┐   │
│  │ Decryption         │           │ DecryptionRegistry      │   │
│  │ • request()        │           │ • request() same events │   │
│  │ • response()       │           │ • NO response handling   │   │
│  └────────────────────┘           │ • dispute/reimburse      │   │
│                                   └────────────────────────────┘   │
│  ┌────────────────────┐                                          │
│  │ Shared             │◀─────────────────────────────────────────│
│  │ • GatewayConfig    │                                          │
│  │ • ProtocolPayment  │                                          │
│  └────────────────────┘                                          │
└─────────────────────────────────────────────────────────────────┘
```

---

## New Contract: InputVerificationRegistry

### Location
```
gateway-contracts/contracts/InputVerificationRegistry.sol
gateway-contracts/contracts/interfaces/IInputVerificationRegistry.sol
```

### Purpose
Register input verification with commitment only. No response handling.

### Interface
```
registerInputVerification(commitment, chainId, contractAddress) → requestId
dispute(requestId)
reimburse(requestId)
getRequest(requestId) → (commitment, payer, fee, timestamp, status)
```

### Events
```
InputVerificationRegistered(requestId, commitment, userAddress, chainId, contractAddress, timestamp)
DisputeOpened(requestId, disputer, timestamp)
RequestReimbursed(requestId, payer, amount)
```

### State
```
requestCounter: uint256
commitments: mapping(requestId => bytes32)
escrows: mapping(requestId => {payer, fee, timestamp, status})
disputeTimestamps: mapping(requestId => uint256)
```

### Invariants
- Commitment MUST be non-zero
- Fee collected and escrowed at registration
- Dispute only after DISPUTE_TIMEOUT (1 hour)
- Reimburse only after RESOLUTION_WINDOW (1 hour after dispute)
- No double-dispute, no double-reimburse

### Gas Comparison
| Operation | V1 | V2 |
|-----------|----|----|
| Request | ~10KB calldata | ~100 bytes calldata |
| Response | N × ~500 bytes | 0 (off-chain) |
| **Total** | ~15KB | ~100 bytes |

---

## New Contract: DecryptionRegistry

### Location
```
gateway-contracts/contracts/DecryptionRegistry.sol
gateway-contracts/contracts/interfaces/IDecryptionRegistry.sol
```

### Purpose
Register decryption requests. Same events as V1 for worker compatibility.
No response handling.

### Interface
```
requestUserDecryption(handles, contractAddresses, publicKey, signature, chainId, extraData) → requestId
requestPublicDecryption(handles, chainId, extraData) → requestId
dispute(requestId)
reimburse(requestId)
```

### Events (same as V1 requests)
```
UserDecryptionRequested(requestId, handles, contractAddresses, userAddress, publicKey, signature, chainId, timestamp)
PublicDecryptionRequested(requestId, handles, chainId, timestamp)
DisputeOpened(requestId, disputer, timestamp)
RequestReimbursed(requestId, payer, amount)
```

### State
```
publicDecryptionCounter: uint256 (initialized at PUBLIC_DECRYPT_COUNTER_BASE)
userDecryptionCounter: uint256 (initialized at USER_DECRYPT_COUNTER_BASE)
escrows: mapping(requestId => {payer, fee, timestamp, status})
disputeTimestamps: mapping(requestId => uint256)
```

### Invariants
- Request ID format matches V1 (prefix-based uniqueness)
- Events match V1 schema exactly (workers don't need changes)
- Fee escrowed, refundable via dispute

---

## Dispute Protocol

```
┌────────────┐    DISPUTE_TIMEOUT    ┌────────────┐    RESOLUTION_WINDOW    ┌────────────┐
│ Registered │────────(1 hour)──────▶│  Disputed  │────────(1 hour)────────▶│ Reimbursed │
└────────────┘                       └────────────┘                         └────────────┘
      │                                    │                                      │
      │ Normal: workers respond            │ Anyone can dispute                   │ Payer gets
      │ via API, verified at               │ with small fee                       │ fee back
      │ point of use                       │                                      │
      ▼                                    ▼                                      ▼
 (no on-chain action)              (fee held as spam protection)          (dispute fee refunded)
```

### Constants
```
DISPUTE_TIMEOUT = 1 hour
RESOLUTION_WINDOW = 1 hour
DISPUTE_FEE = 0.001 ether (spam protection)
```

### Invariants
- Dispute requires `block.timestamp > request.timestamp + DISPUTE_TIMEOUT`
- Reimburse requires `block.timestamp > dispute.timestamp + RESOLUTION_WINDOW`
- Dispute fee refunded on successful reimbursement
- Cannot dispute already-disputed or reimbursed requests

---

## Files NOT Changed

These V1 contracts remain for backward compatibility:

| Contract | Reason |
|----------|--------|
| `Decryption.sol` | V1 flow operational during transition |
| `InputVerification.sol` | V1 flow operational during transition |
| `CiphertextCommits.sol` | KMS can still use as fallback |
| `MultichainACL.sol` | Deprecated but not removed yet |
| `GatewayConfig.sol` | Shared, add apiUrl fields |
| `ProtocolPayment.sol` | Shared, unchanged |

---

## Deployment

### Order
1. Deploy InputVerificationRegistry
2. Deploy DecryptionRegistry
3. Update GatewayConfig with apiUrl fields
4. Configure Relayer for V2 contracts
5. Run dual-mode (V1 + V2)

### Upgrade Path
- V2 contracts deployed as UUPS proxies
- Can upgrade logic without changing addresses
- V1 contracts NOT upgraded (frozen)

---

## Testing Strategy

### Unit Tests
| Test | Assertion |
|------|-----------|
| Registration | Correct event, fee escrowed, requestId returned |
| Dispute too early | Reverts with correct error |
| Dispute success | Status changes, event emitted |
| Double dispute | Reverts |
| Reimburse too early | Reverts |
| Reimburse success | Fee transferred, dispute fee refunded |
| Gas measurement | V2 < V1 by ~100x for input verification |

### Integration Tests
- Register on V2 → workers receive event → respond via API
- Dispute flow end-to-end
- V1 and V2 running simultaneously

---

## Deliverables

| Contract | File | Status |
|----------|------|--------|
| InputVerificationRegistry | `contracts/InputVerificationRegistry.sol` | ⏳ |
| IInputVerificationRegistry | `contracts/interfaces/IInputVerificationRegistry.sol` | ⏳ |
| DecryptionRegistry | `contracts/DecryptionRegistry.sol` | ⏳ |
| IDecryptionRegistry | `contracts/interfaces/IDecryptionRegistry.sol` | ⏳ |
| GatewayConfig update | `contracts/GatewayConfig.sol` | ⏳ |
| Deployment script | `deploy/deploy_v2.ts` | ⏳ |

---

## Acceptance Criteria

- [ ] InputVerificationRegistry registers with commitment only
- [ ] DecryptionRegistry emits same events as V1 Decryption
- [ ] Neither V2 contract has response handling functions
- [ ] Dispute/reimburse mechanism works correctly
- [ ] Gas for input verification reduced ~100x
- [ ] V1 contracts unchanged and operational
- [ ] All tests pass
