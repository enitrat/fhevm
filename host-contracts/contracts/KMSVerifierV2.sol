// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {UUPSUpgradeableEmptyProxy} from "./shared/UUPSUpgradeableEmptyProxy.sol";
import {EIP712UpgradeableCrossChain} from "./shared/EIP712UpgradeableCrossChain.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ACLOwnable} from "./shared/ACLOwnable.sol";

/**
 * @title   KMSVerifierV2
 * @notice  KMSVerifier V2 with epoch grace period support for Gateway V2.
 * @dev     During MPC context transitions, signatures from both old and new signer sets are valid
 *          for a configurable grace period, ensuring in-flight requests can complete.
 */
contract KMSVerifierV2 is UUPSUpgradeableEmptyProxy, EIP712UpgradeableCrossChain, ACLOwnable {
    // ============ Errors ============

    /// @notice Returned if the KMS signer to add is already a signer.
    error KMSAlreadySigner();

    /// @notice Returned if the recovered KMS signer is not a valid KMS signer.
    error KMSInvalidSigner(address invalidSigner);

    /// @notice Returned if the deserializing of the decryption proof fails.
    error DeserializingDecryptionProofFail();

    /// @notice Returned if the decryption proof is empty.
    error EmptyDecryptionProof();

    /// @notice Returned if the KMS signer to add is the null address.
    error KMSSignerNull();

    /// @notice Returned if the number of signatures is inferior to the threshold.
    error KMSSignatureThresholdNotReached(uint256 numSignatures);

    /// @notice Returned if the number of signatures is equal to 0.
    error KMSZeroSignature();

    /// @notice Returned if the signers set is empty.
    error SignersSetIsEmpty();

    /// @notice Returned if the chosen threshold is null.
    error ThresholdIsNull();

    /// @notice Threshold is above number of signers.
    error ThresholdIsAboveNumberOfSigners();

    /// @notice Grace period is below minimum.
    error GracePeriodBelowMinimum(uint256 provided, uint256 minimum);

    // ============ Events ============

    /// @notice Emitted when a context is set or changed.
    event NewContextSet(address[] newKmsSignersSet, uint256 newThreshold, uint256 transitionBlock);

    /// @notice Emitted when grace period is updated.
    event GracePeriodUpdated(uint256 newGracePeriod);

    // ============ Structs ============

    /// @notice The typed data structure for EIP712 signature validation in public decryption responses.
    struct PublicDecryptVerification {
        bytes32[] ctHandles;
        bytes decryptedResult;
        bytes extraData;
    }

    // ============ Constants ============

    string public constant EIP712_PUBLIC_DECRYPT_TYPE =
        "PublicDecryptVerification(bytes32[] ctHandles,bytes decryptedResult,bytes extraData)";

    bytes32 public constant DECRYPTION_RESULT_TYPEHASH = keccak256(bytes(EIP712_PUBLIC_DECRYPT_TYPE));

    string private constant CONTRACT_NAME = "KMSVerifierV2";
    string private constant CONTRACT_NAME_SOURCE = "Decryption";

    uint256 private constant MAJOR_VERSION = 2;
    uint256 private constant MINOR_VERSION = 0;
    uint256 private constant PATCH_VERSION = 0;

    uint64 private constant REINITIALIZER_VERSION = 3;

    /// @notice Minimum allowed grace period (50 blocks)
    uint256 public constant MIN_GRACE_PERIOD = 50;

    /// @notice Default grace period (100 blocks)
    uint256 public constant DEFAULT_GRACE_PERIOD = 100;

    // ============ Storage ============

    /// @custom:storage-location erc7201:fhevm.storage.KMSVerifierV2
    struct KMSVerifierV2Storage {
        // Current context
        mapping(address => bool) isSigner;
        address[] signers;
        uint256 threshold;
        
        // Previous context (for grace period)
        mapping(address => bool) isPreviousSigner;
        address[] previousSigners;
        uint256 previousThreshold;
        
        // Grace period configuration
        uint256 contextTransitionBlock;
        uint256 gracePeriodBlocks;
        
        // Epoch tracking
        uint256 epochId;
    }

    bytes32 private constant STORAGE_LOCATION =
        0x8e82b744ce86773af8644dd7304fa1dc9350ccabf16cfcaa614ddb78b4ce8901;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initialization ============

    /// @custom:oz-upgrades-validate-as-initializer
    function initializeFromEmptyProxy(
        address verifyingContractSource,
        uint64 chainIDSource,
        address[] calldata initialSigners,
        uint256 initialThreshold
    ) public virtual onlyFromEmptyProxy reinitializer(REINITIALIZER_VERSION) {
        __EIP712_init(CONTRACT_NAME_SOURCE, "1", verifyingContractSource, chainIDSource);
        
        KMSVerifierV2Storage storage $ = _getStorage();
        $.gracePeriodBlocks = DEFAULT_GRACE_PERIOD;
        $.epochId = 1;
        
        _setSigners(initialSigners, initialThreshold);
    }

    // ============ External Functions ============

    /**
     * @notice Sets a new context (new signer set and threshold).
     * @dev Stores the previous context for grace period support.
     *      During the grace period, signatures from both contexts are valid.
     * @param newSignersSet The new set of signers
     * @param newThreshold The new threshold
     */
    function defineNewContext(address[] memory newSignersSet, uint256 newThreshold) public virtual onlyACLOwner {
        if (newSignersSet.length == 0) {
            revert SignersSetIsEmpty();
        }

        KMSVerifierV2Storage storage $ = _getStorage();

        // Store current context as previous (for grace period)
        _storePreviousContext();

        // Clear current signers
        uint256 oldLen = $.signers.length;
        for (uint256 i = 0; i < oldLen; i++) {
            $.isSigner[$.signers[i]] = false;
        }
        delete $.signers;

        // Set new signers
        _setSigners(newSignersSet, newThreshold);

        // Record transition
        $.contextTransitionBlock = block.number;
        $.epochId++;

        emit NewContextSet(newSignersSet, newThreshold, block.number);
    }

    /**
     * @notice Sets the threshold.
     * @param threshold The new threshold
     */
    function setThreshold(uint256 threshold) public virtual onlyACLOwner {
        _setThreshold(threshold);
        KMSVerifierV2Storage storage $ = _getStorage();
        emit NewContextSet($.signers, threshold, $.contextTransitionBlock);
    }

    /**
     * @notice Sets the grace period duration.
     * @param newGracePeriod New grace period in blocks
     */
    function setGracePeriod(uint256 newGracePeriod) public virtual onlyACLOwner {
        if (newGracePeriod < MIN_GRACE_PERIOD) {
            revert GracePeriodBelowMinimum(newGracePeriod, MIN_GRACE_PERIOD);
        }
        KMSVerifierV2Storage storage $ = _getStorage();
        $.gracePeriodBlocks = newGracePeriod;
        emit GracePeriodUpdated(newGracePeriod);
    }

    /**
     * @notice Verifies signatures for public decryption.
     * @param handlesList The handles that were decrypted
     * @param decryptedResult The decrypted value
     * @param decryptionProof Packed proof: numSigners (1 byte) + signatures (65 bytes each) + extraData
     * @return isVerified True if threshold valid signatures found
     */
    function verifyDecryptionEIP712KMSSignatures(
        bytes32[] memory handlesList,
        bytes memory decryptedResult,
        bytes memory decryptionProof
    ) public virtual returns (bool) {
        if (decryptionProof.length == 0) {
            revert EmptyDecryptionProof();
        }

        uint256 numSigners = uint256(uint8(decryptionProof[0]));
        uint256 extraDataOffset = 1 + 65 * numSigners;

        if (decryptionProof.length < extraDataOffset) {
            revert DeserializingDecryptionProofFail();
        }

        bytes[] memory signatures = new bytes[](numSigners);
        for (uint256 j = 0; j < numSigners; j++) {
            signatures[j] = new bytes(65);
            for (uint256 i = 0; i < 65; i++) {
                signatures[j][i] = decryptionProof[1 + 65 * j + i];
            }
        }

        uint256 extraDataSize = decryptionProof.length - extraDataOffset;
        bytes memory extraData = new bytes(extraDataSize);
        for (uint i = 0; i < extraDataSize; i++) {
            extraData[i] = decryptionProof[extraDataOffset + i];
        }

        PublicDecryptVerification memory verification = PublicDecryptVerification(
            handlesList,
            decryptedResult,
            extraData
        );
        bytes32 digest = _hashDecryptionResult(verification);

        return _verifySignaturesDigest(digest, signatures);
    }

    // ============ View Functions ============

    /**
     * @notice Check if an address is a valid signer (current OR previous during grace period).
     * @param account The address to check
     * @return True if the address is a valid signer
     */
    function isValidSigner(address account) public view virtual returns (bool) {
        KMSVerifierV2Storage storage $ = _getStorage();
        
        // Check current signers
        if ($.isSigner[account]) return true;
        
        // During grace period, also accept previous signers
        if (_isInGracePeriod()) {
            return $.isPreviousSigner[account];
        }
        
        return false;
    }

    /**
     * @notice Check if currently in grace period.
     */
    function isInGracePeriod() public view returns (bool) {
        return _isInGracePeriod();
    }

    /**
     * @notice Get the effective threshold (considers grace period).
     * @dev During grace period, returns minimum of both thresholds.
     */
    function getEffectiveThreshold() public view virtual returns (uint256) {
        KMSVerifierV2Storage storage $ = _getStorage();
        
        if (_isInGracePeriod() && $.previousThreshold > 0) {
            return $.previousThreshold < $.threshold ? $.previousThreshold : $.threshold;
        }
        
        return $.threshold;
    }

    /**
     * @notice Returns the current signer set.
     */
    function getKmsSigners() public view virtual returns (address[] memory) {
        KMSVerifierV2Storage storage $ = _getStorage();
        return $.signers;
    }

    /**
     * @notice Returns the previous signer set (if in grace period).
     */
    function getPreviousSigners() public view virtual returns (address[] memory) {
        KMSVerifierV2Storage storage $ = _getStorage();
        return $.previousSigners;
    }

    /**
     * @notice Get the current threshold.
     */
    function getThreshold() public view virtual returns (uint256) {
        KMSVerifierV2Storage storage $ = _getStorage();
        return $.threshold;
    }

    /**
     * @notice Get the grace period configuration.
     */
    function getGracePeriodConfig() public view returns (
        uint256 gracePeriodBlocks,
        uint256 contextTransitionBlock,
        uint256 blocksRemaining
    ) {
        KMSVerifierV2Storage storage $ = _getStorage();
        gracePeriodBlocks = $.gracePeriodBlocks;
        contextTransitionBlock = $.contextTransitionBlock;
        
        if (_isInGracePeriod()) {
            blocksRemaining = ($.contextTransitionBlock + $.gracePeriodBlocks) - block.number;
        }
    }

    /**
     * @notice Get the current epoch ID.
     */
    function getEpochId() public view returns (uint256) {
        KMSVerifierV2Storage storage $ = _getStorage();
        return $.epochId;
    }

    /**
     * @notice Legacy compatibility: check if address is current signer.
     */
    function isSigner(address account) public view virtual returns (bool) {
        KMSVerifierV2Storage storage $ = _getStorage();
        return $.isSigner[account];
    }

    /**
     * @notice Get the version string.
     */
    function getVersion() external pure virtual returns (string memory) {
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

    function _isInGracePeriod() internal view returns (bool) {
        KMSVerifierV2Storage storage $ = _getStorage();
        return block.number <= $.contextTransitionBlock + $.gracePeriodBlocks;
    }

    function _storePreviousContext() internal {
        KMSVerifierV2Storage storage $ = _getStorage();

        // Clear previous context
        uint256 prevLen = $.previousSigners.length;
        for (uint256 i = 0; i < prevLen; i++) {
            $.isPreviousSigner[$.previousSigners[i]] = false;
        }
        delete $.previousSigners;

        // Copy current to previous
        uint256 currentLen = $.signers.length;
        for (uint256 i = 0; i < currentLen; i++) {
            address signer = $.signers[i];
            $.isPreviousSigner[signer] = true;
            $.previousSigners.push(signer);
        }
        $.previousThreshold = $.threshold;
    }

    function _setSigners(address[] memory newSignersSet, uint256 newThreshold) internal {
        KMSVerifierV2Storage storage $ = _getStorage();

        for (uint256 i = 0; i < newSignersSet.length; i++) {
            address signer = newSignersSet[i];
            if (signer == address(0)) {
                revert KMSSignerNull();
            }
            if ($.isSigner[signer]) {
                revert KMSAlreadySigner();
            }
            $.isSigner[signer] = true;
            $.signers.push(signer);
        }

        _setThreshold(newThreshold);
    }

    function _setThreshold(uint256 threshold) internal virtual {
        if (threshold == 0) {
            revert ThresholdIsNull();
        }
        KMSVerifierV2Storage storage $ = _getStorage();
        if (threshold > $.signers.length) {
            revert ThresholdIsAboveNumberOfSigners();
        }
        $.threshold = threshold;
    }

    function _verifySignaturesDigest(bytes32 digest, bytes[] memory signatures) internal virtual returns (bool) {
        uint256 numSignatures = signatures.length;

        if (numSignatures == 0) {
            revert KMSZeroSignature();
        }

        uint256 threshold = getEffectiveThreshold();

        if (numSignatures < threshold) {
            revert KMSSignatureThresholdNotReached(numSignatures);
        }

        address[] memory recoveredSigners = new address[](numSignatures);
        uint256 uniqueValidCount;
        
        for (uint256 i = 0; i < numSignatures; i++) {
            address signerRecovered = _recoverSigner(digest, signatures[i]);
            
            // Use isValidSigner which checks both current and previous during grace period
            if (!isValidSigner(signerRecovered)) {
                revert KMSInvalidSigner(signerRecovered);
            }
            
            if (!_tload(signerRecovered)) {
                recoveredSigners[uniqueValidCount] = signerRecovered;
                uniqueValidCount++;
                _tstore(signerRecovered, 1);
            }
            
            if (uniqueValidCount >= threshold) {
                _cleanTransientHashMap(recoveredSigners, uniqueValidCount);
                return true;
            }
        }
        
        _cleanTransientHashMap(recoveredSigners, uniqueValidCount);
        return false;
    }

    function _cleanTransientHashMap(address[] memory keys, uint256 maxIndex) internal virtual {
        for (uint256 j = 0; j < maxIndex; j++) {
            _tstore(keys[j], 0);
        }
    }

    function _tstore(address location, uint256 value) internal virtual {
        assembly {
            tstore(location, value)
        }
    }

    function _tload(address location) internal view virtual returns (bool value) {
        assembly {
            value := tload(location)
        }
    }

    function _hashDecryptionResult(PublicDecryptVerification memory decRes) internal view virtual returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    DECRYPTION_RESULT_TYPEHASH,
                    keccak256(abi.encodePacked(decRes.ctHandles)),
                    keccak256(decRes.decryptedResult),
                    keccak256(abi.encodePacked(decRes.extraData))
                )
            )
        );
    }

    function _recoverSigner(bytes32 message, bytes memory signature) internal pure virtual returns (address) {
        return ECDSA.recover(message, signature);
    }

    function _authorizeUpgrade(address _newImplementation) internal virtual override onlyACLOwner {}

    function _getStorage() internal pure returns (KMSVerifierV2Storage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
}
