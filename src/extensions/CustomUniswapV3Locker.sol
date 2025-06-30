// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { IERC721Receiver } from "@openzeppelin/token/ERC721/IERC721Receiver.sol";
import { INonfungiblePositionManager } from "src/extensions/interfaces/INonfungiblePositionManager.sol";
import { ICustomUniswapV3Locker } from "src/extensions/interfaces/ICustomUniswapV3Locker.sol";
import { CustomUniswapV3Migrator } from "src/extensions/CustomUniswapV3Migrator.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";

/**
 * @author ant
 * @notice An extension built on top of CustomUniswapV3Migrator to enable real-time fee streaming by escrowing LP for a fixed period
 */
contract CustomUniswapV3Locker is ICustomUniswapV3Locker, Ownable, IERC721Receiver {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for uint160;

    uint256 public constant DOPPLER_FEE_WAD = 0.05e18;
    uint256 public constant MAX_CREATOR_FEE_WAD = 1e18 - DOPPLER_FEE_WAD;

    /// @notice Address of the Uniswap V3 nonfungible position manager
    INonfungiblePositionManager public immutable NONFUNGIBLE_POSITION_MANAGER;

    /// @notice Address of the Uniswap V3 migrator
    CustomUniswapV3Migrator public immutable MIGRATOR;

    /// @notice Address of the Doppler fee receiver
    address public dopplerFeeReceiver;

    /// @notice Returns the state of a pool
    mapping(address pool => PositionState state) public positionStates;

    /**
     * @param owner_ Address of the owner
     * @param nonfungiblePositionManager_ Address of the Uniswap V3 nonfungible position manager
     * @param migrator_ Address of the Custom Uniswap V3 migrator
     * @param dopplerFeeReceiver_ Address of the Doppler fee receiver
     */
    constructor(
        address owner_,
        INonfungiblePositionManager nonfungiblePositionManager_,
        CustomUniswapV3Migrator migrator_,
        address dopplerFeeReceiver_
    ) Ownable(owner_) {
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
        MIGRATOR = migrator_;

        _setDopplerFeeReceiver(dopplerFeeReceiver_);
    }

    /**
     * @notice Modifier to check if the sender is the migrator
     */
    modifier onlyMigrator() {
        require(msg.sender == address(MIGRATOR), SenderNotMigrator());
        _;
    }

    /**
     * @notice Registers an LP position to be held by this contract
     * @param pool Address of the pool
     * @param minUnlockDate Minimum unlock date
     * @param creatorFeeReceiver Address of the creator fee receiver
     * @param creatorFee Creator fee
     * @param integratorFeeReceiver Address of the integrator fee receiver
     */
    function initializePosition(
        address pool,
        uint64 minUnlockDate,
        address creatorFeeReceiver,
        uint256 creatorFee,
        address integratorFeeReceiver
    ) external onlyMigrator {
        require(positionStates[pool].minUnlockDate == 0, PoolAlreadyInitialized());
        require(integratorFeeReceiver != address(0), ZeroFeeReceiverAddress());
        require((creatorFeeReceiver == address(0)) == (creatorFee == 0), InvalidCreatorFeeSetup());
        require(creatorFee <= MAX_CREATOR_FEE_WAD, InvalidCreatorFeeSetup());
        require(minUnlockDate >= block.timestamp, InvalidMinUnlockDate());

        positionStates[pool].minUnlockDate = minUnlockDate;
        positionStates[pool].creatorFeeReceiver = creatorFeeReceiver;
        positionStates[pool].creatorFee = creatorFee;
        positionStates[pool].integratorFeeReceiver = integratorFeeReceiver;
    }

    /**
     * @notice Updates the position on a pool with its token ID and recipient after migration
     * @param pool Address of the pool
     * @param tokenId Token ID of the NFT position
     * @param recipient Address of the recipient
     */
    function updatePosition(address pool, uint256 tokenId, address recipient) external onlyMigrator {
        require(positionStates[pool].tokenId == 0, PoolAlreadyInitialized());
        require(tokenId != 0, InvalidTokenId());

        address tokenOwner = NONFUNGIBLE_POSITION_MANAGER.ownerOf(tokenId);
        require(tokenOwner == address(this), InvalidTokenOwnership());

        positionStates[pool].tokenId = tokenId;
        positionStates[pool].recipient = recipient;
    }

    /**
     * @notice Harvests the fees from the position and distributes them to the fee receivers
     * @param pool Address of the pool
     * @return collectedAmount0 Amount of token0 collected
     * @return collectedAmount1 Amount of token1 collected
     */
    function harvestPosition(
        address pool
    ) public returns (uint256 collectedAmount0, uint256 collectedAmount1) {
        (collectedAmount0, collectedAmount1) = NONFUNGIBLE_POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionStates[pool].tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        _distributeFees(pool, collectedAmount0, collectedAmount1);
    }

    /**
     * @notice Transfers the whole LP to the recipient (i.e. Timelock contract) after the lockup
     * period. Fees are distributed once more before unlocking
     * @param pool Address of the pool
     * @return collectedAmount0 Amount of token0 collected
     * @return collectedAmount1 Amount of token1 collected
     */
    function unlockPosition(
        address pool
    ) external returns (uint256 collectedAmount0, uint256 collectedAmount1) {
        uint256 tokenId = positionStates[pool].tokenId;
        uint64 minUnlockDate = positionStates[pool].minUnlockDate;
        address recipient = positionStates[pool].recipient;

        require(minUnlockDate != 0, PoolNotInitialized());
        require(block.timestamp >= minUnlockDate, MinUnlockDateNotReached());

        (collectedAmount0, collectedAmount1) = harvestPosition(pool);

        // TimelockController is safe to receive ERC721 tokens
        NONFUNGIBLE_POSITION_MANAGER.safeTransferFrom(address(this), recipient, tokenId);
    }

    /**
     * @notice Sets the Doppler fee receiver. Can only be called by the owner
     * @param dopplerFeeReceiver_ Address of the Doppler fee receiver
     */
    function setDopplerFeeReceiver(
        address dopplerFeeReceiver_
    ) external onlyOwner {
        _setDopplerFeeReceiver(dopplerFeeReceiver_);
    }

    /**
     * @notice Sets the Doppler fee receiver
     * @param dopplerFeeReceiver_ Address of the Doppler fee receiver
     */
    function _setDopplerFeeReceiver(
        address dopplerFeeReceiver_
    ) internal {
        dopplerFeeReceiver = dopplerFeeReceiver_;
        emit DopplerFeeReceiverSet(dopplerFeeReceiver);
    }

    /**
     * @notice Distributes the fees to the fee receivers
     * @param pool Address of the pool
     * @param collectedAmount0 Amount of token0 collected
     * @param collectedAmount1 Amount of token1 collected
     */
    function _distributeFees(address pool, uint256 collectedAmount0, uint256 collectedAmount1) internal {
        if (collectedAmount0 == 0 && collectedAmount1 == 0) return;

        (,, address token0, address token1,,,,,,,,) =
            NONFUNGIBLE_POSITION_MANAGER.positions(positionStates[pool].tokenId);

        address integratorFeeReceiver = positionStates[pool].integratorFeeReceiver;
        address creatorFeeReceiver = positionStates[pool].creatorFeeReceiver;
        uint256 creatorFee = positionStates[pool].creatorFee;
        address dopplerFeeReceiver_ = dopplerFeeReceiver;

        _distributeTokenFees(
            token0, collectedAmount0, integratorFeeReceiver, creatorFeeReceiver, dopplerFeeReceiver_, creatorFee
        );
        _distributeTokenFees(
            token1, collectedAmount1, integratorFeeReceiver, creatorFeeReceiver, dopplerFeeReceiver_, creatorFee
        );
    }

    /**
     * @notice Distributes the fees to the fee receivers for a given token
     * @param token Address of the token
     * @param collectedAmount Amount of the token collected
     * @param integratorFeeReceiver Address of the integrator fee receiver
     * @param creatorFeeReceiver Address of the creator fee receiver
     * @param dopplerFeeReceiver_ Address of the Doppler fee receiver
     * @param creatorFee Creator fee
     */
    function _distributeTokenFees(
        address token,
        uint256 collectedAmount,
        address integratorFeeReceiver,
        address creatorFeeReceiver,
        address dopplerFeeReceiver_,
        uint256 creatorFee
    ) internal {
        if (collectedAmount == 0) return;

        uint256 dopplerFeeAmount = FixedPointMathLib.mulWadDown(collectedAmount, DOPPLER_FEE_WAD);
        uint256 creatorFeeAmount = FixedPointMathLib.mulWadDown(collectedAmount, creatorFee);

        ERC20(token).safeTransfer(dopplerFeeReceiver_, dopplerFeeAmount);
        if (creatorFeeAmount != 0) ERC20(token).safeTransfer(creatorFeeReceiver, creatorFeeAmount);

        // This both ensures we will not underflow (which can be assumed as mulWadDown is floored)
        // and that we will not transfer 0
        if (collectedAmount > dopplerFeeAmount + creatorFeeAmount) {
            ERC20(token).safeTransfer(integratorFeeReceiver, collectedAmount - dopplerFeeAmount - creatorFeeAmount);
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
