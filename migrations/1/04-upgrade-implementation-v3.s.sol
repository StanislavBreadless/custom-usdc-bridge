// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {L1USDCBridge} from "../../src/L1USDCBridge.sol";
import {IBridgehub} from "@era-contracts/l1-contracts/contracts/bridgehub/IBridgehub.sol";
import {ITransparentUpgradeableProxy, ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {DeploymentUtils} from "../../utils/DeploymentUtils.sol";

// Deploys the V3 implementation and prints the governance call that upgrades the proxy to it.
// V3 reads the chain shutdown state from the L1 asset tracker (`isChainShutdown`, `shutdownChainInfo`), so the
// upgrade must be executed together with the asset tracker upgrade that adds them: until then every deposit,
// withdrawal and failed-deposit claim of the new implementation reverts.
// V3 does not change the storage layout, so no reinitializer is needed.
// Command to test:
// source .env && forge script ./migrations/1/04-upgrade-implementation-v3.s.sol --rpc-url ethereum
contract MigrateL1USDCBridgeV3 is Script, DeploymentUtils {
    string public constant version = "V3";
    address constant PROXY_ADMIN = 0xC2a36181fB524a6bEfE639aFEd37A67e77d62cf1; // Ethereum Proxy Admin
    // keccak256("eip1967.proxy.implementation") - 1
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() public {
        address proxyAddress = getDeployedContract("L1USDCBridge");
        require(proxyAddress != address(0), "Proxy not deployed");
        L1USDCBridge bridge = L1USDCBridge(proxyAddress);

        // The constructor arguments are read from the live proxy, so they match the current implementation.
        address usdc = bridge.L1_USDC_TOKEN();
        IBridgehub bridgehub = bridge.BRIDGE_HUB();
        require(usdc == getDeployedContract("USDC"), "USDC mismatch");
        require(address(bridgehub) == getDeployedContract("Bridgehub"), "Bridgehub mismatch");

        vm.startBroadcast();
        address newImplementation = address(new L1USDCBridge(usdc, bridgehub));
        vm.stopBroadcast();

        console.log(string.concat("Migrating L1USDCBridge to ", version));
        console.log("New implementation deployed at:", newImplementation);

        address governance = ProxyAdmin(PROXY_ADMIN).owner();
        bytes memory upgradeCallData =
            abi.encodeCall(ProxyAdmin.upgrade, (ITransparentUpgradeableProxy(proxyAddress), newImplementation));

        console.log("\n=== Governance call ===");
        console.log("From:", governance);
        console.log("To:", PROXY_ADMIN);
        console.log("Value: 0");
        console.log("Data:", vm.toString(upgradeCallData));
        console.log("========================\n");

        // Simulate the upgrade and check that the state is preserved.
        address ownerBefore = bridge.owner();
        address adminBefore = bridge.admin();
        bool pausedBefore = bridge.paused();

        console.log("Simulating the upgrade...");
        vm.prank(governance);
        (bool success,) = PROXY_ADMIN.call(upgradeCallData);
        require(success, "Upgrade simulation failed");
        require(
            address(uint160(uint256(vm.load(proxyAddress, IMPLEMENTATION_SLOT)))) == newImplementation,
            "Implementation not set"
        );
        require(bridge.owner() == ownerBefore, "Owner changed");
        require(bridge.admin() == adminBefore, "Admin changed");
        require(bridge.paused() == pausedBefore, "Paused state changed");
        console.log("Upgrade simulation successful!");

        saveDeployedContract(string.concat("L1USDCBridge-impl-", version), newImplementation);
    }
}
