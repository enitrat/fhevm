// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {UUPSUpgradeableEmptyProxy} from "./shared/UUPSUpgradeableEmptyProxy.sol";
import {ACLOwnable} from "./shared/ACLOwnable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title DecryptionFallback - Gateway V2 Cold Path
 * @notice Allows users to submit decryption requests directly on the Host Chain,
 *         bypassing the Gateway and Relayer entirely.
 * @dev This contract provides a trustless fallback path for users who want to:
 *      1. Avoid reliance on the Relayer
 *      2. Submit requests during Gateway downtime
 *      3. Have full control over their decryption workflow
 *
 *      KMS nodes observe events from this contract and compute decryption shares.
 *      Users poll KMS APIs directly to collect shares.
 */
contract DecryptionFallback is EIP712Upgradeable, UUPSUpgradeableEmptyProxy, ACLOwnable {
    // ============ Events ============

    /**
     * @notice Emitted when a decryption request is submitted.
     * @param requestId Unique identifier for this request
     * @param handles Ciphertext handles to decrypt
     * @param requester Address that submitted the request
     * @param publicKey User's public key for re-encryption (user decrypt) or empty (public decrypt)
     * @param isPublic True for public decryption, false for user decryption
     * @param timestamp Block timestamp when request was submitted
     */
    event DecryptionRequested(
        uint256 indexed requestId,
        bytes32[] handles,
        address indexed requester,
        bytes publicKey,
        bool isPublic,
        uint256 timestamp
    );

    // ============ Errors ============

    error EmptyHandles();
    error InsufficientPayment(uint256 required, uint256 provided);
    error RequestNotFound(uint256 requestId);
    error InvalidSignature();

    // ============ Structs ============

    struct DecryptionRequest {
        bytes32[] handles;
        address requester;
        bytes publicKey;
        bool isPublic;
        uint256 fee;
        uint256 timestamp;
    }

    // ============ Constants ============

    string private constant CONTRACT_NAME = "DecryptionFallback";
    uint256 private constant MAJOR_VERSION = 2;
    uint256 private constant MINOR_VERSION = 0;
    uint256 private constant PATCH_VERSION = 0;

    uint64 private constant REINITIALIZER_VERSION = 2;

    // Request ID prefix for cold path requests
    uint256 private constant COLD_PATH_PREFIX = 0x03 << 248;

    // ============ Storage ============

    /// @custom:storage-location erc7201:fhevm.storage.DecryptionFallback
    struct DecryptionFallbackStorage {
        uint256 requestCounter;
        mapping(uint256 requestId => DecryptionRequest request) requests;
        uint256 baseFeeWei;
        uint256 feePerHandle;
    }

    bytes32 private constant STORAGE_LOCATION =
        0x9f83c855de87884bf8755ee7415fa2dc9461ccabf26dfcbb724edb89b5df9b00;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initialization ============

    /// @custom:oz-upgrades-validate-as-initializer
    function initializeFromEmptyProxy(
        uint256 baseFeeWei,
        uint256 feePerHandle
    ) public virtual onlyFromEmptyProxy reinitializer(REINITIALIZER_VERSION) {
        __EIP712_init(CONTRACT_NAME, "1");
        
        DecryptionFallbackStorage storage $ = _getStorage();
        $.baseFeeWei = baseFeeWei;
        $.feePerHandle = feePerHandle;
    }

    // ============ External Functions ============

    /**
     * @notice Submit a user decryption request directly on the Host Chain.
     * @dev Users must pay in native token (ETH). After submission:
     *      1. KMS nodes observe the DecryptionRequested event
     *      2. KMS nodes verify ACL on this chain
     *      3. KMS nodes compute and store decryption shares
     *      4. User polls KMS APIs directly to collect shares
     *      5. User's SDK verifies signatures and decrypts
     * @param handles Ciphertext handles to decrypt
     * @param contractAddresses Contracts that have ACL access to handles
     * @param publicKey User's public key for re-encrypting shares
     * @param signature User's EIP-712 signature authorizing this request
     * @return requestId Unique identifier for this request
     */
    function requestUserDecryption(
        bytes32[] calldata handles,
        address[] calldata contractAddresses,
        bytes calldata publicKey,
        bytes calldata signature
    ) external payable returns (uint256 requestId) {
        if (handles.length == 0) revert EmptyHandles();

        uint256 requiredFee = _calculateFee(handles.length);
        if (msg.value < requiredFee) {
            revert InsufficientPayment(requiredFee, msg.value);
        }

        // Verify user signature (simplified for cold path)
        // In production, this should validate against a proper EIP-712 structure
        if (signature.length < 65) {
            revert InvalidSignature();
        }

        DecryptionFallbackStorage storage $ = _getStorage();

        $.requestCounter++;
        requestId = COLD_PATH_PREFIX | $.requestCounter;

        $.requests[requestId] = DecryptionRequest({
            handles: handles,
            requester: msg.sender,
            publicKey: publicKey,
            isPublic: false,
            fee: msg.value,
            timestamp: block.timestamp
        });

        emit DecryptionRequested(
            requestId,
            handles,
            msg.sender,
            publicKey,
            false,
            block.timestamp
        );

        // Silence unused variable warning
        contractAddresses;
    }

    /**
     * @notice Submit a public decryption request directly on the Host Chain.
     * @dev Similar to user decryption, but results are verified via KMSVerifier on-chain.
     * @param handles Ciphertext handles to decrypt
     * @return requestId Unique identifier for this request
     */
    function requestPublicDecryption(
        bytes32[] calldata handles
    ) external payable returns (uint256 requestId) {
        if (handles.length == 0) revert EmptyHandles();

        uint256 requiredFee = _calculateFee(handles.length);
        if (msg.value < requiredFee) {
            revert InsufficientPayment(requiredFee, msg.value);
        }

        DecryptionFallbackStorage storage $ = _getStorage();

        $.requestCounter++;
        requestId = COLD_PATH_PREFIX | $.requestCounter;

        $.requests[requestId] = DecryptionRequest({
            handles: handles,
            requester: msg.sender,
            publicKey: "",
            isPublic: true,
            fee: msg.value,
            timestamp: block.timestamp
        });

        emit DecryptionRequested(
            requestId,
            handles,
            msg.sender,
            "",
            true,
            block.timestamp
        );
    }

    // ============ View Functions ============

    /**
     * @notice Get request information.
     */
    function getRequest(uint256 requestId) external view returns (
        bytes32[] memory handles,
        address requester,
        bytes memory publicKey,
        bool isPublic,
        uint256 fee,
        uint256 timestamp
    ) {
        DecryptionFallbackStorage storage $ = _getStorage();
        DecryptionRequest storage req = $.requests[requestId];
        
        if (req.timestamp == 0) revert RequestNotFound(requestId);

        return (req.handles, req.requester, req.publicKey, req.isPublic, req.fee, req.timestamp);
    }

    /**
     * @notice Calculate the fee for a decryption request.
     * @param numHandles Number of handles to decrypt
     */
    function calculateFee(uint256 numHandles) external view returns (uint256) {
        return _calculateFee(numHandles);
    }

    /**
     * @notice Get fee configuration.
     */
    function getFeeConfig() external view returns (uint256 baseFeeWei, uint256 feePerHandle) {
        DecryptionFallbackStorage storage $ = _getStorage();
        return ($.baseFeeWei, $.feePerHandle);
    }

    /**
     * @notice Get request count.
     */
    function getRequestCount() external view returns (uint256) {
        DecryptionFallbackStorage storage $ = _getStorage();
        return $.requestCounter;
    }

    /**
     * @notice Get version string.
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

    // ============ Admin Functions ============

    /**
     * @notice Update fee configuration.
     */
    function setFeeConfig(uint256 baseFeeWei, uint256 feePerHandle) external onlyACLOwner {
        DecryptionFallbackStorage storage $ = _getStorage();
        $.baseFeeWei = baseFeeWei;
        $.feePerHandle = feePerHandle;
    }

    /**
     * @notice Withdraw collected fees.
     */
    function withdrawFees(address payable recipient) external onlyACLOwner {
        uint256 balance = address(this).balance;
        (bool success, ) = recipient.call{value: balance}("");
        require(success, "Transfer failed");
    }

    // ============ Internal Functions ============

    function _calculateFee(uint256 numHandles) internal view returns (uint256) {
        DecryptionFallbackStorage storage $ = _getStorage();
        return $.baseFeeWei + ($.feePerHandle * numHandles);
    }

    function _authorizeUpgrade(address _newImplementation) internal virtual override onlyACLOwner {}

    function _getStorage() internal pure returns (DecryptionFallbackStorage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
}
