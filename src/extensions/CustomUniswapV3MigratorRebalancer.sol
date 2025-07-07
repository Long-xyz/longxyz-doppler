// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { WETH as IWETH } from "@solmate/tokens/WETH.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { IBaseSwapRouter02 } from "src/extensions/interfaces/IBaseSwapRouter02.sol";

contract CustomUniswapV3MigratorRebalancer is Ownable {
    using SafeTransferLib for ERC20;

    IUniswapV3Factory public immutable FACTORY;
    IWETH public immutable WETH;
    uint24 public immutable FEE_TIER;

    event PoolRebalanced(address indexed pool, uint160 targetSqrtPriceX96, uint160 finalSqrtPriceX96);

    error InvalidTokenOrder();
    error PoolDoesNotExist();
    error InvalidSwapCallbackCaller();

    receive() external payable {}

    /**
     * @notice Constructs the CustomUniswapV3MigratorRebalancer
     * @param owner_ Address of the owner
     * @param router Uniswap V3 router to extract factory and WETH addresses
     * @param feeTier_ The fee tier (in basis points) for the V3 pools this rebalancer will work with
     */
    constructor(
        address owner_,
        IBaseSwapRouter02 router,
        uint24 feeTier_
    ) Ownable(owner_) {
        FACTORY = IUniswapV3Factory(router.factory());
        WETH = IWETH(payable(router.WETH9()));
        FEE_TIER = feeTier_;
    }

    /**
     * @notice Rebalances a pool to a target price
     * @param token0 The token0 address (must be smaller than token1)
     * @param token1 The token1 address (must be larger than token0)
     * @param targetSqrtPriceX96 The target sqrt price to rebalance to
     */
    function rebalancePool(
        address token0,
        address token1,
        uint160 targetSqrtPriceX96
    ) external payable onlyOwner {
        require(token0 < token1, InvalidTokenOrder());

        // Handle ETH by wrapping to WETH
        if (token0 == address(0)) {
            token0 = address(WETH);
            if (token0 > token1) {
                targetSqrtPriceX96 = _invertSqrtPriceX96(targetSqrtPriceX96);
                (token0, token1) = (token1, token0);
            }
        }

        address pool = FACTORY.getPool(token0, token1, FEE_TIER);
        require(pool != address(0), PoolDoesNotExist());

        // Wrap ETH if needed
        _wrapETH(token0, token1);

        // Perform the rebalance
        _rebalance(pool, token0, token1, targetSqrtPriceX96);

        // Refund any remaining tokens to owner
        _refundTokens(token0, token1);

        // Get final price for event
        (uint160 finalSqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        emit PoolRebalanced(pool, targetSqrtPriceX96, finalSqrtPriceX96);
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

        if (amount > 0) {
            IUniswapV3Pool(pool).swap(address(this), zeroForOne, int256(amount), sqrtPriceLimitX96, "");
        }
    }

    /**
     * @notice Refunds remaining tokens and ETH to the owner
     * @param token0 Address of token0
     * @param token1 Address of token1
     */
    function _refundTokens(address token0, address token1) internal {
        if (address(this).balance > 0) {
            SafeTransferLib.safeTransferETH(owner(), address(this).balance);
        }

        uint256 balance0 = ERC20(token0).balanceOf(address(this));
        uint256 balance1 = ERC20(token1).balanceOf(address(this));

        if (balance0 != 0) {
            ERC20(token0).safeTransfer(owner(), balance0);
        }

        if (balance1 != 0) {
            ERC20(token1).safeTransfer(owner(), balance1);
        }
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
        if ((token0 == address(WETH) || token1 == address(WETH)) && address(this).balance > 0) {
            WETH.deposit{ value: address(this).balance }();
        }
    }

    /**
     * @notice Gets the token balances for rebalancing
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
     * @dev Called by the pool during the swap to request payment
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

    /**
     * @notice Allows owner to withdraw any tokens stuck in the contract
     * @param token Address of the token to withdraw
     * @param amount Amount to withdraw
     */
    function withdrawToken(address token, uint256 amount) external onlyOwner {
        ERC20(token).safeTransfer(owner(), amount);
    }

    /**
     * @notice Allows owner to withdraw ETH stuck in the contract
     */
    function withdrawETH() external onlyOwner {
        SafeTransferLib.safeTransferETH(owner(), address(this).balance);
    }
}