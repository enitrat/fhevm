// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "@openzeppelin/foundry-upgrades/src/Upgrades.sol";

import {DecryptionFallback} from "../../contracts/DecryptionFallback.sol";
import {ACL} from "../../contracts/ACL.sol";
import {EmptyUUPSProxy} from "../../contracts/emptyProxy/EmptyUUPSProxy.sol";
import {ACLOwnable} from "../../contracts/shared/ACLOwnable.sol";
import {aclAdd} from "../../addresses/FHEVMHostAddresses.sol";

/**
 * @title DecryptionFallbackTest
 * @notice Tests for DecryptionFallback (Gateway V2 Cold Path).
 */
contract DecryptionFallbackTest is Test {
    DecryptionFallback internal fallbackContract;

    address internal constant owner = address(456);
    address internal user = address(789);

    // Fee configuration
    uint256 internal constant baseFeeWei = 0.001 ether;
    uint256 internal constant feePerHandle = 0.0001 ether;

    // Test keys
    uint256 internal constant userPrivateKey = 0x123;
    address internal userAddr;

    address internal proxy;
    address internal implementation;

    // ============ Setup ============

    function setUp() public {
        userAddr = vm.addr(userPrivateKey);
        vm.deal(user, 10 ether);
        vm.deal(userAddr, 10 ether);

        _deployProxy();
        _deployAndEtchACL();
        _upgradeProxy();
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

    function _upgradeProxy() internal {
        implementation = address(new DecryptionFallback());
        UnsafeUpgrades.upgradeProxy(
            proxy,
            implementation,
            abi.encodeCall(
                DecryptionFallback.initializeFromEmptyProxy,
                (baseFeeWei, feePerHandle)
            ),
            owner
        );
        fallbackContract = DecryptionFallback(proxy);
    }

    // ============ Helper Functions ============

    function _generateMockHandles(uint256 count) internal pure returns (bytes32[] memory) {
        bytes32[] memory handles = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            handles[i] = bytes32(uint256(i + 1));
        }
        return handles;
    }

    function _generateMockSignature() internal pure returns (bytes memory) {
        // Generate a 65-byte dummy signature (r, s, v format)
        return abi.encodePacked(
            bytes32(uint256(1)), // r
            bytes32(uint256(2)), // s
            uint8(27) // v
        );
    }

    function _generateMockPublicKey() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(0xdeadbeef)));
    }

    // ============ Initialization Tests ============

    function test_PostProxyUpgradeCheck() public view {
        assertEq(fallbackContract.getVersion(), "DecryptionFallback v2.0.0");
        
        (uint256 base, uint256 perHandle) = fallbackContract.getFeeConfig();
        assertEq(base, baseFeeWei);
        assertEq(perHandle, feePerHandle);
    }

    function test_InitialRequestCountIsZero() public view {
        assertEq(fallbackContract.getRequestCount(), 0);
    }

    // ============ Fee Calculation Tests ============

    function test_CalculateFeeWithOneHandle() public view {
        uint256 fee = fallbackContract.calculateFee(1);
        assertEq(fee, baseFeeWei + feePerHandle);
    }

    function test_CalculateFeeWithMultipleHandles() public view {
        uint256 fee = fallbackContract.calculateFee(5);
        assertEq(fee, baseFeeWei + (5 * feePerHandle));
    }

    function test_CalculateFeeWithZeroHandles() public view {
        uint256 fee = fallbackContract.calculateFee(0);
        assertEq(fee, baseFeeWei);
    }

    // ============ Public Decryption Request Tests ============

    function test_RequestPublicDecryption() public {
        bytes32[] memory handles = _generateMockHandles(3);
        uint256 fee = fallbackContract.calculateFee(3);

        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        // requestId has prefix 0x03 << 248 | 1
        uint256 expectedRequestId = (0x03 << 248) | 1;
        emit DecryptionFallback.DecryptionRequested(
            expectedRequestId,
            handles,
            user,
            "",
            true,
            block.timestamp
        );
        uint256 requestId = fallbackContract.requestPublicDecryption{value: fee}(handles);

        assertEq(requestId, expectedRequestId);
        assertEq(fallbackContract.getRequestCount(), 1);

        // Verify stored request
        (
            bytes32[] memory storedHandles,
            address requester,
            bytes memory publicKey,
            bool isPublic,
            uint256 storedFee,
            uint256 timestamp
        ) = fallbackContract.getRequest(requestId);

        assertEq(storedHandles.length, 3);
        assertEq(requester, user);
        assertEq(publicKey.length, 0);
        assertTrue(isPublic);
        assertEq(storedFee, fee);
        assertEq(timestamp, block.timestamp);
    }

    function test_RequestPublicDecryption_EmptyHandlesReverts() public {
        bytes32[] memory handles = new bytes32[](0);
        uint256 fee = fallbackContract.calculateFee(0);

        vm.prank(user);
        vm.expectRevert(DecryptionFallback.EmptyHandles.selector);
        fallbackContract.requestPublicDecryption{value: fee}(handles);
    }

    function test_RequestPublicDecryption_InsufficientPaymentReverts() public {
        bytes32[] memory handles = _generateMockHandles(3);
        uint256 requiredFee = fallbackContract.calculateFee(3);
        uint256 insufficientFee = requiredFee - 1;

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                DecryptionFallback.InsufficientPayment.selector,
                requiredFee,
                insufficientFee
            )
        );
        fallbackContract.requestPublicDecryption{value: insufficientFee}(handles);
    }

    function test_RequestPublicDecryption_OverpaymentAccepted() public {
        bytes32[] memory handles = _generateMockHandles(3);
        uint256 requiredFee = fallbackContract.calculateFee(3);
        uint256 overpayment = requiredFee + 1 ether;

        vm.prank(user);
        fallbackContract.requestPublicDecryption{value: overpayment}(handles);

        // Contract should have received full overpayment
        assertEq(address(fallbackContract).balance, overpayment);
    }

    // ============ User Decryption Request Tests ============

    function test_RequestUserDecryption() public {
        bytes32[] memory handles = _generateMockHandles(2);
        address[] memory contracts = new address[](1);
        contracts[0] = address(0x1234);
        bytes memory publicKey = _generateMockPublicKey();
        bytes memory signature = _generateMockSignature();
        uint256 fee = fallbackContract.calculateFee(2);

        vm.prank(user);
        uint256 expectedRequestId = (0x03 << 248) | 1;
        vm.expectEmit(true, true, false, true);
        emit DecryptionFallback.DecryptionRequested(
            expectedRequestId,
            handles,
            user,
            publicKey,
            false,
            block.timestamp
        );
        uint256 requestId = fallbackContract.requestUserDecryption{value: fee}(
            handles,
            contracts,
            publicKey,
            signature
        );

        assertEq(requestId, expectedRequestId);

        // Verify stored request
        (
            bytes32[] memory storedHandles,
            address requester,
            bytes memory storedPublicKey,
            bool isPublic,
            uint256 storedFee,
            uint256 timestamp
        ) = fallbackContract.getRequest(requestId);

        assertEq(storedHandles.length, 2);
        assertEq(requester, user);
        assertEq(keccak256(storedPublicKey), keccak256(publicKey));
        assertFalse(isPublic);
        assertEq(storedFee, fee);
        assertEq(timestamp, block.timestamp);
    }

    function test_RequestUserDecryption_EmptyHandlesReverts() public {
        bytes32[] memory handles = new bytes32[](0);
        address[] memory contracts = new address[](0);
        bytes memory publicKey = _generateMockPublicKey();
        bytes memory signature = _generateMockSignature();
        uint256 fee = fallbackContract.calculateFee(0);

        vm.prank(user);
        vm.expectRevert(DecryptionFallback.EmptyHandles.selector);
        fallbackContract.requestUserDecryption{value: fee}(
            handles,
            contracts,
            publicKey,
            signature
        );
    }

    function test_RequestUserDecryption_InvalidSignatureReverts() public {
        bytes32[] memory handles = _generateMockHandles(2);
        address[] memory contracts = new address[](0);
        bytes memory publicKey = _generateMockPublicKey();
        bytes memory invalidSignature = abi.encodePacked(uint8(1)); // Too short
        uint256 fee = fallbackContract.calculateFee(2);

        vm.prank(user);
        vm.expectRevert(DecryptionFallback.InvalidSignature.selector);
        fallbackContract.requestUserDecryption{value: fee}(
            handles,
            contracts,
            publicKey,
            invalidSignature
        );
    }

    function test_RequestUserDecryption_InsufficientPaymentReverts() public {
        bytes32[] memory handles = _generateMockHandles(2);
        address[] memory contracts = new address[](0);
        bytes memory publicKey = _generateMockPublicKey();
        bytes memory signature = _generateMockSignature();
        uint256 requiredFee = fallbackContract.calculateFee(2);
        uint256 insufficientFee = requiredFee - 1;

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                DecryptionFallback.InsufficientPayment.selector,
                requiredFee,
                insufficientFee
            )
        );
        fallbackContract.requestUserDecryption{value: insufficientFee}(
            handles,
            contracts,
            publicKey,
            signature
        );
    }

    // ============ Request ID Format Tests ============

    function test_RequestIdHasColdPathPrefix() public {
        bytes32[] memory handles = _generateMockHandles(1);
        uint256 fee = fallbackContract.calculateFee(1);

        vm.prank(user);
        uint256 requestId = fallbackContract.requestPublicDecryption{value: fee}(handles);

        // Verify prefix (0x03 << 248)
        uint256 prefix = requestId >> 248;
        assertEq(prefix, 0x03);
    }

    function test_RequestIdIncrementsSequentially() public {
        bytes32[] memory handles = _generateMockHandles(1);
        uint256 fee = fallbackContract.calculateFee(1);

        vm.startPrank(user);
        uint256 requestId1 = fallbackContract.requestPublicDecryption{value: fee}(handles);
        uint256 requestId2 = fallbackContract.requestPublicDecryption{value: fee}(handles);
        uint256 requestId3 = fallbackContract.requestPublicDecryption{value: fee}(handles);
        vm.stopPrank();

        // Counter portion should increment
        uint256 counter1 = requestId1 & ((1 << 248) - 1);
        uint256 counter2 = requestId2 & ((1 << 248) - 1);
        uint256 counter3 = requestId3 & ((1 << 248) - 1);

        assertEq(counter1, 1);
        assertEq(counter2, 2);
        assertEq(counter3, 3);
    }

    // ============ Get Request Tests ============

    function test_GetRequest_NotFoundReverts() public {
        uint256 nonExistentRequestId = 999;

        vm.expectRevert(
            abi.encodeWithSelector(
                DecryptionFallback.RequestNotFound.selector,
                nonExistentRequestId
            )
        );
        fallbackContract.getRequest(nonExistentRequestId);
    }

    // ============ Admin Functions Tests ============

    function test_SetFeeConfig() public {
        uint256 newBaseFee = 0.002 ether;
        uint256 newFeePerHandle = 0.0002 ether;

        vm.prank(owner);
        fallbackContract.setFeeConfig(newBaseFee, newFeePerHandle);

        (uint256 base, uint256 perHandle) = fallbackContract.getFeeConfig();
        assertEq(base, newBaseFee);
        assertEq(perHandle, newFeePerHandle);
    }

    function test_SetFeeConfig_OnlyOwner(address randomAccount) public {
        vm.assume(randomAccount != owner);

        vm.prank(randomAccount);
        vm.expectPartialRevert(ACLOwnable.NotHostOwner.selector);
        fallbackContract.setFeeConfig(0, 0);
    }

    function test_WithdrawFees() public {
        // First, accumulate some fees
        bytes32[] memory handles = _generateMockHandles(3);
        uint256 fee = fallbackContract.calculateFee(3);

        vm.prank(user);
        fallbackContract.requestPublicDecryption{value: fee}(handles);

        assertEq(address(fallbackContract).balance, fee);

        // Withdraw fees
        address payable recipient = payable(address(0x9999));
        uint256 recipientBalanceBefore = recipient.balance;

        vm.prank(owner);
        fallbackContract.withdrawFees(recipient);

        assertEq(address(fallbackContract).balance, 0);
        assertEq(recipient.balance, recipientBalanceBefore + fee);
    }

    function test_WithdrawFees_OnlyOwner(address randomAccount) public {
        vm.assume(randomAccount != owner);

        vm.prank(randomAccount);
        vm.expectPartialRevert(ACLOwnable.NotHostOwner.selector);
        fallbackContract.withdrawFees(payable(address(0x1)));
    }

    // ============ Edge Cases ============

    function test_MultipleRequestsFromSameUser() public {
        bytes32[] memory handles1 = _generateMockHandles(1);
        bytes32[] memory handles2 = _generateMockHandles(2);
        uint256 fee1 = fallbackContract.calculateFee(1);
        uint256 fee2 = fallbackContract.calculateFee(2);

        vm.startPrank(user);
        uint256 requestId1 = fallbackContract.requestPublicDecryption{value: fee1}(handles1);
        uint256 requestId2 = fallbackContract.requestPublicDecryption{value: fee2}(handles2);
        vm.stopPrank();

        // Verify both requests are stored correctly
        (, address requester1, , , , ) = fallbackContract.getRequest(requestId1);
        (, address requester2, , , , ) = fallbackContract.getRequest(requestId2);

        assertEq(requester1, user);
        assertEq(requester2, user);
        assertEq(fallbackContract.getRequestCount(), 2);
    }

    function test_RequestsFromDifferentUsers() public {
        address user2 = address(0xAAA);
        vm.deal(user2, 10 ether);

        bytes32[] memory handles = _generateMockHandles(1);
        uint256 fee = fallbackContract.calculateFee(1);

        vm.prank(user);
        uint256 requestId1 = fallbackContract.requestPublicDecryption{value: fee}(handles);

        vm.prank(user2);
        uint256 requestId2 = fallbackContract.requestPublicDecryption{value: fee}(handles);

        (, address requester1, , , , ) = fallbackContract.getRequest(requestId1);
        (, address requester2, , , , ) = fallbackContract.getRequest(requestId2);

        assertEq(requester1, user);
        assertEq(requester2, user2);
    }

    function test_LargeNumberOfHandles() public {
        // Test with many handles
        bytes32[] memory handles = _generateMockHandles(100);
        uint256 fee = fallbackContract.calculateFee(100);

        vm.prank(user);
        uint256 requestId = fallbackContract.requestPublicDecryption{value: fee}(handles);

        (bytes32[] memory storedHandles, , , , , ) = fallbackContract.getRequest(requestId);
        assertEq(storedHandles.length, 100);
    }

    function test_ZeroFeeConfiguration() public {
        vm.prank(owner);
        fallbackContract.setFeeConfig(0, 0);

        bytes32[] memory handles = _generateMockHandles(5);

        // Should work with zero fee
        vm.prank(user);
        fallbackContract.requestPublicDecryption{value: 0}(handles);

        assertEq(fallbackContract.getRequestCount(), 1);
    }
}
