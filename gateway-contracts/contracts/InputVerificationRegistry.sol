// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import { gatewayConfigAddress } from "../addresses/GatewayAddresses.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IGatewayConfig } from "./interfaces/IGatewayConfig.sol";
import { UUPSUpgradeableEmptyProxy } from "./shared/UUPSUpgradeableEmptyProxy.sol";
import { GatewayConfigChecks } from "./shared/GatewayConfigChecks.sol";
import { Pausable } from "./shared/Pausable.sol";
import { GatewayOwnable } from "./shared/GatewayOwnable.sol";
import { ProtocolPaymentUtils } from "./shared/ProtocolPaymentUtils.sol";

/**
 * @title InputVerificationRegistry - Gateway V2
 * @notice Simplified input verification registry that only handles request registration.
 * @dev In V2, coprocessors respond via HTTP API instead of on-chain transactions.
 *      This contract only registers requests and emits events for coprocessors to observe.
 *      Response handling and consensus aggregation happens off-chain in the Relayer.
 */
contract InputVerificationRegistry is
    UUPSUpgradeableEmptyProxy,
    GatewayOwnable,
    GatewayConfigChecks,
    ProtocolPaymentUtils,
    Pausable
{
    // ============ Events ============

    /**
     * @notice Emitted when an input verification request is registered.
     * @param requestId Unique identifier for this request
     * @param commitment Hash of the full payload (ciphertext + ZKPoK) for integrity verification
     * @param userAddress Address of the user submitting the input
     * @param contractChainId Chain ID of the target contract
     * @param contractAddress Address of the target contract
     * @param timestamp Block timestamp when request was registered
     */
    event InputVerificationRegistered(
        uint256 indexed requestId,
        bytes32 commitment,
        address indexed userAddress,
        uint256 contractChainId,
        address contractAddress,
        uint256 timestamp
    );

    // ============ Errors ============

    /// @notice Returned if the commitment is zero
    error InvalidCommitment();

    /// @notice Returned if the request does not exist
    error RequestNotFound(uint256 requestId);

    // ============ Constants ============

    /**
     * @notice The address of the GatewayConfig contract for protocol state calls.
     */
    IGatewayConfig private constant GATEWAY_CONFIG = IGatewayConfig(gatewayConfigAddress);

    string private constant CONTRACT_NAME = "InputVerificationRegistry";
    uint256 private constant MAJOR_VERSION = 2;
    uint256 private constant MINOR_VERSION = 0;
    uint256 private constant PATCH_VERSION = 0;

    uint64 private constant REINITIALIZER_VERSION = 1;

    // ============ Storage ============

    /**
     * @notice Request metadata stored for dispute resolution
     */
    struct RequestInfo {
        bytes32 commitment;
        address userAddress;
        uint256 contractChainId;
        address contractAddress;
        uint256 fee;
        uint256 timestamp;
    }

    /// @custom:storage-location erc7201:fhevm_gateway.storage.InputVerificationRegistry
    struct InputVerificationRegistryStorage {
        /// @notice Counter for generating unique request IDs
        uint256 requestCounter;
        /// @notice Request metadata by ID
        mapping(uint256 requestId => RequestInfo info) requests;
    }

    bytes32 private constant STORAGE_LOCATION =
        0x9a1d3d7b6c4e5f8a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f00;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initialization ============

    /// @custom:oz-upgrades-validate-as-initializer
    function initializeFromEmptyProxy() public virtual onlyFromEmptyProxy reinitializer(REINITIALIZER_VERSION) {
        __Pausable_init();
    }

    // ============ External Functions ============

    /**
     * @notice Register an input verification request.
     * @dev The full payload is NOT stored on-chain to save gas. Only the commitment (hash) is stored.
     *      The Relayer sends the full payload directly to coprocessors, who verify it matches the commitment.
     * @param commitment Hash of the full payload (ciphertext + ZKPoK)
     * @param contractChainId Chain ID of the target contract
     * @param contractAddress Address of the target contract
     * @return requestId Unique identifier for this request
     */
    function registerInputVerification(
        bytes32 commitment,
        uint256 contractChainId,
        address contractAddress
    ) external payable whenNotPaused onlyRegisteredHostChain(contractChainId) returns (uint256 requestId) {
        if (commitment == bytes32(0)) {
            revert InvalidCommitment();
        }

        InputVerificationRegistryStorage storage $ = _getStorage();

        $.requestCounter++;
        requestId = $.requestCounter;

        // Collect the fee from the transaction sender
        uint256 fee = _collectInputVerificationFee(msg.sender);

        // Store request metadata for potential dispute resolution
        $.requests[requestId] = RequestInfo({
            commitment: commitment,
            userAddress: msg.sender,
            contractChainId: contractChainId,
            contractAddress: contractAddress,
            fee: fee,
            timestamp: block.timestamp
        });

        emit InputVerificationRegistered(
            requestId,
            commitment,
            msg.sender,
            contractChainId,
            contractAddress,
            block.timestamp
        );
    }

    /**
     * @notice Get request information by ID.
     * @param requestId The request ID
     * @return commitment The commitment hash
     * @return userAddress The user who submitted the request
     * @return fee The fee paid
     * @return timestamp When the request was registered
     */
    function getRequest(uint256 requestId) external view returns (
        bytes32 commitment,
        address userAddress,
        uint256 fee,
        uint256 timestamp
    ) {
        InputVerificationRegistryStorage storage $ = _getStorage();
        RequestInfo storage info = $.requests[requestId];
        
        if (info.timestamp == 0) {
            revert RequestNotFound(requestId);
        }

        return (info.commitment, info.userAddress, info.fee, info.timestamp);
    }

    /**
     * @notice Get the current request counter.
     * @return The number of requests registered
     */
    function getRequestCount() external view returns (uint256) {
        InputVerificationRegistryStorage storage $ = _getStorage();
        return $.requestCounter;
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

    function _authorizeUpgrade(address _newImplementation) internal virtual override onlyGatewayOwner {}

    function _getStorage() internal pure returns (InputVerificationRegistryStorage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
}
