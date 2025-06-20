// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICustomUniswapV3Locker {
    /**
     * @notice State of a position
     * @param minUnlockDate Minimum unlock date
     * @param integratorFeeReceiver Address of the integrator fee receiver
     * @param recipient Address of the recipient
     */
    struct PositionState {
        uint64 minUnlockDate;
        address recipient;
        address integratorFeeReceiver;
    }

    /// @notice Thrown when the sender is not the migrator contract
    error SenderNotMigrator();

    /// @notice Thrown when trying to initialized a pool that was already initialized
    error PoolAlreadyInitialized();

    /// @notice Thrown when trying to exit a pool that was not initialized
    error PoolNotInitialized();

    /// @notice Thrown when the Locker contract doesn't hold the NFT position
    error NFTPositionNotFound(uint256 tokenId);

    /// @notice Thrown when the minimum unlock date has not been reached
    error MinUnlockDateNotReached();

    /// @notice Thrown when the integrator fee receiver is the zero address
    error ZeroFeeReceiverAddress();

    function register(uint256 tokenId, address integratorFeeReceiver, address timelock) external;

    function harvest(
        uint256 tokenId
    ) external returns (uint256 collectedAmount0, uint256 collectedAmount1);

    function unlock(
        uint256 tokenId
    ) external;

    function setFeeReceiver(address feeReceiver) external;
}
