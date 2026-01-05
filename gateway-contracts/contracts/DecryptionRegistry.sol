// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import { gatewayConfigAddress } from "../addresses/GatewayAddresses.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IGatewayConfig } from "./interfaces/IGatewayConfig.sol";
import { UUPSUpgradeableEmptyProxy } from "./shared/UUPSUpgradeableEmptyProxy.sol";
import { GatewayConfigChecks } from "./shared/GatewayConfigChecks.sol";
import { Pausable } from "./shared/Pausable.sol";
import { GatewayOwnable } from "./shared/GatewayOwnable.sol";
import { ProtocolPaymentUtils } from "./shared/ProtocolPaymentUtils.sol";
import { FheType } from "./shared/FheType.sol";
import { FHETypeBitSizes } from "./libraries/FHETypeBitSizes.sol";
import { HandleOps } from "./libraries/HandleOps.sol";

/**
 * @title DecryptionRegistry - Gateway V2
 * @notice Simplified decryption registry that only handles request registration.
 * @dev In V2, KMS nodes respond via HTTP API instead of on-chain transactions.
 *      This contract only registers requests and emits events for KMS nodes to observe.
 *      Response handling and aggregation happens off-chain in the Relayer or SDK.
 */
contract DecryptionRegistry is
    EIP712Upgradeable,
    UUPSUpgradeableEmptyProxy,
    GatewayOwnable,
    GatewayConfigChecks,
    ProtocolPaymentUtils,
    Pausable
{
    // ============ Events ============

    /**
     * @notice Emitted when a user decryption request is registered.
     * @param requestId Unique identifier for this request
     * @param handles Ciphertext handles to decrypt
     * @param contractAddresses Associated contract addresses
     * @param userAddress User requesting the decryption
     * @param publicKey User's public key for re-encryption
     * @param signature User's EIP-712 signature authorizing the request
     * @param chainId Chain ID of the contracts
     * @param timestamp Block timestamp when request was registered
     */
    event UserDecryptionRequested(
        uint256 indexed requestId,
        bytes32[] handles,
        address[] contractAddresses,
        address indexed userAddress,
        bytes publicKey,
        bytes signature,
        uint256 chainId,
        uint256 timestamp
    );

    /**
     * @notice Emitted when a public decryption request is registered.
     * @param requestId Unique identifier for this request
     * @param handles Ciphertext handles to decrypt
     * @param chainId Chain ID where handles were created
     * @param timestamp Block timestamp when request was registered
     */
    event PublicDecryptionRequested(
        uint256 indexed requestId,
        bytes32[] handles,
        uint256 chainId,
        uint256 timestamp
    );

    // ============ Errors ============

    error EmptyHandles();
    error EmptyContractAddresses();
    error MaxDecryptionRequestBitSizeExceeded(uint256 max, uint256 actual);
    error InvalidUserSignature(bytes signature);
    error RequestNotFound(uint256 requestId);
    error InvalidDurationDays();
    error StartTimestampInFuture(uint256 blockTimestamp, uint256 startTimestamp);
    error RequestExpired(uint256 blockTimestamp, uint256 expiryTimestamp);
    error HandleChainIdMismatch(bytes32 handle, uint256 handleChainId, uint256 expectedChainId);

    // ============ Structs ============

    /**
     * @notice User decryption request verification structure for EIP-712
     */
    struct UserDecryptRequestVerification {
        bytes publicKey;
        address[] contractAddresses;
        uint256 startTimestamp;
        uint256 durationDays;
        bytes extraData;
    }

    /**
     * @notice Request validity parameters
     */
    struct RequestValidity {
        uint256 startTimestamp;
        uint256 durationDays;
    }

    /**
     * @notice Stored request metadata
     */
    struct DecryptionRequest {
        bytes32[] handles;
        address userAddress;
        uint256 chainId;
        uint256 fee;
        uint256 timestamp;
        bool isPublic;
    }

    // ============ Constants ============

    IGatewayConfig private constant GATEWAY_CONFIG = IGatewayConfig(gatewayConfigAddress);

    uint256 internal constant MAX_DECRYPTION_REQUEST_BITS = 2048;
    uint16 internal constant MAX_DURATION_DAYS = 365;

    bytes32 private constant DOMAIN_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    string private constant EIP712_USER_DECRYPT_REQUEST_TYPE =
        "UserDecryptRequestVerification(bytes publicKey,address[] contractAddresses,uint256 startTimestamp,"
        "uint256 durationDays,bytes extraData)";

    bytes32 private constant EIP712_USER_DECRYPT_REQUEST_TYPE_HASH = 
        keccak256(bytes(EIP712_USER_DECRYPT_REQUEST_TYPE));

    string private constant CONTRACT_NAME = "DecryptionRegistry";
    uint256 private constant MAJOR_VERSION = 2;
    uint256 private constant MINOR_VERSION = 0;
    uint256 private constant PATCH_VERSION = 0;

    uint64 private constant REINITIALIZER_VERSION = 1;

    // Request ID prefixes for uniqueness
    uint256 private constant PUBLIC_DECRYPT_PREFIX = 0x01 << 248;
    uint256 private constant USER_DECRYPT_PREFIX = 0x02 << 248;

    // ============ Storage ============

    /// @custom:storage-location erc7201:fhevm_gateway.storage.DecryptionRegistry
    struct DecryptionRegistryStorage {
        uint256 publicDecryptionCounter;
        uint256 userDecryptionCounter;
        mapping(uint256 requestId => DecryptionRequest request) requests;
    }

    bytes32 private constant STORAGE_LOCATION =
        0x8a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a00;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initialization ============

    /// @custom:oz-upgrades-validate-as-initializer
    function initializeFromEmptyProxy() public virtual onlyFromEmptyProxy reinitializer(REINITIALIZER_VERSION) {
        __EIP712_init(CONTRACT_NAME, "1");
        __Pausable_init();
    }

    // ============ External Functions ============

    /**
     * @notice Register a user decryption request.
     * @dev KMS nodes will observe this event and compute decryption shares.
     *      The Relayer polls KMS APIs to collect shares and returns them to the user.
     * @param handles Ciphertext handles to decrypt
     * @param contractAddresses Contracts that have ACL access to the handles
     * @param publicKey User's public key for re-encrypting the shares
     * @param signature User's EIP-712 signature authorizing this request
     * @param extraData Additional metadata (version info, etc.)
     * @return requestId Unique identifier for this request
     */
    function requestUserDecryption(
        bytes32[] calldata handles,
        address[] calldata contractAddresses,
        bytes calldata publicKey,
        bytes calldata signature,
        bytes calldata extraData
    ) external payable whenNotPaused returns (uint256 requestId) {
        if (handles.length == 0) revert EmptyHandles();
        if (contractAddresses.length == 0) revert EmptyContractAddresses();

        // Extract chain ID from first handle and validate all handles
        uint256 chainId = HandleOps.extractChainId(handles[0]);
        _validateHandles(handles, chainId);

        // Verify user signature
        _verifyUserSignature(
            publicKey,
            contractAddresses,
            signature,
            chainId,
            extraData
        );

        DecryptionRegistryStorage storage $ = _getStorage();

        $.userDecryptionCounter++;
        requestId = USER_DECRYPT_PREFIX | $.userDecryptionCounter;

        // Collect fee
        uint256 fee = _collectUserDecryptionFee(msg.sender);

        // Store request metadata
        $.requests[requestId] = DecryptionRequest({
            handles: handles,
            userAddress: msg.sender,
            chainId: chainId,
            fee: fee,
            timestamp: block.timestamp,
            isPublic: false
        });

        emit UserDecryptionRequested(
            requestId,
            handles,
            contractAddresses,
            msg.sender,
            publicKey,
            signature,
            chainId,
            block.timestamp
        );
    }

    /**
     * @notice Register a public decryption request.
     * @dev KMS nodes will observe this event and compute the plaintext.
     *      Results are verified on-chain via KMSVerifier when used.
     * @param handles Ciphertext handles to decrypt
     * @param extraData Additional metadata
     * @return requestId Unique identifier for this request
     */
    function requestPublicDecryption(
        bytes32[] calldata handles,
        bytes calldata extraData
    ) external payable whenNotPaused returns (uint256 requestId) {
        if (handles.length == 0) revert EmptyHandles();

        // Extract chain ID from first handle and validate all handles
        uint256 chainId = HandleOps.extractChainId(handles[0]);
        _validateHandles(handles, chainId);

        DecryptionRegistryStorage storage $ = _getStorage();

        $.publicDecryptionCounter++;
        requestId = PUBLIC_DECRYPT_PREFIX | $.publicDecryptionCounter;

        // Collect fee
        uint256 fee = _collectPublicDecryptionFee(msg.sender);

        // Store request metadata
        $.requests[requestId] = DecryptionRequest({
            handles: handles,
            userAddress: msg.sender,
            chainId: chainId,
            fee: fee,
            timestamp: block.timestamp,
            isPublic: true
        });

        emit PublicDecryptionRequested(
            requestId,
            handles,
            chainId,
            block.timestamp
        );

        // Silence unused variable warning
        extraData;
    }

    /**
     * @notice Get request information by ID.
     */
    function getRequest(uint256 requestId) external view returns (
        bytes32[] memory handles,
        address userAddress,
        uint256 chainId,
        uint256 fee,
        uint256 timestamp,
        bool isPublic
    ) {
        DecryptionRegistryStorage storage $ = _getStorage();
        DecryptionRequest storage req = $.requests[requestId];
        
        if (req.timestamp == 0) revert RequestNotFound(requestId);

        return (req.handles, req.userAddress, req.chainId, req.fee, req.timestamp, req.isPublic);
    }

    /**
     * @notice Get request counters.
     */
    function getRequestCounts() external view returns (uint256 publicCount, uint256 userCount) {
        DecryptionRegistryStorage storage $ = _getStorage();
        return ($.publicDecryptionCounter, $.userDecryptionCounter);
    }

    /**
     * @notice Get the version string.
     */
    function getVersion() external pure returns (string memory) {
        return string(
            abi.encodePacked(
                CONTRACT_NAME,
                " v",
                Strings.toString(MAJOR_VERSION),
                ".",
                Strings.toString(MINOR_VERSION),
                ".",
                Strings.toString(PATCH_VERSION)
            )
        );
    }

    // ============ Internal Functions ============

    function _validateHandles(bytes32[] calldata handles, uint256 expectedChainId) internal pure {
        uint256 totalBits = 0;

        for (uint256 i = 0; i < handles.length; i++) {
            bytes32 handle = handles[i];
            
            // Verify chain ID matches
            uint256 handleChainId = HandleOps.extractChainId(handle);
            if (handleChainId != expectedChainId) {
                revert HandleChainIdMismatch(handle, handleChainId, expectedChainId);
            }

            // Extract FHE type and accumulate bit size
            FheType fheType = HandleOps.extractFheType(handle);
            totalBits += FHETypeBitSizes.getBitSize(fheType);
        }

        if (totalBits > MAX_DECRYPTION_REQUEST_BITS) {
            revert MaxDecryptionRequestBitSizeExceeded(MAX_DECRYPTION_REQUEST_BITS, totalBits);
        }
    }

    function _verifyUserSignature(
        bytes calldata publicKey,
        address[] calldata contractAddresses,
        bytes calldata signature,
        uint256 chainId,
        bytes calldata extraData
    ) internal view {
        // For V2, we use a simplified signature that doesn't require validity params
        // The signature covers: publicKey, contractAddresses, extraData
        UserDecryptRequestVerification memory verification = UserDecryptRequestVerification({
            publicKey: publicKey,
            contractAddresses: contractAddresses,
            startTimestamp: block.timestamp,
            durationDays: 1,
            extraData: extraData
        });

        bytes32 structHash = keccak256(
            abi.encode(
                EIP712_USER_DECRYPT_REQUEST_TYPE_HASH,
                keccak256(verification.publicKey),
                keccak256(abi.encodePacked(verification.contractAddresses)),
                verification.startTimestamp,
                verification.durationDays,
                keccak256(abi.encodePacked(verification.extraData))
            )
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPE_HASH, _EIP712NameHash(), _EIP712VersionHash(), chainId, address(this))
        );

        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        address signer = ECDSA.recover(digest, signature);

        if (signer != msg.sender) {
            revert InvalidUserSignature(signature);
        }
    }

    function _authorizeUpgrade(address _newImplementation) internal virtual override onlyGatewayOwner {}

    function _getStorage() internal pure returns (DecryptionRegistryStorage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
}
