// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { CustomUniswapV3MigratorManualFallback } from "src/extensions/CustomUniswapV3MigratorManualFallback.sol";

contract DeployV3MigratorManualFallback is Script {
    function run() public {
        // TODO: change to actual migrator address
        address MIGRATOR = 0x0000000000000000000000000000000000000000;

        // TODO: change to actual multisig address
        address MULTISIG = 0x0000000000000000000000000000000000000000;

        vm.startBroadcast();

        CustomUniswapV3MigratorManualFallback fallbackMigrator = new CustomUniswapV3MigratorManualFallback(
            MIGRATOR,
            MULTISIG
        );

        console.log("manual fallback deployed at", address(fallbackMigrator));

        vm.stopBroadcast();
    }
}