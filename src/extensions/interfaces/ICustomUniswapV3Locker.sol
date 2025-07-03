// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICustomUniswapV3Locker {
    /**
     * @notice State of a position
     * @param tokenId Token ID of the NFT position
     * @param minUnlockDate Minimum unlock date
     * @param recipient Address of the recipient
     * @param creatorFeeReceiver Address of the creator fee receiver
     * @param creatorFee Creator fee
     * @param integratorFeeReceiver Address of the integrator fee receiver
     */
    struct PositionState {
        address creatorFeeReceiver;
        uint256 creatorFee;
        address integratorFeeReceiver;
        address recipient;
        uint64 minUnlockDate;
        uint256 tokenId;
    }

    /// @notice Emitted when the Doppler fee receiver is set
    event DopplerFeeReceiverSet(address dopplerFeeReceiver);

    /// @notice Thrown when the sender is not the migrator contract
    error SenderNotMigrator();

    /// @notice Thrown when trying to initialized a pool that was already initialized
    error PoolAlreadyInitialized();

    /// @notice Thrown when trying to exit a pool that was not initialized
    error PoolNotInitialized();

    /// @notice Thrown when the Locker contract doesn't hold the position token
    error InvalidTokenOwnership();

    /// @notice Thrown when the minimum unlock date has not been reached
    error MinUnlockDateNotReached();

    /// @notice Thrown when the integrator fee receiver is the zero address
    error ZeroFeeReceiverAddress();

    /// @notice Thrown when the token ID is invalid
    error InvalidTokenId();

    /// @notice Thrown when the creator fee setup is invalid
    error InvalidCreatorFeeSetup();

    /// @notice Thrown when the minimum unlock date is in the past
    error InvalidMinUnlockDate();

    function initializePosition(
        address pool,
        uint64 minUnlockDate,
        address creatorFeeReceiver,
        uint256 creatorFee,
        address integratorFeeReceiver
    ) external;

    function updatePosition(address pool, uint256 tokenId, address recipient) external;

    function harvestPosition(
        address pool
    ) external returns (uint256 collectedAmount0, uint256 collectedAmount1);

    function unlockPosition(
        address pool
    ) external returns (uint256 collectedAmount0, uint256 collectedAmount1);

    function setDopplerFeeReceiver(
        address dopplerFeeReceiver
    ) external;
}
