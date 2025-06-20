// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { CustomUniswapV3Migrator } from "src/extensions/CustomUniswapV3Migrator.sol";
import { IBaseSwapRouter02 } from "src/extensions/interfaces/IBaseSwapRouter02.sol";
import { INonfungiblePositionManager } from "src/extensions/interfaces/INonfungiblePositionManager.sol";

contract DeployV3Migrator is Script {
    function run() public {
        address AIRLOCK_BASE = 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12;
        address UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
        address UNISWAP_V3_ROUTER_02_BASE = 0x2626664c2603336E57B271c5C0b26F421741e481;

        // TODO: change to actual owner
        address OWNER = 0x0000000000000000000000000000000000000000;

        // TODO: change to actual doppler fee receiver
        // This can be set later by the Locker owner
        address DOPPLER_FEE_RECEIVER = 0x21E2ce70511e4FE542a97708e89520471DAa7A66;

        // TODO: change to actual fee tier
        uint24 FEE_TIER = 10_000; // 1%

        vm.startBroadcast();

        CustomUniswapV3Migrator migrator = new CustomUniswapV3Migrator(
            AIRLOCK_BASE,
            INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE),
            IBaseSwapRouter02(UNISWAP_V3_ROUTER_02_BASE),
            DOPPLER_FEE_RECEIVER,
            FEE_TIER,
            OWNER
        );

        console.log("migrator deployed at", address(migrator));

        vm.stopBroadcast();
    }
}
