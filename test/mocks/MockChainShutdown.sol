// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Stands in for the era-contracts L1 asset router, L1 native token vault and L1 asset tracker at once: the
/// bridge only reads `nativeTokenVault()` and `l1AssetTracker()` to find the asset tracker, and then its shutdown
/// state. Used so the unit tests don't need the whole ecosystem deployed.
contract MockL1AssetTracker {
    struct ShutdownChainInfo {
        address chainAdmin;
        address distributor;
    }

    mapping(uint256 chainId => ShutdownChainInfo) public shutdownChainInfo;

    function nativeTokenVault() external view returns (address) {
        return address(this);
    }

    function l1AssetTracker() external view returns (address) {
        return address(this);
    }

    function isChainShutdown(uint256 _chainId) external view returns (bool) {
        return shutdownChainInfo[_chainId].chainAdmin != address(0);
    }

    /// @dev Mirrors `L1AssetTracker.shutdownChain` and `setShutdownDistributor`.
    function shutdownChain(uint256 _chainId, address _chainAdmin, address _distributor) external {
        shutdownChainInfo[_chainId] = ShutdownChainInfo({chainAdmin: _chainAdmin, distributor: _distributor});
    }
}

/// @notice A claim distributor whose root is zero until it is installed, like the shutdown distributor proxy.
contract MockShutdownClaimDistributor {
    bytes32 public MERKLE_ROOT;

    function install(bytes32 _merkleRoot) external {
        MERKLE_ROOT = _merkleRoot;
    }
}
