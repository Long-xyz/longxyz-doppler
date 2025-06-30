// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { WETH as IWETH } from "@solmate/tokens/WETH.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { FixedPoint96 } from "@v4-core/libraries/FixedPoint96.sol";
import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { ICustomUniswapV3Migrator } from "src/extensions/interfaces/ICustomUniswapV3Migrator.sol";
import { INonfungiblePositionManager } from "src/extensions/interfaces/INonfungiblePositionManager.sol";
import { IBaseSwapRouter02 } from "src/extensions/interfaces/IBaseSwapRouter02.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { CustomUniswapV3Locker } from "src/extensions/CustomUniswapV3Locker.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";

/**
 * @author ant
 * @notice An extension for LiquidityMigrator to enable real-time fee streaming via Uniswap v3 pool & v3 locker contract
 */
contract CustomUniswapV3Migrator is ICustomUniswapV3Migrator, Ownable, ImmutableAirlock {
    using SafeTransferLib for ERC20;

    INonfungiblePositionManager public immutable NONFUNGIBLE_POSITION_MANAGER;
    IUniswapV3Factory public immutable FACTORY;
    IWETH public immutable WETH;
    CustomUniswapV3Locker public immutable CUSTOM_V3_LOCKER;

    uint24 public immutable FEE_TIER;

    ILiquidityMigrator public fallbackLiquidityMigrator;

    receive() external payable onlyAirlock { }

    /**
     * @notice Modifier to ensure the caller is the migrator itself
     */
    modifier onlySelf() {
        require(msg.sender == address(this), OnlySelf());
        _;
    }

    /**
     * @notice Constructs the CustomUniswapV3Migrator and deploys a new CustomUniswapV3Locker
     * @param owner_ Address of the owner
     * @param airlock_ Address of the Airlock contract that will call this migrator
     * @param positionManager_ Uniswap V3 NFT position manager for minting liquidity positions
     * @param router Uniswap V3 router to extract factory and WETH addresses
     * @param dopplerFeeReceiver_ Address that will receive the 5% protocol fee from collected LP fees
     * @param feeTier_ The fee tier (in basis points) for the V3 pools this migrator will create
     */
    constructor(
        address owner_,
        address airlock_,
        INonfungiblePositionManager positionManager_,
        IBaseSwapRouter02 router,
        address dopplerFeeReceiver_,
        uint24 feeTier_
    ) Ownable(owner_) ImmutableAirlock(airlock_) {
        NONFUNGIBLE_POSITION_MANAGER = positionManager_;
        FACTORY = IUniswapV3Factory(router.factory());
        WETH = IWETH(payable(router.WETH9()));
        CUSTOM_V3_LOCKER = new CustomUniswapV3Locker(owner_, positionManager_, this, dopplerFeeReceiver_);
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
        require(liquidityMigratorData.length == 128, InvalidLiquidityMigratorDataLength());

        (address integratorFeeReceiver, address creatorFeeReceiver, uint256 creatorFee, uint64 minUnlockDate) =
            abi.decode(liquidityMigratorData, (address, address, uint256, uint64));

        if (numeraire == address(0)) numeraire = address(WETH);
        (address token0, address token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        pool = FACTORY.getPool(token0, token1, FEE_TIER);
        if (pool == address(0)) {
            pool = FACTORY.createPool(token0, token1, FEE_TIER);
        }
        _tryInitializePool(pool, asset == token0);

        CUSTOM_V3_LOCKER.initializePosition(pool, minUnlockDate, creatorFeeReceiver, creatorFee, integratorFeeReceiver);

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
        try this.migrateImpl(sqrtPriceX96, token0, token1, recipient) returns (uint256 liquidity) {
            return liquidity;
        } catch {
            return _handleMigrationFailure(sqrtPriceX96, token0, token1, recipient);
        }
    }

    /**
     * @notice Migrates the liquidity into a Uniswap V3 pool
     * @param sqrtPriceX96 Square root price of the pool as a Q64.96 value
     * @param token0 Smaller address of the two tokens
     * @param token1 Larger address of the two tokens
     * @param recipient Address receiving the liquidity pool tokens i.e. timelock
     */
    function migrateImpl(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) public onlySelf returns (uint256) {
        require(token0 < token1, InvalidTokenOrder());

        if (token0 == address(0)) {
            token0 = address(WETH);

            if (token0 > token1) {
                sqrtPriceX96 = _invertSqrtPriceX96(sqrtPriceX96);
                (token0, token1) = (token1, token0);
            }
        }

        address pool = FACTORY.getPool(token0, token1, FEE_TIER);
        require(pool != address(0), PoolDoesNotExist());

        _wrapETH(token0, token1);

        _rebalance(pool, token0, token1, sqrtPriceX96);

        uint128 liquidity = _mintPosition(pool, token0, token1, recipient);
        _refundDustAndRevokeAllowances(token0, token1, recipient);

        return liquidity;
    }

    /**
     * @notice Sets the fallback liquidity migrator
     * @param liquidityMigrator The fallback liquidity migrator
     */
    function setFallbackLiquidityMigrator(
        ILiquidityMigrator liquidityMigrator
    ) external onlyOwner {
        fallbackLiquidityMigrator = liquidityMigrator;
        emit FallbackLiquidityMigratorSet(liquidityMigrator);
    }

    /**
     * @notice Mints a new liquidity position
     * @dev This mints a full-range position with all available balance of both tokens
     *      If there's no balance of either token, it doesn't mint anything instead of
     *      minting a one-sided position.
     * @param pool Address of the pool
     * @param token0 Address of token0
     * @param token1 Address of token1
     * @param recipient Address receiving the liquidity pool tokens i.e. timelock
     * @return liquidity The amount of liquidity minted
     */
    function _mintPosition(
        address pool,
        address token0,
        address token1,
        address recipient
    ) internal returns (uint128 liquidity) {
        (uint256 balance0, uint256 balance1) = _getTokenBalances(token0, token1);

        if (balance0 == 0 || balance1 == 0) {
            return 0;
        }

        ERC20(token0).safeApprove(address(NONFUNGIBLE_POSITION_MANAGER), balance0);
        ERC20(token1).safeApprove(address(NONFUNGIBLE_POSITION_MANAGER), balance1);

        int24 tickSpacing = FACTORY.feeAmountTickSpacing(FEE_TIER);

        uint256 tokenId;
        (tokenId, liquidity,,) = NONFUNGIBLE_POSITION_MANAGER.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE_TIER,
                tickLower: TickMath.minUsableTick(tickSpacing),
                tickUpper: TickMath.maxUsableTick(tickSpacing),
                amount0Desired: balance0,
                amount1Desired: balance1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(CUSTOM_V3_LOCKER),
                deadline: block.timestamp
            })
        );

        CUSTOM_V3_LOCKER.updatePosition(pool, tokenId, recipient);
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
        uint256 amount = zeroForOne ? balance0 : balance1;

        IUniswapV3Pool(pool).swap(address(this), zeroForOne, int256(amount), targetSqrtPriceX96, "");
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
        if (address(this).balance != 0) {
            SafeTransferLib.safeTransferETH(recipient, address(this).balance);
        }

        (uint256 balance0, uint256 balance1) = _getTokenBalances(token0, token1);

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
     * @notice Handles migration failure by relying on the fallback liquidity migrator
     * @param sqrtPriceX96 Square root price of the pool as a Q64.96 value
     * @param token0 Smaller address of the two tokens
     * @param token1 Larger address of the two tokens
     * @param recipient Address receiving the liquidity pool tokens i.e. timelock
     * @return liquidity The amount of liquidity migrated
     */
    function _handleMigrationFailure(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) internal returns (uint256) {
        emit MigrateFailed(sqrtPriceX96, token0, token1, recipient);

        ILiquidityMigrator fallbackLiquidityMigrator_ = fallbackLiquidityMigrator;
        require(address(fallbackLiquidityMigrator_) != address(0), InvalidFallbackLiquidityMigrator());

        (uint256 balance0, uint256 balance1) = _getTokenBalances(token0, token1);

        if (balance0 != 0) {
            ERC20(token0).safeTransfer(address(fallbackLiquidityMigrator_), balance0);
        }
        if (balance1 != 0) {
            ERC20(token1).safeTransfer(address(fallbackLiquidityMigrator_), balance1);
        }

        return fallbackLiquidityMigrator_.migrate(sqrtPriceX96, token0, token1, recipient);
    }

    /**
     * @notice Tries to initialize a pool, ignores any reverts
     * @param pool Address of the pool
     * @param isToken0 Whether the asset is token0
     */
    function _tryInitializePool(address pool, bool isToken0) internal {
        int24 tickSpacing = FACTORY.feeAmountTickSpacing(FEE_TIER);
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(
            isToken0 ? TickMath.minUsableTick(tickSpacing) : TickMath.maxUsableTick(tickSpacing)
        );

        try IUniswapV3Pool(pool).initialize(sqrtPriceX96) { } catch { }
    }

    /**
     * @notice Inverses a sqrtPriceX96 value
     * @param sqrtPriceX96 The sqrtPriceX96 value to invert
     * @return invertedSqrtPriceX96 The inverted sqrtPriceX96 value
     */
    function _invertSqrtPriceX96(
        uint160 sqrtPriceX96
    ) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(-1 * TickMath.getTickAtSqrtPrice(sqrtPriceX96));
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
