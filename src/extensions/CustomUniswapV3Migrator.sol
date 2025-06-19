// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { WETH as IWETH } from "@solmate/tokens/WETH.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { FixedPoint96 } from "@v4-core/libraries/FixedPoint96.sol";
import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { ICustomUniswapV3Migrator } from "src/extensions/interfaces/ICustomUniswapV3Migrator.sol";
import { INonfungiblePositionManager } from "src/extensions/interfaces/INonfungiblePositionManager.sol";
import { IBaseSwapRouter02 } from "src/extensions/interfaces/IBaseSwapRouter02.sol";
import { CustomUniswapV3Locker } from "src/extensions/CustomUniswapV3Locker.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";

/**
 * @author ant
 * @notice An extension for LiquidityMigrator to enable real-time fee streaming via Uniswap v3 pool & v3 locker contract
 */
contract CustomUniswapV3Migrator is ICustomUniswapV3Migrator, ImmutableAirlock {
    using SafeTransferLib for ERC20;

    INonfungiblePositionManager public immutable NONFUNGIBLE_POSITION_MANAGER;
    IUniswapV3Factory public immutable FACTORY;
    IWETH public immutable WETH;
    CustomUniswapV3Locker public immutable CUSTOM_V3_LOCKER;
    uint24 public immutable FEE_TIER;

    mapping(address pool => address integratorFeeReceiver) public poolFeeReceivers;

    receive() external payable onlyAirlock { }

    /**
     * @notice Constructs the CustomUniswapV3Migrator and deploys a new CustomUniswapV3Locker
     * @param airlock_ Address of the Airlock contract that will call this migrator
     * @param positionManager_ Uniswap V3 NFT position manager for minting liquidity positions
     * @param router Uniswap V3 router to extract factory and WETH addresses
     * @param dopplerFeeReceiver_ Address that will receive the 5% protocol fee from collected LP fees
     * @param feeTier_ The fee tier (in basis points) for the V3 pools this migrator will create
     */
    constructor(
        address airlock_,
        INonfungiblePositionManager positionManager_,
        IBaseSwapRouter02 router,
        address dopplerFeeReceiver_,
        uint24 feeTier_
    ) ImmutableAirlock(airlock_) {
        NONFUNGIBLE_POSITION_MANAGER = positionManager_;
        FACTORY = IUniswapV3Factory(router.factory());
        WETH = IWETH(payable(router.WETH9()));
        CUSTOM_V3_LOCKER = new CustomUniswapV3Locker(positionManager_, this, dopplerFeeReceiver_);
        FEE_TIER = feeTier_;
    }

    /**
     * @notice Initializes a Uniswap V3 pool for future migration
     * @dev Creates the pool if it doesn't exist and initializes it at an extreme price.
     * @param asset The token being sold in the Doppler pool
     * @param numeraire The token used to purchase the asset (address(0) for ETH)
     * @param liquidityMigratorData Encoded integrator fee receiver address
     * @return pool The address of the created/existing V3 pool
     */
    function initialize(
        address asset,
        address numeraire,
        bytes calldata liquidityMigratorData
    ) external onlyAirlock returns (address pool) {
        require(liquidityMigratorData.length == 32, InvalidLiquidityMigratorDataLength());

        (address integratorFeeReceiver) = abi.decode(liquidityMigratorData, (address));
        require(integratorFeeReceiver != address(0), ZeroFeeReceiverAddress());

        if (numeraire == address(0)) numeraire = address(WETH);
        (address token0, address token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        pool = FACTORY.getPool(token0, token1, FEE_TIER);
        if (pool == address(0)) {
            pool = FACTORY.createPool(token0, token1, FEE_TIER);
        }
        poolFeeReceivers[pool] = integratorFeeReceiver;

        // NOTE: we are aware that anyone can initialize the pool with any sqrtPriceX96 after pool creation,
        // so we will initialize price ourselves and later on rebalance the price during migration
        int24 tickSpacing = FACTORY.feeAmountTickSpacing(FEE_TIER);
        int24 minTickWithSpacing = TickMath.minUsableTick(tickSpacing) + tickSpacing;
        int24 maxTickWithSpacing = TickMath.maxUsableTick(tickSpacing) - tickSpacing;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(asset == token0 ? minTickWithSpacing : maxTickWithSpacing);

        try IUniswapV3Pool(pool).initialize(sqrtPriceX96) { } catch { }

        return pool;
    }

    /**
     * @notice Migrates the liquidity into a Uniswap V3 pool
     * @param sqrtPriceX96 Square root price of the pool as a Q64.96 value
     * @param token0 Smaller address of the two tokens
     * @param token1 Larger address of the two tokens
     * @param recipient Address receiving the liquidity pool tokens i.e. timelock
     */
    function migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) external payable onlyAirlock returns (uint256) {
        if (token0 == address(0)) token0 = address(WETH);
        if (token0 > token1) (token0, token1) = (token1, token0);

        address pool = FACTORY.getPool(token0, token1, FEE_TIER);
        require(pool != address(0), PoolDoesNotExist());

        _wrapETH(token0, token1);

        _rebalance(pool, token0, token1, sqrtPriceX96);
        (uint256 balance0, uint256 balance1) = _getTokenBalances(token0, token1);

        int24 tickSpacing = FACTORY.feeAmountTickSpacing(FEE_TIER);
        (int24 tickLower, int24 tickUpper, bool isOneSided) = _calculateValidTicks(pool, sqrtPriceX96, tickSpacing);

        uint128 liquidity;

        // if we have depleted our balance and the position is not one-sided, we just skip minting
        if (isOneSided || (balance0 != 0 && balance1 != 0)) {
            ERC20(token0).safeApprove(address(NONFUNGIBLE_POSITION_MANAGER), balance0);
            ERC20(token1).safeApprove(address(NONFUNGIBLE_POSITION_MANAGER), balance1);

            INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE_TIER,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: balance0,
                amount1Desired: balance1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(CUSTOM_V3_LOCKER),
                deadline: block.timestamp
            });

            uint256 tokenId;

            (tokenId, liquidity,,) = NONFUNGIBLE_POSITION_MANAGER.mint(mintParams);

            CUSTOM_V3_LOCKER.register(tokenId, poolFeeReceivers[pool], recipient);
        }

        _refundDustAndRevokeAllowances(token0, token1, recipient);

        return liquidity;
    }

    /**
     * @notice Tries to rebalance the pool to the target sqrt price
     * @dev Swaps through the pool to move the price. When there's existing liquidity,
     * it's a best effort to move the price to the target price.
     * @param pool The pool to rebalance
     * @param token0 The token0 address
     * @param token1 The token1 address
     * @param targetSqrtPriceX96 The target sqrt price
     */
    function _rebalance(address pool, address token0, address token1, uint160 targetSqrtPriceX96) internal {
        (uint160 currentSqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();

        if (currentSqrtPriceX96 == 0) {
            IUniswapV3Pool(pool).initialize(targetSqrtPriceX96);
            return;
        }

        if (currentSqrtPriceX96 == targetSqrtPriceX96) {
            return;
        }

        (uint256 balance0, uint256 balance1) = _getTokenBalances(token0, token1);

        bool zeroForOne = targetSqrtPriceX96 < currentSqrtPriceX96;
        uint160 sqrtPriceLimitX96;
        uint256 amount;
        if (zeroForOne) {
            // price is decreasing, limit must be between target and MIN
            sqrtPriceLimitX96 =
                targetSqrtPriceX96 > TickMath.MIN_SQRT_PRICE + 1 ? targetSqrtPriceX96 : TickMath.MIN_SQRT_PRICE + 1;
            amount = balance0;
        } else {
            // Price is increasing, limit must be between target and MAX
            sqrtPriceLimitX96 =
                targetSqrtPriceX96 < TickMath.MAX_SQRT_PRICE - 1 ? targetSqrtPriceX96 : TickMath.MAX_SQRT_PRICE - 1;
            amount = balance1;
        }

        IUniswapV3Pool(pool).swap(address(this), zeroForOne, int256(amount), sqrtPriceLimitX96, "");
    }

    /**
     * @notice Calculates valid tick boundaries for a concentrated liquidity position
     * @dev Creates a narrow range centered around the wanted price, ensuring ticks are:
     *      1. Divisible by tickSpacing
     *      2. Within the usable tick range
     *      3. Properly ordered (lower < upper)
     *      4. The range includes the wanted price to ensure liquidity is active
     *      Handles edge cases at price extremes by creating a minimal valid range.
     * @param pool The pool to calculate the valid ticks for
     * @param tickSpacing The tick spacing of the pool
     * @return tickLower The lower tick boundary for the position
     * @return tickUpper The upper tick boundary for the position
     * @return isOneSided Whether the position is one-sided
     */
    function _calculateValidTicks(
        address pool,
        uint160 targetSqrtPriceX96,
        int24 tickSpacing
    ) internal view returns (int24 tickLower, int24 tickUpper, bool isOneSided) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();

        int24 priceImpliedTick = TickMath.getTickAtSqrtPrice(targetSqrtPriceX96);
        uint160 boundaryPrice = TickMath.getSqrtPriceAtTick(priceImpliedTick);

        int24 compressed = priceImpliedTick / tickSpacing;
        if (priceImpliedTick < 0 && priceImpliedTick % tickSpacing != 0) compressed--;
        int24 divisibleTick = compressed * tickSpacing;

        if (targetSqrtPriceX96 != boundaryPrice) {
            tickLower = divisibleTick;
            tickUpper = divisibleTick + tickSpacing;
        } else {
            tickLower = divisibleTick - tickSpacing;
            tickUpper = divisibleTick + tickSpacing;
        }

        int24 minUsableTick = TickMath.minUsableTick(tickSpacing);
        int24 maxUsableTick = TickMath.maxUsableTick(tickSpacing);

        if (tickUpper > maxUsableTick) {
            tickUpper = maxUsableTick;
            tickLower = tickUpper - tickSpacing;
        }
        if (tickLower < minUsableTick) {
            tickLower = minUsableTick;
            tickUpper = tickLower + tickSpacing;
        }

        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        isOneSided = sqrtPriceX96 <= sqrtPriceLowerX96 || sqrtPriceX96 >= sqrtPriceUpperX96;
    }

    /**
     * @notice Refunds remaining tokens and ETH to the recipient and revokes allowances
     * @dev After minting the V3 position, any leftover tokens (dust) that couldn't be
     *      deposited due to price constraints are sent to the recipient.
     *      Also revokes token approvals.
     * @param token0 Address of token0
     * @param token1 Address of token1
     * @param recipient Address to receive the refunded tokens (timelock)
     */
    function _refundDustAndRevokeAllowances(address token0, address token1, address recipient) internal {
        if (address(this).balance > 0) {
            SafeTransferLib.safeTransferETH(recipient, address(this).balance);
        }

        uint256 balance0 = ERC20(token0).balanceOf(address(this));
        uint256 balance1 = ERC20(token1).balanceOf(address(this));

        if (balance0 != 0) {
            ERC20(token0).safeApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);
            ERC20(token0).safeTransfer(recipient, balance0);
        }

        if (balance1 != 0) {
            ERC20(token1).safeApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);
            ERC20(token1).safeTransfer(recipient, balance1);
        }
    }

    /**
     * @notice Deposits ETH into WETH if it's one of the active tokens
     * @param token0 Address of token0
     * @param token1 Address of token1
     */
    function _wrapETH(address token0, address token1) internal {
        if (token0 == address(WETH) || token1 == address(WETH)) {
            WETH.deposit{ value: address(this).balance }();
        }
    }

    /**
     * @notice Gets the token balances for migration, considering WETH
     * @param token0 Address of token0
     * @param token1 Address of token1
     * @return balance0 Balance of token0
     * @return balance1 Balance of token1
     */
    function _getTokenBalances(
        address token0,
        address token1
    ) internal view returns (uint256 balance0, uint256 balance1) {
        balance0 = ERC20(token0).balanceOf(address(this));
        balance1 = ERC20(token1).balanceOf(address(this));
    }

    /**
     * @notice Callback for Uniswap V3 swap
     * @dev Called by the pool during the swap to request payment. When the pool has existing liquidity,
     *      we need to transfer the requested tokens to complete the swap.
     * @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive)
     * @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive)
     */
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        IUniswapV3Pool pool = IUniswapV3Pool(msg.sender);
        address token0 = pool.token0();
        address token1 = pool.token1();
        uint24 fee = pool.fee();

        require(msg.sender == FACTORY.getPool(token0, token1, fee), InvalidSwapCallbackCaller());

        if (amount0Delta > 0) {
            ERC20(token0).safeTransfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            ERC20(token1).safeTransfer(msg.sender, uint256(amount1Delta));
        }
    }
}
