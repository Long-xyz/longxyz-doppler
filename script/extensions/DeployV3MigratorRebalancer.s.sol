// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { CustomUniswapV3MigratorRebalancer } from "src/extensions/CustomUniswapV3MigratorRebalancer.sol";
import { IBaseSwapRouter02 } from "src/extensions/interfaces/IBaseSwapRouter02.sol";

contract DeployV3MigratorRebalancer is Script {
    function run() public {
        address UNISWAP_V3_ROUTER_02_BASE = 0x2626664c2603336E57B271c5C0b26F421741e481;

        // TODO: change to actual owner
        address OWNER = 0x0000000000000000000000000000000000000000;

        // TODO: change to actual fee tier
        uint24 FEE_TIER = 10_000; // 1%

        vm.startBroadcast();

        CustomUniswapV3MigratorRebalancer rebalancer = new CustomUniswapV3MigratorRebalancer(
            OWNER,
            IBaseSwapRouter02(UNISWAP_V3_ROUTER_02_BASE),
            FEE_TIER
        );

        console.log("rebalancer deployed at", address(rebalancer));

        vm.stopBroadcast();
    }
}