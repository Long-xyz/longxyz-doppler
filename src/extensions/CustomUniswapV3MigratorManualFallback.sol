// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";

contract CustomUniswapV3MigratorManualFallback is ILiquidityMigrator {
    using SafeTransferLib for ERC20;

    address public immutable migrator;
    address public immutable multisig;

    constructor(address migrator_, address multisig_) {
        migrator = migrator_;
        multisig = multisig_;
    }

    function initialize(address asset, address numeraire, bytes calldata data) external returns (address pool) {
        return address(0);
    }

    function migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) external payable returns (uint256 liquidity) {
        require(msg.sender == migrator, "Invalid sender");
        require(token0 == 0x4200000000000000000000000000000000000006, "Invalid token0");
        require(token1 == 0x8262b2275ACB27301b1BbFBDDba465CbdBd30E0B, "Invalid token1");

        address multisig_ = multisig;

        uint256 balance0 = ERC20(token0).balanceOf(address(this));
        uint256 balance1 = ERC20(token1).balanceOf(address(this));

        ERC20(token0).safeTransfer(multisig, balance0);
        ERC20(token1).safeTransfer(multisig, balance1);

        return 0;
    }
}
