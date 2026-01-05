// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "@openzeppelin/foundry-upgrades/src/Upgrades.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {KMSVerifierV2} from "../../contracts/KMSVerifierV2.sol";
import {ACL} from "../../contracts/ACL.sol";
import {EmptyUUPSProxy} from "../../contracts/emptyProxy/EmptyUUPSProxy.sol";
import {ACLOwnable} from "../../contracts/shared/ACLOwnable.sol";
import {aclAdd} from "../../addresses/FHEVMHostAddresses.sol";

/**
 * @title KMSVerifierV2Test
 * @notice Tests for KMSVerifierV2 with epoch grace period support.
 */
contract KMSVerifierV2Test is Test {
    KMSVerifierV2 internal kmsVerifier;

    uint256 internal constant initialThreshold = 1;
    address internal constant verifyingContractSource = address(10000);
    address internal constant owner = address(456);

    // Signer private keys
    uint256 internal constant privateKeySigner0 = 0x022;
    uint256 internal constant privateKeySigner1 = 0x03;
    uint256 internal constant privateKeySigner2 = 0x04;
    uint256 internal constant privateKeySigner3 = 0x05;
    uint256 internal constant privateKeySigner4 = 0x06;
    
    // Additional signers for new context
    uint256 internal constant privateKeyNewSigner0 = 0x07;
    uint256 internal constant privateKeyNewSigner1 = 0x08;
    uint256 internal constant privateKeyNewSigner2 = 0x09;
    
    address[] internal activeSigners;
    mapping(address => uint256) internal signerPrivateKeys;
    
    address internal signer0;
    address internal signer1;
    address internal signer2;
    address internal signer3;
    address internal signer4;
    
    address internal newSigner0;
    address internal newSigner1;
    address internal newSigner2;

    address internal proxy;
    address internal implementation;

    // ============ Setup ============

    function setUp() public {
        _deployProxy();
        _deployAndEtchACL();
        _initializeSigners();
    }

    function _deployProxy() internal {
        proxy = UnsafeUpgrades.deployUUPSProxy(
            address(new EmptyUUPSProxy()),
            abi.encodeCall(EmptyUUPSProxy.initialize, ())
        );
    }

    function _deployAndEtchACL() internal {
        address _acl = address(new ACL());
        bytes memory code = _acl.code;
        vm.etch(aclAdd, code);
        vm.store(
            aclAdd,
            0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300,
            bytes32(uint256(uint160(owner)))
        );
    }

    function _initializeSigners() internal {
        signer0 = vm.addr(privateKeySigner0);
        signer1 = vm.addr(privateKeySigner1);
        signer2 = vm.addr(privateKeySigner2);
        signer3 = vm.addr(privateKeySigner3);
        signer4 = vm.addr(privateKeySigner4);
        
        newSigner0 = vm.addr(privateKeyNewSigner0);
        newSigner1 = vm.addr(privateKeyNewSigner1);
        newSigner2 = vm.addr(privateKeyNewSigner2);

        signerPrivateKeys[signer0] = privateKeySigner0;
        signerPrivateKeys[signer1] = privateKeySigner1;
        signerPrivateKeys[signer2] = privateKeySigner2;
        signerPrivateKeys[signer3] = privateKeySigner3;
        signerPrivateKeys[signer4] = privateKeySigner4;
        
        signerPrivateKeys[newSigner0] = privateKeyNewSigner0;
        signerPrivateKeys[newSigner1] = privateKeyNewSigner1;
        signerPrivateKeys[newSigner2] = privateKeyNewSigner2;
    }

    function _upgradeProxy(address[] memory signers) internal {
        implementation = address(new KMSVerifierV2());
        UnsafeUpgrades.upgradeProxy(
            proxy,
            implementation,
            abi.encodeCall(
                KMSVerifierV2.initializeFromEmptyProxy,
                (verifyingContractSource, uint64(block.chainid), signers, initialThreshold)
            ),
            owner
        );
        kmsVerifier = KMSVerifierV2(proxy);
    }

    function _upgradeProxyWithSigners(uint256 numberSigners) internal {
        assert(numberSigners > 0 && numberSigners < 6);

        if (numberSigners >= 1) activeSigners.push(signer0);
        if (numberSigners >= 2) activeSigners.push(signer1);
        if (numberSigners >= 3) activeSigners.push(signer2);
        if (numberSigners >= 4) activeSigners.push(signer3);
        if (numberSigners == 5) activeSigners.push(signer4);

        _upgradeProxy(activeSigners);
    }

    // ============ Helper Functions ============

    function _computeSignature(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory signature) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _computeDigest(
        bytes32[] memory handlesList,
        bytes memory decryptedResult,
        bytes memory extraData
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                kmsVerifier.DECRYPTION_RESULT_TYPEHASH(),
                keccak256(abi.encodePacked(handlesList)),
                keccak256(decryptedResult),
                keccak256(abi.encodePacked(extraData))
            )
        );

        bytes32 hashTypeData = MessageHashUtils.toTypedDataHash(_computeDomainSeparator(), structHash);
        return hashTypeData;
    }

    function _computeDomainSeparator() internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract, , ) = kmsVerifier
            .eip712Domain();

        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
    }

    function _generateMockHandlesList(uint256 numberHandles) internal pure returns (bytes32[] memory) {
        assert(numberHandles < 250);
        bytes32[] memory handlesList = new bytes32[](numberHandles);
        for (uint256 i = 0; i < numberHandles; i++) {
            handlesList[i] = bytes32(uint256(i + 1));
        }
        return handlesList;
    }

    function _createDecryptionProof(
        bytes[] memory signatures,
        bytes memory extraData
    ) internal pure returns (bytes memory) {
        bytes memory proof = abi.encodePacked(uint8(signatures.length));
        for (uint256 i = 0; i < signatures.length; i++) {
            proof = abi.encodePacked(proof, signatures[i]);
        }
        proof = abi.encodePacked(proof, extraData);
        return proof;
    }

    // ============ Basic Functionality Tests ============

    function test_PostProxyUpgradeCheck() public {
        _upgradeProxyWithSigners(3);
        assertEq(kmsVerifier.getVersion(), string(abi.encodePacked("KMSVerifierV2 v2.0.0")));
        assertEq(kmsVerifier.getThreshold(), initialThreshold);
        assertEq(kmsVerifier.getEpochId(), 1);
    }

    function test_DefaultGracePeriod() public {
        _upgradeProxyWithSigners(3);
        (uint256 gracePeriodBlocks, , ) = kmsVerifier.getGracePeriodConfig();
        assertEq(gracePeriodBlocks, 100); // DEFAULT_GRACE_PERIOD
    }

    function test_GetKmsSignersWorkAsExpected() public {
        _upgradeProxyWithSigners(3);
        address[] memory signers = kmsVerifier.getKmsSigners();
        assertEq(signers.length, 3);
        assertEq(signers[0], signer0);
        assertEq(signers[1], signer1);
        assertEq(signers[2], signer2);
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(kmsVerifier.isSigner(signers[i]));
            assertTrue(kmsVerifier.isValidSigner(signers[i]));
        }
    }

    // ============ Grace Period Tests ============

    function test_DefineNewContextStoresPreviousContext() public {
        _upgradeProxyWithSigners(3);
        
        // Define new context with different signers
        address[] memory newSigners = new address[](2);
        newSigners[0] = newSigner0;
        newSigners[1] = newSigner1;
        
        vm.prank(owner);
        kmsVerifier.defineNewContext(newSigners, 2);
        
        // Previous signers should be stored
        address[] memory prevSigners = kmsVerifier.getPreviousSigners();
        assertEq(prevSigners.length, 3);
        assertEq(prevSigners[0], signer0);
        assertEq(prevSigners[1], signer1);
        assertEq(prevSigners[2], signer2);
        
        // New signers should be current
        address[] memory currentSigners = kmsVerifier.getKmsSigners();
        assertEq(currentSigners.length, 2);
        assertEq(currentSigners[0], newSigner0);
        assertEq(currentSigners[1], newSigner1);
    }

    function test_GracePeriodActiveAfterContextTransition() public {
        _upgradeProxyWithSigners(3);
        uint256 transitionBlock = block.number;
        
        address[] memory newSigners = new address[](2);
        newSigners[0] = newSigner0;
        newSigners[1] = newSigner1;
        
        vm.prank(owner);
        kmsVerifier.defineNewContext(newSigners, 2);
        
        // Should be in grace period immediately after transition
        assertTrue(kmsVerifier.isInGracePeriod());
        
        // Check config
        (uint256 gracePeriodBlocks, uint256 contextTransitionBlock, uint256 blocksRemaining) = kmsVerifier.getGracePeriodConfig();
        assertEq(gracePeriodBlocks, 100);
        assertEq(contextTransitionBlock, transitionBlock);
        assertEq(blocksRemaining, 100);
    }

    function test_PreviousSignersValidDuringGracePeriod() public {
        _upgradeProxyWithSigners(3);
        
        address[] memory newSigners = new address[](2);
        newSigners[0] = newSigner0;
        newSigners[1] = newSigner1;
        
        vm.prank(owner);
        kmsVerifier.defineNewContext(newSigners, 2);
        
        // During grace period, both old and new signers should be valid
        assertTrue(kmsVerifier.isValidSigner(signer0)); // old signer
        assertTrue(kmsVerifier.isValidSigner(signer1)); // old signer
        assertTrue(kmsVerifier.isValidSigner(signer2)); // old signer
        assertTrue(kmsVerifier.isValidSigner(newSigner0)); // new signer
        assertTrue(kmsVerifier.isValidSigner(newSigner1)); // new signer
        
        // But isSigner only checks current
        assertFalse(kmsVerifier.isSigner(signer0)); // not current signer
        assertTrue(kmsVerifier.isSigner(newSigner0)); // is current signer
    }

    function test_PreviousSignersInvalidAfterGracePeriod() public {
        _upgradeProxyWithSigners(3);
        
        address[] memory newSigners = new address[](2);
        newSigners[0] = newSigner0;
        newSigners[1] = newSigner1;
        
        vm.prank(owner);
        kmsVerifier.defineNewContext(newSigners, 2);
        
        // Advance past grace period (100 blocks + 1)
        vm.roll(block.number + 101);
        
        assertFalse(kmsVerifier.isInGracePeriod());
        
        // Old signers should no longer be valid
        assertFalse(kmsVerifier.isValidSigner(signer0));
        assertFalse(kmsVerifier.isValidSigner(signer1));
        assertFalse(kmsVerifier.isValidSigner(signer2));
        
        // New signers still valid
        assertTrue(kmsVerifier.isValidSigner(newSigner0));
        assertTrue(kmsVerifier.isValidSigner(newSigner1));
    }

    function test_GracePeriodExpiresAtCorrectBlock() public {
        _upgradeProxyWithSigners(3);
        
        address[] memory newSigners = new address[](2);
        newSigners[0] = newSigner0;
        newSigners[1] = newSigner1;
        
        vm.prank(owner);
        kmsVerifier.defineNewContext(newSigners, 2);
        
        uint256 startBlock = block.number;
        
        // At exactly grace period end, should still be valid
        vm.roll(startBlock + 100);
        assertTrue(kmsVerifier.isInGracePeriod());
        assertTrue(kmsVerifier.isValidSigner(signer0));
        
        // One block later, grace period ends
        vm.roll(startBlock + 101);
        assertFalse(kmsVerifier.isInGracePeriod());
        assertFalse(kmsVerifier.isValidSigner(signer0));
    }

    // ============ Effective Threshold Tests ============

    function test_EffectiveThresholdReturnsMinimumDuringGracePeriod() public {
        _upgradeProxyWithSigners(3);
        
        vm.prank(owner);
        kmsVerifier.setThreshold(2); // current threshold = 2
        
        address[] memory newSigners = new address[](3);
        newSigners[0] = newSigner0;
        newSigners[1] = newSigner1;
        newSigners[2] = newSigner2;
        
        vm.prank(owner);
        kmsVerifier.defineNewContext(newSigners, 3); // new threshold = 3
        
        // During grace period, effective threshold should be min(2, 3) = 2
        assertEq(kmsVerifier.getEffectiveThreshold(), 2);
        assertEq(kmsVerifier.getThreshold(), 3); // actual threshold is 3
        
        // After grace period, effective threshold should be 3
        vm.roll(block.number + 101);
        assertEq(kmsVerifier.getEffectiveThreshold(), 3);
    }

    function test_EffectiveThresholdWithLowerNewThreshold() public {
        _upgradeProxyWithSigners(3);
        
        vm.prank(owner);
        kmsVerifier.setThreshold(3); // current threshold = 3
        
        address[] memory newSigners = new address[](3);
        newSigners[0] = newSigner0;
        newSigners[1] = newSigner1;
        newSigners[2] = newSigner2;
        
        vm.prank(owner);
        kmsVerifier.defineNewContext(newSigners, 1); // new threshold = 1
        
        // During grace period, effective threshold should be min(3, 1) = 1
        assertEq(kmsVerifier.getEffectiveThreshold(), 1);
    }

    // ============ Grace Period Configuration Tests ============

    function test_OwnerCanSetGracePeriod() public {
        _upgradeProxyWithSigners(3);
        
        vm.prank(owner);
        vm.expectEmit();
        emit KMSVerifierV2.GracePeriodUpdated(200);
        kmsVerifier.setGracePeriod(200);
        
        (uint256 gracePeriodBlocks, , ) = kmsVerifier.getGracePeriodConfig();
        assertEq(gracePeriodBlocks, 200);
    }

    function test_CannotSetGracePeriodBelowMinimum() public {
        _upgradeProxyWithSigners(3);
        
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KMSVerifierV2.GracePeriodBelowMinimum.selector, 49, 50));
        kmsVerifier.setGracePeriod(49);
    }

    function test_CanSetGracePeriodToMinimum() public {
        _upgradeProxyWithSigners(3);
        
        vm.prank(owner);
        kmsVerifier.setGracePeriod(50); // MIN_GRACE_PERIOD
        
        (uint256 gracePeriodBlocks, , ) = kmsVerifier.getGracePeriodConfig();
        assertEq(gracePeriodBlocks, 50);
    }

    function test_OnlyOwnerCanSetGracePeriod(address randomAccount) public {
        vm.assume(randomAccount != owner);
        _upgradeProxyWithSigners(3);
        
        vm.prank(randomAccount);
        vm.expectPartialRevert(ACLOwnable.NotHostOwner.selector);
        kmsVerifier.setGracePeriod(200);
    }

    // ============ Epoch Tracking Tests ============

    function test_EpochIdIncrementsOnContextChange() public {
        _upgradeProxyWithSigners(3);
        assertEq(kmsVerifier.getEpochId(), 1);
        
        address[] memory newSigners = new address[](2);
        newSigners[0] = newSigner0;
        newSigners[1] = newSigner1;
        
        vm.prank(owner);
        kmsVerifier.defineNewContext(newSigners, 2);
        assertEq(kmsVerifier.getEpochId(), 2);
        
        address[] memory newerSigners = new address[](1);
        newerSigners[0] = newSigner2;
        
        vm.prank(owner);
        kmsVerifier.defineNewContext(newerSigners, 1);
        assertEq(kmsVerifier.getEpochId(), 3);
    }

    // ============ Signature Verification Tests (with Grace Period) ============

    function test_VerifySignaturesFromCurrentSigners() public {
        _upgradeProxyWithSigners(3);
        
        vm.prank(owner);
        kmsVerifier.setThreshold(2);
        
        bytes32[] memory handlesList = _generateMockHandlesList(3);
        bytes memory decryptedResult = abi.encodePacked(keccak256("test"));
        bytes memory extraData = abi.encodePacked(uint8(0));
        bytes32 digest = _computeDigest(handlesList, decryptedResult, extraData);
        
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _computeSignature(privateKeySigner0, digest);
        signatures[1] = _computeSignature(privateKeySigner1, digest);
        
        bytes memory decryptionProof = _createDecryptionProof(signatures, extraData);
        
        assertTrue(kmsVerifier.verifyDecryptionEIP712KMSSignatures(handlesList, decryptedResult, decryptionProof));
    }

    function test_VerifySignaturesFromPreviousSignersDuringGracePeriod() public {
        _upgradeProxyWithSigners(3);
        
        vm.prank(owner);
        kmsVerifier.setThreshold(2);
        
        // Change context to new signers
        address[] memory newSigners = new address[](2);
        newSigners[0] = newSigner0;
        newSigners[1] = newSigner1;
        
        vm.prank(owner);
        kmsVerifier.defineNewContext(newSigners, 2);
        
        // Verify that old signers can still sign during grace period
        bytes32[] memory handlesList = _generateMockHandlesList(3);
        bytes memory decryptedResult = abi.encodePacked(keccak256("test"));
        bytes memory extraData = abi.encodePacked(uint8(0));
        bytes32 digest = _computeDigest(handlesList, decryptedResult, extraData);
        
        // Sign with OLD signers (should work during grace period)
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _computeSignature(privateKeySigner0, digest);
        signatures[1] = _computeSignature(privateKeySigner1, digest);
        
        bytes memory decryptionProof = _createDecryptionProof(signatures, extraData);
        
        assertTrue(kmsVerifier.verifyDecryptionEIP712KMSSignatures(handlesList, decryptedResult, decryptionProof));
    }

    function test_VerifySignaturesFromPreviousSignersFailsAfterGracePeriod() public {
        _upgradeProxyWithSigners(3);
        
        vm.prank(owner);
        kmsVerifier.setThreshold(2);
        
        // Change context
        address[] memory newSigners = new address[](2);
        newSigners[0] = newSigner0;
        newSigners[1] = newSigner1;
        
        vm.prank(owner);
        kmsVerifier.defineNewContext(newSigners, 2);
        
        // Advance past grace period
        vm.roll(block.number + 101);
        
        bytes32[] memory handlesList = _generateMockHandlesList(3);
        bytes memory decryptedResult = abi.encodePacked(keccak256("test"));
        bytes memory extraData = abi.encodePacked(uint8(0));
        bytes32 digest = _computeDigest(handlesList, decryptedResult, extraData);
        
        // Sign with OLD signers (should fail after grace period)
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _computeSignature(privateKeySigner0, digest);
        signatures[1] = _computeSignature(privateKeySigner1, digest);
        
        bytes memory decryptionProof = _createDecryptionProof(signatures, extraData);
        
        vm.expectPartialRevert(KMSVerifierV2.KMSInvalidSigner.selector);
        kmsVerifier.verifyDecryptionEIP712KMSSignatures(handlesList, decryptedResult, decryptionProof);
    }

    function test_VerifyMixedSignaturesDuringGracePeriod() public {
        _upgradeProxyWithSigners(3);
        
        vm.prank(owner);
        kmsVerifier.setThreshold(2);
        
        // Change context
        address[] memory newSigners = new address[](2);
        newSigners[0] = newSigner0;
        newSigners[1] = newSigner1;
        
        vm.prank(owner);
        kmsVerifier.defineNewContext(newSigners, 2);
        
        bytes32[] memory handlesList = _generateMockHandlesList(3);
        bytes memory decryptedResult = abi.encodePacked(keccak256("test"));
        bytes memory extraData = abi.encodePacked(uint8(0));
        bytes32 digest = _computeDigest(handlesList, decryptedResult, extraData);
        
        // Mix of old and new signers
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _computeSignature(privateKeySigner0, digest); // old
        signatures[1] = _computeSignature(privateKeyNewSigner0, digest); // new
        
        bytes memory decryptionProof = _createDecryptionProof(signatures, extraData);
        
        assertTrue(kmsVerifier.verifyDecryptionEIP712KMSSignatures(handlesList, decryptedResult, decryptionProof));
    }

    function test_VerifyNewSignersAfterGracePeriod() public {
        _upgradeProxyWithSigners(3);
        
        // Change context
        address[] memory newSigners = new address[](2);
        newSigners[0] = newSigner0;
        newSigners[1] = newSigner1;
        
        vm.prank(owner);
        kmsVerifier.defineNewContext(newSigners, 2);
        
        // Advance past grace period
        vm.roll(block.number + 101);
        
        bytes32[] memory handlesList = _generateMockHandlesList(3);
        bytes memory decryptedResult = abi.encodePacked(keccak256("test"));
        bytes memory extraData = abi.encodePacked(uint8(0));
        bytes32 digest = _computeDigest(handlesList, decryptedResult, extraData);
        
        // Sign with NEW signers (should work)
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _computeSignature(privateKeyNewSigner0, digest);
        signatures[1] = _computeSignature(privateKeyNewSigner1, digest);
        
        bytes memory decryptionProof = _createDecryptionProof(signatures, extraData);
        
        assertTrue(kmsVerifier.verifyDecryptionEIP712KMSSignatures(handlesList, decryptedResult, decryptionProof));
    }

    // ============ Legacy Compatibility Tests ============

    function test_isSignerOnlyChecksCurrentContext() public {
        _upgradeProxyWithSigners(3);
        
        address[] memory newSigners = new address[](2);
        newSigners[0] = newSigner0;
        newSigners[1] = newSigner1;
        
        vm.prank(owner);
        kmsVerifier.defineNewContext(newSigners, 2);
        
        // isSigner only checks current signers
        assertFalse(kmsVerifier.isSigner(signer0));
        assertFalse(kmsVerifier.isSigner(signer1));
        assertTrue(kmsVerifier.isSigner(newSigner0));
        assertTrue(kmsVerifier.isSigner(newSigner1));
        
        // isValidSigner checks both during grace period
        assertTrue(kmsVerifier.isValidSigner(signer0));
        assertTrue(kmsVerifier.isValidSigner(newSigner0));
    }

    // ============ Access Control Tests ============

    function test_OnlyOwnerCanDefineNewContext(address randomAccount) public {
        vm.assume(randomAccount != owner);
        _upgradeProxyWithSigners(3);
        
        address[] memory newSigners = new address[](1);
        newSigners[0] = address(42);
        
        vm.prank(randomAccount);
        vm.expectPartialRevert(ACLOwnable.NotHostOwner.selector);
        kmsVerifier.defineNewContext(newSigners, 1);
    }

    function test_OnlyOwnerCanSetThreshold(address randomAccount) public {
        vm.assume(randomAccount != owner);
        _upgradeProxyWithSigners(3);
        
        vm.prank(randomAccount);
        vm.expectPartialRevert(ACLOwnable.NotHostOwner.selector);
        kmsVerifier.setThreshold(2);
    }

    // ============ Error Case Tests ============

    function test_CannotAddNullAddressAsSigner() public {
        _upgradeProxyWithSigners(3);
        
        address[] memory newSigners = new address[](1);
        newSigners[0] = address(0);
        
        vm.prank(owner);
        vm.expectPartialRevert(KMSVerifierV2.KMSSignerNull.selector);
        kmsVerifier.defineNewContext(newSigners, 1);
    }

    function test_CannotAddDuplicateSigners() public {
        _upgradeProxyWithSigners(3);
        
        address[] memory newSigners = new address[](2);
        newSigners[0] = newSigner0;
        newSigners[1] = newSigner0; // duplicate
        
        vm.prank(owner);
        vm.expectRevert(KMSVerifierV2.KMSAlreadySigner.selector);
        kmsVerifier.defineNewContext(newSigners, 1);
    }

    function test_CannotSetEmptySignersSet() public {
        _upgradeProxyWithSigners(3);
        
        address[] memory emptySigners = new address[](0);
        
        vm.prank(owner);
        vm.expectRevert(KMSVerifierV2.SignersSetIsEmpty.selector);
        kmsVerifier.defineNewContext(emptySigners, 0);
    }

    function test_ThresholdCannotBeZero() public {
        _upgradeProxyWithSigners(3);
        
        vm.prank(owner);
        vm.expectRevert(KMSVerifierV2.ThresholdIsNull.selector);
        kmsVerifier.setThreshold(0);
    }

    function test_ThresholdCannotExceedSignersCount() public {
        _upgradeProxyWithSigners(3);
        
        vm.prank(owner);
        vm.expectRevert(KMSVerifierV2.ThresholdIsAboveNumberOfSigners.selector);
        kmsVerifier.setThreshold(4);
    }

    // ============ Edge Cases ============

    function test_MultipleContextTransitionsPreserveOnlyImmediatePrevious() public {
        _upgradeProxyWithSigners(3);
        
        // First transition
        address[] memory context2 = new address[](2);
        context2[0] = newSigner0;
        context2[1] = newSigner1;
        
        vm.prank(owner);
        kmsVerifier.defineNewContext(context2, 2);
        
        // Second transition (before grace period ends)
        address[] memory context3 = new address[](1);
        context3[0] = newSigner2;
        
        vm.prank(owner);
        kmsVerifier.defineNewContext(context3, 1);
        
        // Original signers (signer0, signer1, signer2) should NOT be valid
        // Only context2 signers should be in previous
        assertFalse(kmsVerifier.isValidSigner(signer0)); // original
        assertTrue(kmsVerifier.isValidSigner(newSigner0)); // previous (context2)
        assertTrue(kmsVerifier.isValidSigner(newSigner1)); // previous (context2)
        assertTrue(kmsVerifier.isValidSigner(newSigner2)); // current (context3)
        
        // Previous signers array should be context2
        address[] memory prevSigners = kmsVerifier.getPreviousSigners();
        assertEq(prevSigners.length, 2);
        assertEq(prevSigners[0], newSigner0);
        assertEq(prevSigners[1], newSigner1);
    }

    function test_ContextTransitionEmitsCorrectEvent() public {
        _upgradeProxyWithSigners(3);
        
        address[] memory newSigners = new address[](2);
        newSigners[0] = newSigner0;
        newSigners[1] = newSigner1;
        
        vm.prank(owner);
        vm.expectEmit();
        emit KMSVerifierV2.NewContextSet(newSigners, 2, block.number);
        kmsVerifier.defineNewContext(newSigners, 2);
    }
}
