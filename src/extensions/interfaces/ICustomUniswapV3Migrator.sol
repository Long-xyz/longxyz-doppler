// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";

interface ICustomUniswapV3Migrator is ILiquidityMigrator {
    event FallbackLiquidityMigratorSet(ILiquidityMigrator liquidityMigrator);
    event MigrateFailed(uint160 sqrtPriceX96, address token0, address token1, address recipient);

    error InvalidLiquidityMigratorDataLength();
    error PoolDoesNotExist();
    error RebalanceFailed();
    error InvalidSwapCallbackCaller();
    error OnlySelf();
    error InvalidFallbackLiquidityMigrator();
    error InvalidTokenOrder();

    function fallbackLiquidityMigrator() external view returns (ILiquidityMigrator);

    function setFallbackLiquidityMigrator(
        ILiquidityMigrator liquidityMigrator
    ) external;
}
