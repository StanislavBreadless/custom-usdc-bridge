// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {L1USDCBridgeTest} from "./_L1USDCBridge_Shared.t.sol";
import {MockShutdownClaimDistributor} from "../mocks/MockChainShutdown.sol";

import {ETH_TOKEN_ADDRESS} from "@era-contracts/l1-contracts/contracts/common/Config.sol";
import {IBridgehub} from "@era-contracts/l1-contracts/contracts/bridgehub/IBridgehub.sol";
import {L2Message, TxStatus} from "@era-contracts/l1-contracts/contracts/common/Messaging.sol";
import {IL1ERC20Bridge} from "@era-contracts/l1-contracts/contracts/bridge/interfaces/IL1ERC20Bridge.sol";

/// @notice Tests for chains shut down in the L1 asset tracker: the bridge stops serving them, and
/// `sendShutdownChainFunds` sends their balance to the distributor the asset tracker records.
/// @dev The asset tracker and the distributor are mocks (see `MockChainShutdown.sol`): the shutdown itself is done
/// by the era-contracts governance flow, which these unit tests isolate the bridge from. The bridgehub is mocked as in
/// the other unit tests. Chain balances are built with real `bridgehubDeposit` calls.
contract L1USDCBridgeShutdownTest is L1USDCBridgeTest {
    event ShutdownChainFundsSent(uint256 indexed chainId, address indexed distributor, uint256 amount);

    address chainAdmin;
    MockShutdownClaimDistributor distributor;

    function setUp() public override {
        super.setUp();
        chainAdmin = makeAddr("chainAdmin");
        distributor = new MockShutdownClaimDistributor();
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

    /// @dev Shuts the chain down in the asset tracker and installs its distributor.
    function _shutdownAndInstall(uint256 _chainId) internal {
        assetTracker.shutdownChain(_chainId, chainAdmin, address(distributor));
        distributor.install(keccak256("root"));
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
                    sendShutdownChainFunds: HAPPY PATHS
    //////////////////////////////////////////////////////////////*/

    /// @dev Anyone can send the funds: the destination is fixed by the asset tracker.
    function test_sendShutdownChainFunds_sendsChainBalanceToDistributor() public {
        _deposit(chainId, amount);
        _deposit(eraChainId, 2 * amount);
        _shutdownAndInstall(chainId);

        vm.expectEmit(true, true, true, true, address(sharedBridge));
        emit ShutdownChainFundsSent(chainId, address(distributor), amount);
        vm.prank(alice);
        uint256 sent = sharedBridge.sendShutdownChainFunds(chainId);

        assertEq(sent, amount);
        assertEq(token.balanceOf(address(distributor)), amount);
        assertEq(sharedBridge.chainBalance(chainId, address(token)), 0);
        // The other chain is not affected.
        assertEq(sharedBridge.chainBalance(eraChainId, address(token)), 2 * amount);
        assertEq(token.balanceOf(address(sharedBridge)), 2 * amount);
    }

    /// @dev Until the distributor is installed the governance can replace it in the asset tracker, and the funds
    /// follow the replacement.
    function test_sendShutdownChainFunds_followsReplacedDistributor() public {
        _deposit(chainId, amount);
        assetTracker.shutdownChain(chainId, chainAdmin, address(distributor));

        MockShutdownClaimDistributor newDistributor = new MockShutdownClaimDistributor();
        assetTracker.shutdownChain(chainId, chainAdmin, address(newDistributor));
        newDistributor.install(keccak256("root"));

        sharedBridge.sendShutdownChainFunds(chainId);

        assertEq(token.balanceOf(address(newDistributor)), amount);
        assertEq(token.balanceOf(address(distributor)), 0);
    }

    /// @dev Only the chain's accounted balance is sent: tokens sent to the bridge directly belong to no chain.
    function test_sendShutdownChainFunds_ignoresUnaccountedTokens() public {
        _deposit(chainId, amount);
        token.mint(address(sharedBridge), 7);
        _shutdownAndInstall(chainId);

        sharedBridge.sendShutdownChainFunds(chainId);

        assertEq(token.balanceOf(address(distributor)), amount);
        assertEq(token.balanceOf(address(sharedBridge)), 7);
    }

    function testFuzz_sendShutdownChainFunds(uint128 _amount, uint128 _otherAmount) public {
        vm.assume(_amount != 0 && _otherAmount != 0);
        _deposit(chainId, _amount);
        _deposit(eraChainId, _otherAmount);
        _shutdownAndInstall(chainId);

        sharedBridge.sendShutdownChainFunds(chainId);

        assertEq(token.balanceOf(address(distributor)), _amount);
        assertEq(sharedBridge.chainBalance(chainId, address(token)), 0);
        assertEq(sharedBridge.chainBalance(eraChainId, address(token)), _otherAmount);
        assertEq(token.balanceOf(address(sharedBridge)), _otherAmount);
    }

    /*//////////////////////////////////////////////////////////////
                    sendShutdownChainFunds: UNHAPPY PATHS
    //////////////////////////////////////////////////////////////*/

    function test_sendShutdownChainFunds_revertChainNotShutdown() public {
        _deposit(chainId, amount);

        vm.expectRevert("USDC-ShB: chain is not shut down");
        sharedBridge.sendShutdownChainFunds(chainId);
        assertEq(sharedBridge.chainBalance(chainId, address(token)), amount);
    }

    /// @dev While the distributor proxy still has the installer implementation its root is zero.
    function test_sendShutdownChainFunds_revertDistributorNotInstalled() public {
        _deposit(chainId, amount);
        assetTracker.shutdownChain(chainId, chainAdmin, address(distributor));

        vm.expectRevert("USDC-ShB: distributor not set");
        sharedBridge.sendShutdownChainFunds(chainId);
        assertEq(token.balanceOf(address(sharedBridge)), amount);
    }

    function test_sendShutdownChainFunds_revertTwice() public {
        _deposit(chainId, amount);
        _shutdownAndInstall(chainId);
        sharedBridge.sendShutdownChainFunds(chainId);

        vm.expectRevert("USDC-ShB: no chain balance");
        sharedBridge.sendShutdownChainFunds(chainId);
    }

    function test_sendShutdownChainFunds_revertPaused() public {
        _deposit(chainId, amount);
        _shutdownAndInstall(chainId);
        vm.prank(owner);
        sharedBridge.pause();

        vm.expectRevert("Pausable: paused");
        sharedBridge.sendShutdownChainFunds(chainId);
    }

    /*//////////////////////////////////////////////////////////////
                        AFTER THE SHUTDOWN
    //////////////////////////////////////////////////////////////*/

    function test_afterShutdown_depositReverts() public {
        assetTracker.shutdownChain(chainId, chainAdmin, address(distributor));

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

    function test_afterShutdown_reinitializeChainGovernanceReverts() public {
        assetTracker.shutdownChain(chainId, chainAdmin, address(distributor));

        vm.prank(owner);
        vm.expectRevert("USDC-ShB: chain is shut down");
        sharedBridge.reinitializeChainGovernance(chainId, makeAddr("newL2Bridge"));
        assertEq(sharedBridge.l2BridgeAddress(chainId), l2USDCBridge);

        // The other chain can still be reconfigured.
        vm.prank(owner);
        sharedBridge.reinitializeChainGovernance(eraChainId, makeAddr("newL2Bridge"));
        assertEq(sharedBridge.l2BridgeAddress(eraChainId), makeAddr("newL2Bridge"));
    }

    /// @dev Withdrawals revert even though the chain's balance is still in the bridge.
    function test_afterShutdown_finalizeWithdrawalReverts() public {
        _deposit(chainId, amount);
        _deposit(eraChainId, amount);
        assetTracker.shutdownChain(chainId, chainAdmin, address(distributor));

        bytes memory message = _withdrawalMessage(amount);
        _mockWithdrawalProof(chainId, message);
        vm.expectRevert("USDC-ShB: chain is shut down");
        _finalizeWithdrawal(chainId, message);
        assertEq(sharedBridge.chainBalance(chainId, address(token)), amount);

        // Withdrawals from the other chain still work.
        _mockWithdrawalProof(eraChainId, message);
        _finalizeWithdrawal(eraChainId, message);
        assertEq(token.balanceOf(alice), amount);
        assertEq(sharedBridge.chainBalance(eraChainId, address(token)), 0);
    }

    function test_afterShutdown_claimFailedDepositReverts() public {
        _deposit(chainId, amount);
        bytes32 txDataHash = keccak256(abi.encode(alice, address(token), amount));
        vm.prank(bridgehubAddress);
        sharedBridge.bridgehubConfirmL2Transaction(chainId, txDataHash, txHash);
        assetTracker.shutdownChain(chainId, chainAdmin, address(distributor));

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
        assertEq(sharedBridge.chainBalance(chainId, address(token)), amount);
    }
}
