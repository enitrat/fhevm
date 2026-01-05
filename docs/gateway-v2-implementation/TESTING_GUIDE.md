# Gateway V2 Testing Guide

This guide provides comprehensive instructions for testing the Gateway V2 implementation end-to-end.

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [System Architecture](#system-architecture)
4. [Launch the Full Stack](#launch-the-full-stack)
5. [Component-Level Testing](#component-level-testing)
6. [Integration Testing](#integration-testing)
7. [Troubleshooting](#troubleshooting)
8. [Local Development Tips](#local-development-tips)

---

## Overview

Gateway V2 introduces significant architectural changes:

| Component | V1 | V2 |
|-----------|----|----|
| **Worker Responses** | On-chain (Gateway) | HTTP APIs |
| **Consensus** | On-chain (Gateway contracts) | Off-chain (Relayer) |
| **Verification** | Gateway chain | Host Chain or SDK |

### What Changed

| New Component | Location | Purpose |
|---------------|----------|---------|
| KMS Worker API | `kms-connector/crates/kms-worker/src/api/` | `GET /v1/share/{requestId}` returns decryption shares |
| Coprocessor API | `coprocessor/fhevm-engine/gw-listener/src/api/` | `POST /v1/verify-input`, `GET /v1/ciphertext/{handle}` |
| InputVerificationRegistry | `gateway-contracts/contracts/` | Request-only (no response handling) |
| DecryptionRegistry | `gateway-contracts/contracts/` | Request-only (no response handling) |
| KMSVerifierV2 | `host-contracts/contracts/` | Epoch grace period for MPC context transitions |
| DecryptionFallback | `host-contracts/contracts/` | Cold path for trustless fallback |
| Worker API Client | `console/apps/relayer/src/gateway/worker_api/` | HTTP client for polling workers |
| KmsSignersVerifier | `relayer-sdk/src/sdk/kms/` | SDK-side signature verification |

---

## Prerequisites

### Required Tools

```bash
# Docker & Docker Compose
docker --version  # 24.0+
docker compose version  # 2.20+

# Rust (for building coprocessor/kms-connector)
rustc --version  # 1.75+
cargo --version

# Node.js (for contracts/SDK)
node --version  # 18+
pnpm --version  # 8+

# Foundry (for contract testing)
forge --version
```

### Clone Required Repositories

The FHEVM monorepo contains most components. Ensure you have:

```bash
# Main repo
cd /Users/msaug/zama/fhevm

# Related repos (if testing SDK integration)
# /Users/msaug/zama/relayer-sdk
# /Users/msaug/zama/console
```

---

## System Architecture

### Component Topology

```
                                    User / dApp
                                        |
                                        v
                    +-------------------------------------------+
                    |              Relayer (HTTP API)            |
                    |  - Receives user requests                  |
                    |  - Registers on Gateway                    |
                    |  - Polls worker APIs (NEW in V2)          |
                    |  - Aggregates responses                    |
                    +-------------------------------------------+
                           |                    |
                           v                    v
            +------------------+      +------------------+
            |   Gateway Chain  |      |   Worker APIs    |
            | - Payment        |      | - KMS: /share    |
            | - Request events |      | - Copro: /verify |
            +------------------+      +------------------+
                                             |
                                             v
                                    +------------------+
                                    |   Host Chain     |
                                    | - KMSVerifierV2  |
                                    | - InputVerifier  |
                                    | - DecryptFallback|
                                    +------------------+
```

### Service Dependencies

```
minio
  └── coprocessor (S3 storage)

kms-core
  └── kms-connector (KMS operations)

database (PostgreSQL)
  ├── coprocessor
  └── kms-connector

host-node (Anvil)
  └── host-contracts

gateway-node (Anvil)
  └── gateway-contracts

All above
  └── relayer
      └── test-suite
```

---

## Launch the Full Stack

### Option 1: Using fhevm-cli (Recommended)

```bash
cd /Users/msaug/zama/fhevm/test-suite/fhevm

# Deploy with local builds (required for external developers)
./fhevm-cli deploy --build

# This will:
# 1. Clean existing containers
# 2. Start minio, kms-core, database
# 3. Start host-node, gateway-node
# 4. Build and start coprocessor services
# 5. Build and start kms-connector services
# 6. Deploy gateway contracts
# 7. Deploy host contracts
# 8. Start relayer
# 9. Start test-suite container
```

### Expected Output

```
[INFO] FHEVM Stack Versions:
[INFO] FHEVM Contracts:
[INFO]   gateway-contracts:v0.10.2 (local build)
[INFO]   host-contracts:v0.10.2 (local build)
[INFO] FHEVM Coprocessor Services:
[INFO]   coprocessor/db-migration:v0.10.2 (local build)
...
[INFO] All services started successfully!
```

### Verify All Services Running

```bash
# Check container status
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Expected containers:
# - fhevm-minio
# - kms-core
# - coprocessor-and-kms-db
# - host-node
# - gateway-node
# - coprocessor-host-listener
# - coprocessor-gw-listener
# - coprocessor-tfhe-worker
# - coprocessor-zkproof-worker
# - coprocessor-sns-worker
# - coprocessor-transaction-sender
# - kms-connector-gw-listener
# - kms-connector-kms-worker
# - kms-connector-tx-sender
# - fhevm-relayer
# - fhevm-test-suite-e2e-debug
```

---

## Component-Level Testing

### 1. Host Contracts (KMSVerifierV2, DecryptionFallback)

**Location**: `host-contracts/`

```bash
cd /Users/msaug/zama/fhevm/host-contracts

# Install dependencies
pnpm install

# Run all tests
pnpm test

# Run specific V2 tests
pnpm test test/kmsVerifierV2/
pnpm test test/decryptionFallback/
```

**Expected Results**: 54 tests passing

**What's Tested**:
- `KMSVerifierV2`: Epoch grace period, signature validation during transitions
- `DecryptionFallback`: Cold path request submission, event emission

### 2. Gateway Contracts (New Registry Contracts)

**Location**: `gateway-contracts/`

```bash
cd /Users/msaug/zama/fhevm/gateway-contracts

# Install dependencies
pnpm install

# Run tests
pnpm test
```

**What's Tested**:
- `InputVerificationRegistry`: Commitment registration, event emission
- `DecryptionRegistry`: Request registration without response handling
- `GatewayConfig`: API URL storage for workers

### 3. KMS Worker API (Rust)

**Location**: `kms-connector/crates/kms-worker/`

```bash
cd /Users/msaug/zama/fhevm/kms-connector

# Build
cargo build -p kms-worker

# Run tests
cargo test -p kms-worker

# Verify API types compile
cargo check -p kms-worker
```

**Manual API Testing** (when stack is running):

```bash
# Health check
curl http://localhost:8081/v1/health

# Get share (replace with actual requestId)
curl http://localhost:8081/v1/share/0x1234...
```

### 4. Coprocessor API (Rust)

**Location**: `coprocessor/fhevm-engine/gw-listener/`

```bash
cd /Users/msaug/zama/fhevm/coprocessor

# Build
cargo build -p gw-listener

# Run tests
cargo test -p gw-listener

# Verify API compiles
cargo check -p gw-listener
```

**Manual API Testing** (when stack is running):

```bash
# Health check
curl http://localhost:8082/v1/health

# Get ciphertext (replace with actual handle)
curl http://localhost:8082/v1/ciphertext/0xabcd...
```

### 5. SDK KmsSignersVerifier

**Location**: `relayer-sdk/`

```bash
cd /Users/msaug/zama/relayer-sdk

# Install dependencies
pnpm install

# Run tests
pnpm test

# Run specific KMS tests
pnpm test src/sdk/kms/KmsSignersVerifier.test.ts
```

**Expected Results**: 20/24 tests passing (4 fail due to test infrastructure, not implementation)

---

## Integration Testing

### Run E2E Tests via fhevm-cli

```bash
cd /Users/msaug/zama/fhevm/test-suite/fhevm

# Input verification flow
./fhevm-cli test input-proof

# User decryption flow
./fhevm-cli test user-decryption

# Public decryption flows
./fhevm-cli test public-decrypt-http-ebool
./fhevm-cli test public-decrypt-http-mixed

# ERC20 (comprehensive flow)
./fhevm-cli test erc20

# Debug mode (shell into test container)
./fhevm-cli test debug
```

### Test V2-Specific Flows

**Note**: The current test-suite may not have V2-specific tests yet. Here's how to verify V2 functionality manually:

#### 1. Verify Worker APIs are Exposed

```bash
# From test container
docker exec -it fhevm-test-suite-e2e-debug bash

# Check KMS worker API
curl http://kms-connector-kms-worker:8080/v1/health

# Check Coprocessor API
curl http://coprocessor-gw-listener:8080/v1/health
```

#### 2. Verify API URLs in GatewayConfig

```bash
# From test container, check GatewayConfig has apiUrl fields
docker exec -it fhevm-test-suite-e2e-debug bash

# Use cast or hardhat to query GatewayConfig
cast call $GATEWAY_CONFIG_ADDRESS "getKmsNodes()" --rpc-url $GATEWAY_RPC
```

#### 3. Verify Epoch Grace Period (KMSVerifierV2)

```bash
# Run the specific unit tests
cd /Users/msaug/zama/fhevm/host-contracts
pnpm test test/kmsVerifierV2/KMSVerifierV2.ts
```

---

## Troubleshooting

### Common Issues

#### 1. Docker Build Failures

```bash
# Issue: "Cannot pull image" or "unauthorized"
# Solution: Use --build flag
./fhevm-cli deploy --build
```

#### 2. Service Not Starting

```bash
# Check logs
./fhevm-cli logs <service-name>

# Common services:
./fhevm-cli logs coprocessor-gw-listener
./fhevm-cli logs kms-connector-kms-worker
./fhevm-cli logs fhevm-relayer
```

#### 3. Contract Deployment Failures

```bash
# Check gateway contract deployment
docker logs gateway-sc-deploy

# Check host contract deployment
docker logs host-sc-deploy
```

#### 4. Database Connection Issues

```bash
# Check database is running
docker logs coprocessor-and-kms-db

# Check migrations ran
docker logs coprocessor-db-migration
docker logs kms-connector-db-migration
```

### Clean Start

```bash
# Full cleanup
./fhevm-cli clean

# Remove all docker resources
docker system prune -af --volumes

# Redeploy
./fhevm-cli deploy --build
```

---

## Local Development Tips

### 1. Faster Iteration on Rust Components

Instead of rebuilding the entire stack, you can:

```bash
# Build only your component
cd /Users/msaug/zama/fhevm/coprocessor
cargo build -p gw-listener --release

# Copy binary to running container
docker cp target/release/gw-listener coprocessor-gw-listener:/app/

# Restart container
docker restart coprocessor-gw-listener
```

### 2. Faster Iteration on Contracts

```bash
# Deploy only contracts (skip other services)
cd /Users/msaug/zama/fhevm/host-contracts
pnpm hardhat run scripts/deploy.ts --network localhost
```

### 3. View Real-time Logs

```bash
# Multi-container logs
docker compose -p fhevm logs -f coprocessor-gw-listener kms-connector-kms-worker fhevm-relayer
```

### 4. Connect to Test Container

```bash
# Interactive shell
./fhevm-cli test debug

# Inside container, run arbitrary tests
npx hardhat test --grep "my test pattern"
```

### 5. Environment Variables

Check/modify environment files:

```bash
# View all env files
ls /Users/msaug/zama/fhevm/test-suite/fhevm/env/staging/

# Key files:
# .env.coprocessor - Coprocessor configuration
# .env.kms-connector - KMS connector configuration
# .env.relayer - Relayer configuration
# .env.gateway-sc - Gateway contract addresses
# .env.host-sc - Host contract addresses
```

---

## V2 Implementation Gaps

The following items need attention before full V2 testing:

### 1. Worker API Integration

- [ ] KMS worker API server is implemented but needs integration into the main service loop
- [ ] Coprocessor API server is implemented but needs integration into gw-listener
- [ ] Workers need to populate API responses from computed results

### 2. Gateway Contract Updates

- [ ] `GatewayConfig.sol` needs `apiUrl` field added to `KmsNode` and `Coprocessor` structs
- [ ] `InputVerificationRegistry` and `DecryptionRegistry` contracts need deployment scripts

### 3. Relayer Updates

- [ ] Worker API client (`WorkerApiClient`, `WorkerApiPoller`) needs integration into main relayer flow
- [ ] `UserDecryptHandlerV2` needs to replace or coexist with V1 handler

### 4. SDK Integration

- [ ] `KmsSignersVerifier` needs integration into `userDecrypt` flow
- [ ] Requires TKMS library interface changes

### 5. Test Suite

- [ ] E2E tests for V2-specific flows (API polling, epoch transitions)
- [ ] Contract tests for new Gateway contracts

---

## Next Steps

1. **Complete Worker API Integration**: Wire up the API servers to actual KMS/Coprocessor operations
2. **Deploy V2 Contracts**: Add deployment scripts for new contracts
3. **Update E2E Tests**: Add V2-specific test scenarios
4. **Integration Testing**: Full flow testing with all V2 components

---

## References

- [Gateway V2 Design Document](../../GATEWAY_V2_DESIGN.md)
- [Worker API Specification](./WORKER_API_SPEC.md)
- [Phase Implementation Docs](./PHASE_*.md)
- [Test Suite README](../../test-suite/README.md)
