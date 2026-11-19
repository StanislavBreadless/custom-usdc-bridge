// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {L1USDCBridgeTest} from "./_L1USDCBridge_Shared.t.sol";

import {ETH_TOKEN_ADDRESS} from "@era-contracts/l1-contracts/contracts/common/Config.sol";
import {IBridgehub} from "@era-contracts/l1-contracts/contracts/bridgehub/IBridgehub.sol";
import {L2Message, TxStatus} from "@era-contracts/l1-contracts/contracts/common/Messaging.sol";
import {IL1ERC20Bridge} from "@era-contracts/l1-contracts/contracts/bridge/interfaces/IL1ERC20Bridge.sol";

/// @notice Tests for `shutdownChain`, which closes the bridge for one chain and moves its USDC out.
/// @dev The bridgehub is mocked (as in the other unit tests) because the bridge only uses it for `baseToken` and
/// proofs. Chain balances are built with real `bridgehubDeposit` calls.
contract L1USDCBridgeShutdownTest is L1USDCBridgeTest {
    event ChainShutdown(uint256 indexed chainId, address indexed recipient, uint256 amount);

    address recipient;

    function setUp() public override {
        super.setUp();
        recipient = makeAddr("recipient");
        vm.mockCall(
            bridgehubAddress, abi.encodeWithSelector(IBridgehub.baseToken.selector), abi.encode(ETH_TOKEN_ADDRESS)
        );
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deposit(uint256 _chainId, uint256 _amount) internal {
        token.mint(alice, _amount);
        vm.prank(alice);
        token.approve(address(sharedBridge), _amount);
        vm.prank(bridgehubAddress);
        sharedBridge.bridgehubDeposit(_chainId, alice, 0, abi.encode(address(token), _amount, bob));
    }

    function _withdrawalMessage(uint256 _amount) internal view returns (bytes memory) {
        return abi.encodePacked(IL1ERC20Bridge.finalizeWithdrawal.selector, alice, address(token), _amount);
    }

    function _mockWithdrawalProof(uint256 _chainId, bytes memory _message) internal {
        L2Message memory l2ToL1Message =
            L2Message({txNumberInBatch: l2TxNumberInBatch, sender: l2USDCBridge, data: _message});
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(
                IBridgehub.proveL2MessageInclusion.selector,
                _chainId,
                l2BatchNumber,
                l2MessageIndex,
                l2ToL1Message,
                merkleProof
            ),
            abi.encode(true)
        );
    }

    function _finalizeWithdrawal(uint256 _chainId, bytes memory _message) internal {
        sharedBridge.finalizeWithdrawal({
            _chainId: _chainId,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _message: _message,
            _merkleProof: merkleProof
        });
    }

    /*//////////////////////////////////////////////////////////////
                            HAPPY PATHS
    //////////////////////////////////////////////////////////////*/

    function test_shutdownChain_movesChainBalance() public {
        _deposit(chainId, amount);
        _deposit(eraChainId, 2 * amount);

        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit ChainShutdown(chainId, recipient, amount);
        vm.prank(owner);
        sharedBridge.shutdownChain(chainId, recipient);

        assertTrue(sharedBridge.isChainShutdown(chainId));
        assertEq(sharedBridge.chainBalance(chainId, address(token)), 0);
        assertEq(token.balanceOf(recipient), amount);
        // The other chain is not affected.
        assertFalse(sharedBridge.isChainShutdown(eraChainId));
        assertEq(sharedBridge.chainBalance(eraChainId, address(token)), 2 * amount);
        assertEq(token.balanceOf(address(sharedBridge)), 2 * amount);
    }

    function test_shutdownChain_zeroBalance() public {
        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit ChainShutdown(chainId, recipient, 0);
        vm.prank(owner);
        sharedBridge.shutdownChain(chainId, recipient);

        assertTrue(sharedBridge.isChainShutdown(chainId));
        assertEq(token.balanceOf(recipient), 0);
    }

    /// @dev The owner can close a chain while the bridge is paused, so the other chains don't have to be unpaused.
    function test_shutdownChain_whilePaused() public {
        _deposit(chainId, amount);
        vm.startPrank(owner);
        sharedBridge.pause();
        sharedBridge.shutdownChain(chainId, recipient);
        vm.stopPrank();

        assertTrue(sharedBridge.paused());
        assertTrue(sharedBridge.isChainShutdown(chainId));
        assertEq(token.balanceOf(recipient), amount);
    }

    /// @dev Only the chain's own balance moves: tokens sent to the bridge directly are not attributed to any chain.
    function test_shutdownChain_ignoresUnaccountedTokens() public {
        _deposit(chainId, amount);
        token.mint(address(sharedBridge), 7);

        vm.prank(owner);
        sharedBridge.shutdownChain(chainId, recipient);

        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(sharedBridge)), 7);
    }

    function testFuzz_shutdownChain(uint128 _amount, uint128 _otherAmount) public {
        vm.assume(_amount != 0 && _otherAmount != 0);
        _deposit(chainId, _amount);
        _deposit(eraChainId, _otherAmount);

        vm.prank(owner);
        sharedBridge.shutdownChain(chainId, recipient);

        assertEq(token.balanceOf(recipient), _amount);
        assertEq(sharedBridge.chainBalance(chainId, address(token)), 0);
        assertEq(sharedBridge.chainBalance(eraChainId, address(token)), _otherAmount);
        assertEq(token.balanceOf(address(sharedBridge)), _otherAmount);
    }

    /*//////////////////////////////////////////////////////////////
                            UNHAPPY PATHS
    //////////////////////////////////////////////////////////////*/

    function test_shutdownChain_revertNotOwner() public {
        vm.prank(admin);
        vm.expectRevert("Ownable: caller is not the owner");
        sharedBridge.shutdownChain(chainId, recipient);

        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        sharedBridge.shutdownChain(chainId, recipient);

        assertFalse(sharedBridge.isChainShutdown(chainId));
    }

    function test_shutdownChain_revertZeroRecipient() public {
        vm.prank(owner);
        vm.expectRevert("USDC-ShB: recipient 0");
        sharedBridge.shutdownChain(chainId, address(0));
    }

    function test_shutdownChain_revertUnknownChain() public {
        vm.prank(owner);
        vm.expectRevert("USDC-ShB: l2 bridge not yet set");
        sharedBridge.shutdownChain(12345, recipient);
    }

    function test_shutdownChain_revertTwice() public {
        vm.startPrank(owner);
        sharedBridge.shutdownChain(chainId, recipient);
        vm.expectRevert("USDC-ShB: chain is shut down");
        sharedBridge.shutdownChain(chainId, recipient);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        AFTER THE SHUTDOWN
    //////////////////////////////////////////////////////////////*/

    function test_afterShutdown_depositReverts() public {
        vm.prank(owner);
        sharedBridge.shutdownChain(chainId, recipient);

        token.mint(alice, amount);
        vm.prank(alice);
        token.approve(address(sharedBridge), amount);
        vm.prank(bridgehubAddress);
        vm.expectRevert("USDC-ShB: chain is shut down");
        sharedBridge.bridgehubDeposit(chainId, alice, 0, abi.encode(address(token), amount, bob));

        // Deposits to the other chain still work.
        _deposit(eraChainId, amount);
        assertEq(sharedBridge.chainBalance(eraChainId, address(token)), amount);
    }

    /// @dev Withdrawals revert with the shutdown error even when the bridge holds enough USDC for other chains.
    function test_afterShutdown_finalizeWithdrawalReverts() public {
        _deposit(chainId, amount);
        _deposit(eraChainId, amount);
        vm.prank(owner);
        sharedBridge.shutdownChain(chainId, recipient);

        bytes memory message = _withdrawalMessage(amount);
        _mockWithdrawalProof(chainId, message);
        vm.expectRevert("USDC-ShB: chain is shut down");
        _finalizeWithdrawal(chainId, message);

        // Withdrawals from the other chain still work.
        _mockWithdrawalProof(eraChainId, message);
        _finalizeWithdrawal(eraChainId, message);
        assertEq(token.balanceOf(alice), amount);
        assertEq(sharedBridge.chainBalance(eraChainId, address(token)), 0);
    }

    function test_afterShutdown_claimFailedDepositReverts() public {
        _deposit(chainId, amount);
        _deposit(eraChainId, amount);
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        vm.prank(bridgehubAddress);
        sharedBridge.bridgehubConfirmL2Transaction(chainId, txDataHash, txHash);

        vm.prank(owner);
        sharedBridge.shutdownChain(chainId, recipient);

        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(
                IBridgehub.proveL1ToL2TransactionStatus.selector,
                chainId,
                txHash,
                l2BatchNumber,
                l2MessageIndex,
                l2TxNumberInBatch,
                merkleProof,
                TxStatus.Failure
            ),
            abi.encode(true)
        );
        vm.expectRevert("USDC-ShB: chain is shut down");
        sharedBridge.claimFailedDeposit({
            _chainId: chainId,
            _depositSender: alice,
            _l1Token: address(token),
            _amount: amount,
            _l2TxHash: txHash,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _merkleProof: merkleProof
        });
        assertEq(sharedBridge.depositHappened(chainId, txHash), txDataHash);
    }
}
