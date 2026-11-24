// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// Minimal interfaces of the era-contracts ecosystem contracts that the bridge reads the chain shutdown state from.
// They are declared here because the era-contracts version this repo builds against predates them.

/// @notice The getter of the L1 asset router on the Bridgehub.
interface IBridgehubAssetRouter {
    function assetRouter() external view returns (address);
}

/// @notice The getter of the native token vault on the L1 asset router.
interface IL1AssetRouterNativeTokenVault {
    function nativeTokenVault() external view returns (address);
}

/// @notice The getter of the asset tracker on the L1 native token vault.
interface IL1NativeTokenVaultAssetTracker {
    function l1AssetTracker() external view returns (address);
}

/// @notice The chain shutdown state kept by the L1 asset tracker.
interface IL1AssetTrackerShutdown {
    /// @notice Whether the governance has irreversibly shut the chain down.
    function isChainShutdown(uint256 _chainId) external view returns (bool);

    /// @notice The chain admin at the shutdown and the claim distributor that receives the chain's L1 funds.
    function shutdownChainInfo(uint256 _chainId) external view returns (address chainAdmin, address distributor);
}

/// @notice The claim distributor of a shut down chain.
interface IShutdownClaimDistributor {
    /// @notice The root of the claims. Zero until the distributor is installed.
    function MERKLE_ROOT() external view returns (bytes32);
}
