// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { console } from "forge-std/console.sol";

import { ERC721 } from "@solady/tokens/ERC721.sol";
import { ERC20 } from "@solady/tokens/ERC20.sol";
import { WETH as IWETH } from "@solmate/tokens/WETH.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IPositionManager } from "@v4-periphery/interfaces/IPositionManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { BaseTest } from "test/shared/BaseTest.sol";
import { MineV4Params, mineV4 } from "test/shared/AirlockMiner.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { Airlock, ModuleState, CreateParams } from "src/Airlock.sol";
import { DopplerDeployer, UniswapV4Initializer, IPoolInitializer } from "src/UniswapV4Initializer.sol";
import { CustomUniswapV3Migrator, IBaseSwapRouter02 } from "src/extensions/CustomUniswapV3Migrator.sol";
import { TokenFactory, ITokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory, IGovernanceFactory } from "src/GovernanceFactory.sol";
import { Doppler, CannotMigrate } from "src/Doppler.sol";
import { CustomUniswapV3Locker } from "src/extensions/CustomUniswapV3Locker.sol";
import { INonfungiblePositionManager } from "src/extensions/interfaces/INonfungiblePositionManager.sol";
import {
    UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE,
    UNISWAP_V3_FACTORY_BASE,
    WETH_BASE,
    UNISWAP_V3_ROUTER_02_BASE
} from "test/shared/Addresses.sol";

contract V3MigratorTest is BaseTest {
    using StateLibrary for IPoolManager;

    uint24 constant FEE_TIER = 10_000;
    address constant MIGRATOR_OWNER = address(0x3333);
    address constant DOPPLER_FEE_RECEIVER = address(0x2222);
    address constant INTEGRATOR_FEE_RECEIVER = address(0x1111);

    INonfungiblePositionManager public NFPM;
    IBaseSwapRouter02 public ROUTER_02;

    CustomUniswapV3Migrator public migrator;
    Airlock public airlock;
    DopplerDeployer public deployer;
    UniswapV4Initializer public initializer;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;

    // Test data
    uint256 constant INITIAL_SUPPLY = 1_000_000_000 ether;
    bytes tokenFactoryData;
    bytes poolInitializerData;

    function setUp() public override {
        vm.createSelectFork(vm.envString("BASE_MAINNET_RPC_URL"), 31_118_046);

        DEFAULT_DOPPLER_CONFIG.startingTime = vm.getBlockTimestamp();
        DEFAULT_DOPPLER_CONFIG.endingTime = vm.getBlockTimestamp() + SALE_DURATION;
        super.setUp();

        tokenFactoryData = abi.encode("Test Token", "TEST", 0, 0, new address[](0), new uint256[](0), "TOKEN_URI");
        poolInitializerData = abi.encode(
            DEFAULT_MINIMUM_PROCEEDS,
            DEFAULT_MAXIMUM_PROCEEDS,
            block.timestamp,
            block.timestamp + SALE_DURATION,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            DEFAULT_EPOCH_LENGTH,
            DEFAULT_GAMMA,
            false,
            DEFAULT_NUM_PD_SLUGS,
            DEFAULT_FEE,
            DEFAULT_TICK_SPACING
        );
    }

    function test_migrate_v3_basicScenario() public {
        address integrator = _setupContracts();
        bytes memory liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

        (, address hook, address asset,,, address timelock, address migrationPool) =
            _createPool(integrator, liquidityMigratorData);

        _assertDopplerInitialState(hook);

        _executeSwapsToMinProceeds(hook);

        vm.warp(vm.getBlockTimestamp() + SALE_DURATION + 1);

        assertGt(block.timestamp, Doppler(payable(hook)).endingTime(), "Should be past ending time");

        (uint160 initialSqrtPriceX96,,,,,,) = IUniswapV3Pool(migrationPool).slot0();

        BalanceSnapshot memory beforeSnapshot = _getBalances(hook, asset, timelock, migrationPool);
        airlock.migrate(asset);
        BalanceSnapshot memory afterSnapshot = _getBalances(hook, asset, timelock, migrationPool);
        _assertBalances(beforeSnapshot, afterSnapshot, asset);

        uint128 poolLiquidity = IUniswapV3Pool(migrationPool).liquidity();
        (uint160 finalSqrtPriceX96,,,,,,) = IUniswapV3Pool(migrationPool).slot0();
        assertGt(poolLiquidity, 0, "V3 pool should have liquidity");
        assertNotEq(finalSqrtPriceX96, initialSqrtPriceX96, "Pool price should have changed");
    }

    function test_migrate_v3_withMaxProceeds() public {
        address integrator = _setupContracts();
        bytes memory liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

        (, address hook, address asset,,, address timelock, address migrationPool) =
            _createPool(integrator, liquidityMigratorData);
        _assertDopplerInitialState(hook);

        _executeSwapsToMaxProceeds(hook);

        (uint160 initialSqrtPriceX96,,,,,,) = IUniswapV3Pool(migrationPool).slot0();

        BalanceSnapshot memory before = _getBalances(hook, asset, timelock, migrationPool);
        airlock.migrate(asset);
        BalanceSnapshot memory afterSnapshot = _getBalances(hook, asset, timelock, migrationPool);
        _assertBalances(before, afterSnapshot, asset);

        uint128 poolLiquidity = IUniswapV3Pool(migrationPool).liquidity();
        (uint160 finalSqrtPriceX96,,,,,,) = IUniswapV3Pool(migrationPool).slot0();
        assertGt(poolLiquidity, 0, "V3 pool should have liquidity");
        assertNotEq(finalSqrtPriceX96, initialSqrtPriceX96, "Pool price should have changed");
    }

    function test_migrate_v3_poolFeeTier() public {
        uint24 differentFeeTier = 500; // 0.05%
        (address integrator,) = _setupContractsWithCustomMigrator(differentFeeTier);

        bytes memory liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

        (,,,,,, address migrationPool) = _createPool(integrator, liquidityMigratorData);

        assertEq(IUniswapV3Pool(migrationPool).fee(), differentFeeTier, "Wrong fee tier");
    }

    function test_migrate_v3_feeReceiverRegistration() public {
        address integrator = _setupContracts();
        address customIntegratorFeeReceiver = makeAddr("customIntegratorFeeReceiver");
        bytes memory liquidityMigratorData = abi.encode(customIntegratorFeeReceiver);

        (, address hook, address asset,,, address timelock, address migrationPool) =
            _createPool(integrator, liquidityMigratorData);
        _assertDopplerInitialState(hook);

        assertEq(
            migrator.poolFeeReceivers(migrationPool), customIntegratorFeeReceiver, "Fee receiver should be registered"
        );

        _executeMinimalSwapsToMinProceeds(hook);

        vm.warp(vm.getBlockTimestamp() + SALE_DURATION + 1);

        BalanceSnapshot memory before = _getBalances(hook, asset, timelock, migrationPool);
        airlock.migrate(asset);
        BalanceSnapshot memory afterSnapshot = _getBalances(hook, asset, timelock, migrationPool);
        _assertBalances(before, afterSnapshot, asset);

        assertEq(
            migrator.poolFeeReceivers(migrationPool), customIntegratorFeeReceiver, "Fee receiver should be registered"
        );
    }

    function test_migrate_v3_partialSale() public {
        address integrator = _setupContracts();
        bytes memory liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

        (, address hook, address asset,,,,) = _createPool(integrator, liquidityMigratorData);
        _assertDopplerInitialState(hook);

        uint256 targetProceeds = Doppler(payable(hook)).minimumProceeds();
        uint256 halfTarget = targetProceeds / 2;

        _executeSwapsToTargetProceeds(hook, halfTarget);

        vm.warp(vm.getBlockTimestamp() + SALE_DURATION + 1);

        (,,, uint256 finalProceeds,,) = Doppler(payable(hook)).state();
        assertLt(finalProceeds, targetProceeds, "Should not have reached minimum proceeds");
        assertGe(finalProceeds, halfTarget, "Should have reached half target");

        vm.expectRevert(CannotMigrate.selector);
        airlock.migrate(asset);
    }

    function test_migrate_v3_multipleEpochs() public {
        address integrator = _setupContracts();
        bytes memory liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

        (, address hook, address asset,,, address timelock, address migrationPool) =
            _createPool(integrator, liquidityMigratorData);
        _assertDopplerInitialState(hook);

        uint256 epochLength = DEFAULT_EPOCH_LENGTH;
        uint256 targetProceeds = Doppler(payable(hook)).minimumProceeds();
        uint256 numEpochs = 5;
        uint256 totalTarget = targetProceeds + (targetProceeds / 10);
        uint256 swapAmountPerEpoch = totalTarget / numEpochs;

        for (uint256 i = 0; i < numEpochs; i++) {
            (,,, uint256 currentProceeds,,) = Doppler(payable(hook)).state();
            if (currentProceeds >= targetProceeds) {
                break;
            }

            deal(address(this), swapAmountPerEpoch);

            (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
                Doppler(payable(hook)).poolKey();
            PoolKey memory poolKey = PoolKey({
                currency0: currency0,
                currency1: currency1,
                hooks: hooks,
                fee: fee,
                tickSpacing: tickSpacing
            });

            swapRouter.swap{ value: swapAmountPerEpoch }(
                poolKey,
                IPoolManager.SwapParams(true, -int256(swapAmountPerEpoch), MIN_PRICE_LIMIT),
                PoolSwapTest.TestSettings(false, false),
                ""
            );

            vm.warp(vm.getBlockTimestamp() + epochLength);
        }

        (,,, uint256 totalProceeds,,) = Doppler(payable(hook)).state();
        assertGt(totalProceeds, targetProceeds, "Should have exceeded minimum proceeds");

        vm.warp(Doppler(payable(hook)).endingTime() + 1);

        BalanceSnapshot memory before = _getBalances(hook, asset, timelock, migrationPool);
        airlock.migrate(asset);
        BalanceSnapshot memory afterSnapshot = _getBalances(hook, asset, timelock, migrationPool);
        _assertBalances(before, afterSnapshot, asset);
    }

    function test_migrate_v3_priceVolatility() public {
        address integrator = _setupContracts();
        bytes memory liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

        (, address hook, address asset,,, address timelock, address migrationPool) =
            _createPool(integrator, liquidityMigratorData);
        _assertDopplerInitialState(hook);

        vm.warp(Doppler(payable(hook)).startingTime());
        _executeSingleSwap(hook, 0.1 ether);
        vm.warp(Doppler(payable(hook)).startingTime() + Doppler(payable(hook)).epochLength());
        _executeSingleSwap(hook, 0.5 ether);
        vm.warp(Doppler(payable(hook)).startingTime() + Doppler(payable(hook)).epochLength() * 2);
        _executeSingleSwap(hook, 1 ether);

        _executeSwapsToMinProceeds(hook);

        vm.warp(Doppler(payable(hook)).endingTime() + 1);

        (,,, uint256 finalProceeds,,) = Doppler(payable(hook)).state();
        uint256 minProceeds = Doppler(payable(hook)).minimumProceeds();
        assertGe(finalProceeds, minProceeds, "Should have reached minimum proceeds");

        uint256 dopplerAssetBalance = ERC20(asset).balanceOf(hook);
        uint256 dopplerETHBalance = hook.balance;
        assertGt(dopplerAssetBalance, 0, "Doppler should have unsold tokens");
        assertGt(dopplerETHBalance, 0, "Doppler should have ETH proceeds");

        BalanceSnapshot memory before = _getBalances(hook, asset, timelock, migrationPool);
        airlock.migrate(asset);
        BalanceSnapshot memory afterSnapshot = _getBalances(hook, asset, timelock, migrationPool);
        _assertBalances(before, afterSnapshot, asset);

        (uint160 finalPrice,,,,,,) = IUniswapV3Pool(migrationPool).slot0();
        assertGt(finalPrice, 0, "V3 pool should have valid price");
        uint128 poolLiquidity = IUniswapV3Pool(migrationPool).liquidity();
        assertGt(poolLiquidity, 0, "V3 pool should have liquidity");
    }

    function test_migrate_v3_exactMinimumProceeds() public {
        address integrator = _setupContracts();
        bytes memory liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

        (, address hook, address asset,,, address timelock, address migrationPool) =
            _createPool(integrator, liquidityMigratorData);
        _assertDopplerInitialState(hook);

        uint256 minProceeds = Doppler(payable(hook)).minimumProceeds();

        _executeSwapsToExactProceeds(hook, minProceeds + (minProceeds / 1000)); // Add 0.1% buffer

        (,,, uint256 finalProceeds,,) = Doppler(payable(hook)).state();
        assertGe(finalProceeds, minProceeds, "Should have at least minimum proceeds");
        assertLe(finalProceeds, minProceeds + (minProceeds / 100), "Should be close to minimum proceeds");

        vm.warp(Doppler(payable(hook)).endingTime() + 1);

        BalanceSnapshot memory before = _getBalances(hook, asset, timelock, migrationPool);
        airlock.migrate(asset);
        BalanceSnapshot memory afterSnapshot = _getBalances(hook, asset, timelock, migrationPool);
        _assertBalances(before, afterSnapshot, asset);
    }

    function test_migrate_v3_lateStageRush() public {
        address integrator = _setupContracts();
        bytes memory liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

        (, address hook, address asset,,, address timelock, address migrationPool) =
            _createPool(integrator, liquidityMigratorData);
        _assertDopplerInitialState(hook);

        uint256 endTime = Doppler(payable(hook)).endingTime();
        uint256 rushTime = endTime - 7200;
        vm.warp(rushTime);

        _executeSwapsToMinProceedsWithDeadline(hook, endTime - 60);

        assertLt(block.timestamp, endTime, "Should still be in sale period");

        vm.warp(endTime + 1);

        BalanceSnapshot memory before = _getBalances(hook, asset, timelock, migrationPool);
        airlock.migrate(asset);
        BalanceSnapshot memory afterSnapshot = _getBalances(hook, asset, timelock, migrationPool);
        _assertBalances(before, afterSnapshot, asset);
    }

    function testFuzz_migrate_v3_withVariousFeeTiers(
        uint24 feeTier
    ) public {
        vm.assume(feeTier == 500 || feeTier == 3000 || feeTier == 10_000);

        (address integrator, CustomUniswapV3Migrator testMigrator) = _setupContractsWithCustomMigrator(feeTier);
        bytes memory liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

        (, address hook, address asset,,, address timelock, address migrationPool) =
            _createPool(integrator, liquidityMigratorData);
        _assertDopplerInitialState(hook);

        address weth = address(testMigrator.WETH());
        address token0 = asset < weth ? asset : weth;
        address token1 = asset < weth ? weth : asset;
        address createdPool = IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE).getPool(token0, token1, feeTier);
        assertEq(createdPool, migrationPool, "Pool should have been created with correct fee tier");

        _executeMinimalSwapsToMinProceeds(hook);
        vm.warp(vm.getBlockTimestamp() + SALE_DURATION + 1);

        BalanceSnapshot memory before = _getBalances(hook, asset, timelock, migrationPool);
        airlock.migrate(asset);
        BalanceSnapshot memory afterSnapshot = _getBalances(hook, asset, timelock, migrationPool);
        _assertBalances(before, afterSnapshot, asset);
    }

    function testFuzz_migrate_v3_withVariousSwapAmounts(
        uint256 swapAmount1,
        uint256 swapAmount2,
        uint256 swapAmount3
    ) public {
        swapAmount1 = bound(swapAmount1, 0.1 ether, 100 ether);
        swapAmount2 = bound(swapAmount2, 0.1 ether, 100 ether);
        swapAmount3 = bound(swapAmount3, 0.1 ether, 100 ether);

        address integrator = _setupContracts();
        bytes memory liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

        (, address hook, address asset,,, address timelock, address migrationPool) =
            _createPool(integrator, liquidityMigratorData);
        _assertDopplerInitialState(hook);

        _executeFuzzedSwaps(hook, swapAmount1, swapAmount2, swapAmount3);

        vm.warp(vm.getBlockTimestamp() + SALE_DURATION + 1);

        (,,, uint256 totalProceeds,,) = Doppler(payable(hook)).state();

        // Only migrate if minimum proceeds were reached
        if (totalProceeds >= Doppler(payable(hook)).minimumProceeds()) {
            BalanceSnapshot memory before = _getBalances(hook, asset, timelock, migrationPool);
            airlock.migrate(asset);
            BalanceSnapshot memory afterSnapshot = _getBalances(hook, asset, timelock, migrationPool);
            _assertBalances(before, afterSnapshot, asset);
        }
    }

    function testFuzz_migrate_v3_withVariousFeeReceivers(
        address feeReceiver
    ) public {
        vm.assume(feeReceiver != address(0));
        vm.assume(uint160(feeReceiver) > 255); // Not a precompile

        address integrator = _setupContracts();
        bytes memory liquidityMigratorData = abi.encode(feeReceiver);

        (, address hook, address asset,,, address timelock, address migrationPool) =
            _createPool(integrator, liquidityMigratorData);
        _assertDopplerInitialState(hook);

        assertEq(migrator.poolFeeReceivers(migrationPool), feeReceiver, "Fee receiver should match");

        _executeMinimalSwapsToMinProceeds(hook);
        vm.warp(vm.getBlockTimestamp() + SALE_DURATION + 1);

        BalanceSnapshot memory before = _getBalances(hook, asset, timelock, migrationPool);
        airlock.migrate(asset);
        BalanceSnapshot memory afterSnapshot = _getBalances(hook, asset, timelock, migrationPool);
        _assertBalances(before, afterSnapshot, asset);
    }

    function testFuzz_migrate_v3_withVariousTimings(
        uint256 swapDelay1,
        uint256 swapDelay2,
        uint256 migrationDelay
    ) public {
        swapDelay1 = bound(swapDelay1, 100, 3600);
        swapDelay2 = bound(swapDelay2, 100, 3600);
        migrationDelay = bound(migrationDelay, 1, 86_400);

        address integrator = _setupContracts();
        bytes memory liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

        (, address hook, address asset,,, address timelock, address migrationPool) =
            _createPool(integrator, liquidityMigratorData);
        _assertDopplerInitialState(hook);

        _executeSwapsWithDelays(hook, swapDelay1, swapDelay2);

        vm.warp(Doppler(payable(hook)).endingTime() + migrationDelay);

        (,,, uint256 totalProceeds,,) = Doppler(payable(hook)).state();

        if (totalProceeds >= Doppler(payable(hook)).minimumProceeds()) {
            BalanceSnapshot memory before = _getBalances(hook, asset, timelock, migrationPool);
            airlock.migrate(asset);
            BalanceSnapshot memory afterSnapshot = _getBalances(hook, asset, timelock, migrationPool);
            _assertBalances(before, afterSnapshot, asset);
        }
    }

    function _setupContracts() internal returns (address integrator) {
        integrator = makeAddr("integrator");

        airlock = new Airlock(address(this));
        deployer = new DopplerDeployer(manager);
        initializer = new UniswapV4Initializer(address(airlock), manager, deployer);
        NFPM = INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE);
        ROUTER_02 = IBaseSwapRouter02(UNISWAP_V3_ROUTER_02_BASE);
        migrator = new CustomUniswapV3Migrator(
            address(airlock), NFPM, ROUTER_02, DOPPLER_FEE_RECEIVER, FEE_TIER, MIGRATOR_OWNER
        );
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));

        _setupModules();
    }

    function _setupContractsWithCustomMigrator(
        uint24 feeTier
    ) internal returns (address integrator, CustomUniswapV3Migrator customMigrator) {
        integrator = makeAddr("integrator");

        airlock = new Airlock(address(this));
        deployer = new DopplerDeployer(manager);
        initializer = new UniswapV4Initializer(address(airlock), manager, deployer);
        NFPM = INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE);
        ROUTER_02 = IBaseSwapRouter02(UNISWAP_V3_ROUTER_02_BASE);
        customMigrator = new CustomUniswapV3Migrator(
            address(airlock), NFPM, ROUTER_02, DOPPLER_FEE_RECEIVER, feeTier, MIGRATOR_OWNER
        );
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));

        migrator = customMigrator;
        _setupModules();
    }

    function _setupModules() internal {
        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(initializer);
        modules[3] = address(migrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;

        airlock.setModuleState(modules, states);
    }

    function _createPool(
        address integrator,
        bytes memory liquidityMigratorData
    )
        internal
        returns (
            bytes32 salt,
            address hook,
            address asset,
            address pool,
            address governance,
            address timelock,
            address migrationPool
        )
    {
        MineV4Params memory params = MineV4Params({
            airlock: address(airlock),
            poolManager: address(manager),
            initialSupply: INITIAL_SUPPLY,
            numTokensToSell: DEFAULT_NUM_TOKENS_TO_SELL,
            numeraire: address(0),
            tokenFactory: ITokenFactory(address(tokenFactory)),
            tokenFactoryData: tokenFactoryData,
            poolInitializer: UniswapV4Initializer(address(initializer)),
            poolInitializerData: poolInitializerData
        });

        (salt, hook, asset) = mineV4(params);

        CreateParams memory createParams = CreateParams({
            initialSupply: INITIAL_SUPPLY,
            numTokensToSell: DEFAULT_NUM_TOKENS_TO_SELL,
            numeraire: address(0),
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: tokenFactoryData,
            governanceFactory: IGovernanceFactory(governanceFactory),
            governanceFactoryData: abi.encode("Test Token", 7200, 50_400, 0),
            poolInitializer: IPoolInitializer(initializer),
            poolInitializerData: poolInitializerData,
            liquidityMigrator: ILiquidityMigrator(migrator),
            liquidityMigratorData: liquidityMigratorData,
            integrator: integrator,
            salt: salt
        });

        (, pool, governance, timelock, migrationPool) = airlock.create(createParams);

        _assertMigrationPoolState(asset, migrationPool, migrator.FEE_TIER());
    }

    function _assertMigrationPoolState(address asset, address migrationPool, uint24 feeTier) internal view {
        address weth = address(migrator.WETH());
        (address expectedToken0, address expectedToken1) = asset < weth ? (asset, weth) : (weth, asset);
        address createdMigrationPool =
            IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE).getPool(expectedToken0, expectedToken1, feeTier);
        assertNotEq(createdMigrationPool, address(0), "Pool should exist");
        assertEq(createdMigrationPool, migrationPool, "Pool should match expected tokens");

        (uint160 initialSqrtPriceX96,,,,,,) = IUniswapV3Pool(migrationPool).slot0();
        int24 initialTick = TickMath.getTickAtSqrtPrice(initialSqrtPriceX96);

        int24 tickSpacing = IUniswapV3Pool(migrationPool).tickSpacing();
        bool isAssetToken0 = asset < weth;
        int24 expectedInitialTick = isAssetToken0
            ? TickMath.minUsableTick(tickSpacing) + tickSpacing
            : TickMath.maxUsableTick(tickSpacing) - tickSpacing;
        assertEq(initialTick, expectedInitialTick, "Pool should be initialized at extreme tick");
    }

    function _executeSwapsToMinProceeds(
        address hook
    ) internal {
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            Doppler(payable(hook)).poolKey();

        PoolKey memory poolKey =
            PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing });

        uint256 swapCount = 0;
        while (true) {
            swapCount++;
            if (swapCount > 100) {
                revert("Too many swaps, test failed");
            }

            uint256 swapAmount = 1 ether + (swapCount * 1 ether);
            deal(address(this), swapAmount);

            (uint160 currentSqrtPrice,,,) = manager.getSlot0(poolKey.toId());
            uint160 priceLimit = currentSqrtPrice > 1000 ? currentSqrtPrice - 1000 : TickMath.MIN_SQRT_PRICE + 1;

            swapRouter.swap{ value: swapAmount }(
                poolKey,
                IPoolManager.SwapParams(true, -int256(swapAmount), priceLimit),
                PoolSwapTest.TestSettings(false, false),
                ""
            );

            (,,, uint256 totalProceeds,,) = Doppler(payable(hook)).state();
            if (totalProceeds >= Doppler(payable(hook)).minimumProceeds()) {
                break;
            }

            vm.warp(vm.getBlockTimestamp() + 200);
        }

        (,,, uint256 finalProceeds,,) = Doppler(payable(hook)).state();
        assertGe(finalProceeds, Doppler(payable(hook)).minimumProceeds(), "Should reach minimum proceeds");
    }

    function _executeSwapsToMinProceedsWithDeadline(address hook, uint256 deadline) internal {
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            Doppler(payable(hook)).poolKey();

        PoolKey memory poolKey =
            PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing });

        uint256 swapCount = 0;
        while (true) {
            swapCount++;
            if (swapCount > 100) {
                revert("Too many swaps, test failed");
            }

            // Check if we're getting too close to deadline
            if (block.timestamp + 200 > deadline) {
                break;
            }

            uint256 swapAmount = 1 ether + (swapCount * 1 ether);
            deal(address(this), swapAmount);

            (uint160 currentSqrtPrice,,,) = manager.getSlot0(poolKey.toId());
            uint160 priceLimit = currentSqrtPrice > 1000 ? currentSqrtPrice - 1000 : TickMath.MIN_SQRT_PRICE + 1;

            swapRouter.swap{ value: swapAmount }(
                poolKey,
                IPoolManager.SwapParams(true, -int256(swapAmount), priceLimit),
                PoolSwapTest.TestSettings(false, false),
                ""
            );

            (,,, uint256 totalProceeds,,) = Doppler(payable(hook)).state();
            if (totalProceeds >= Doppler(payable(hook)).minimumProceeds()) {
                break;
            }

            vm.warp(vm.getBlockTimestamp() + 200);
        }

        (,,, uint256 finalProceeds,,) = Doppler(payable(hook)).state();
        assertGe(finalProceeds, Doppler(payable(hook)).minimumProceeds(), "Should reach minimum proceeds");
    }

    function _executeSwapsToMaxProceeds(
        address hook
    ) internal {
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            Doppler(payable(hook)).poolKey();

        PoolKey memory poolKey =
            PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing });

        uint256 BUY_ETH_AMOUNT = 0.5 ether;
        uint256 totalEpochs = SALE_DURATION / DEFAULT_EPOCH_LENGTH;
        uint256 totalEthProceeds;
        uint256 count = 1;

        while (totalEthProceeds < DEFAULT_MAXIMUM_PROCEEDS) {
            require(
                count <= totalEpochs,
                string.concat(
                    "exceeding num of total epochs ", vm.toString(totalEpochs), ", please use a bigger BUY_ETH_AMOUNT"
                )
            );

            BalanceDelta delta = swapRouter.swap{ value: BUY_ETH_AMOUNT }(
                poolKey,
                IPoolManager.SwapParams(true, -int256(BUY_ETH_AMOUNT), MIN_PRICE_LIMIT),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
            uint256 tokenBought = uint256(int256(delta.amount1() < 0 ? -delta.amount1() : delta.amount1()));

            (,, uint256 currentTotalTokensSold, uint256 currentTotalProceeds,,) = Doppler(payable(hook)).state();
            totalEthProceeds = currentTotalProceeds;

            console.log("\n-------------- SALE No. %d ------------------", count);
            // console.log("current epoch", hook.getCurrentEpoch());
            console.log("token bought", tokenBought);
            console.log("totalTokensSold / circulating supply", currentTotalTokensSold);
            // console.log("totalProceeds", currentTotalProceeds);
            // console.log("\n");
            // console.log("sqrtPriceX96(ethPerOneToken)", sqrtPriceX96);
            // console.log("tick(tokenPerOneETH)", tick);

            vm.warp(vm.getBlockTimestamp() + 200);
            count++;
        }

        (,,, uint256 finalProceeds,,) = Doppler(payable(hook)).state();
        assertGe(finalProceeds, Doppler(payable(hook)).maximumProceeds(), "Should reach maximum proceeds");
    }

    function _executeMinimalSwapsToMinProceeds(
        address hook
    ) internal {
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            Doppler(payable(hook)).poolKey();

        PoolKey memory poolKey =
            PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing });

        while (true) {
            uint256 swapAmount = 10 ether;
            deal(address(this), swapAmount);

            (uint160 currentSqrtPrice,,,) = manager.getSlot0(poolKey.toId());
            uint160 priceLimit = currentSqrtPrice > 1000 ? currentSqrtPrice - 1000 : TickMath.MIN_SQRT_PRICE + 1;

            swapRouter.swap{ value: swapAmount }(
                poolKey,
                IPoolManager.SwapParams(true, -int256(swapAmount), priceLimit),
                PoolSwapTest.TestSettings(false, false),
                ""
            );

            (,,, uint256 totalProceeds,,) = Doppler(payable(hook)).state();
            if (totalProceeds >= Doppler(payable(hook)).minimumProceeds()) {
                break;
            }

            vm.warp(vm.getBlockTimestamp() + 200);
        }

        (,,, uint256 finalProceeds,,) = Doppler(payable(hook)).state();
        assertGe(finalProceeds, Doppler(payable(hook)).minimumProceeds(), "Should reach minimum proceeds");
    }

    function _executeFuzzedSwaps(address hook, uint256 amount1, uint256 amount2, uint256 amount3) internal {
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            Doppler(payable(hook)).poolKey();

        PoolKey memory poolKey =
            PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing });

        uint256[3] memory amounts = [amount1, amount2, amount3];

        for (uint256 i = 0; i < 3; i++) {
            if (amounts[i] > 0) {
                deal(address(this), amounts[i]);

                (uint160 currentSqrtPrice,,,) = manager.getSlot0(poolKey.toId());
                uint160 priceLimit;
                if (currentSqrtPrice > TickMath.MIN_SQRT_PRICE + 1000) {
                    priceLimit = currentSqrtPrice - 1000;
                } else {
                    priceLimit = TickMath.MIN_SQRT_PRICE + 1;
                }

                try swapRouter.swap{ value: amounts[i] }(
                    poolKey,
                    IPoolManager.SwapParams(true, -int256(amounts[i]), priceLimit),
                    PoolSwapTest.TestSettings(false, false),
                    ""
                ) { } catch {
                    continue;
                }

                vm.warp(vm.getBlockTimestamp() + 200);
            }
        }
    }

    function _executeSwapsToExactProceeds(address hook, uint256 targetProceeds) internal {
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            Doppler(payable(hook)).poolKey();

        PoolKey memory poolKey =
            PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing });

        uint256 swapIncrement = targetProceeds / 100; // 1% increments

        while (true) {
            (,,, uint256 currentProceeds,,) = Doppler(payable(hook)).state();
            if (currentProceeds >= targetProceeds) break;

            uint256 remaining = targetProceeds - currentProceeds;
            uint256 swapAmount = remaining < swapIncrement ? remaining : swapIncrement;

            deal(address(this), swapAmount);

            (uint160 currentSqrtPrice,,,) = manager.getSlot0(poolKey.toId());
            uint160 priceLimit;
            if (currentSqrtPrice > TickMath.MIN_SQRT_PRICE + 1000) {
                priceLimit = currentSqrtPrice - 1000;
            } else {
                priceLimit = TickMath.MIN_SQRT_PRICE + 1;
            }

            try swapRouter.swap{ value: swapAmount }(
                poolKey,
                IPoolManager.SwapParams(true, -int256(swapAmount), priceLimit),
                PoolSwapTest.TestSettings(false, false),
                ""
            ) { } catch {
                // If swap fails, try with smaller amount
                swapAmount = swapAmount / 2;
                if (swapAmount == 0) break;
                deal(address(this), swapAmount);
                try swapRouter.swap{ value: swapAmount }(
                    poolKey,
                    IPoolManager.SwapParams(true, -int256(swapAmount), priceLimit),
                    PoolSwapTest.TestSettings(false, false),
                    ""
                ) { } catch {
                    break;
                }
            }

            vm.warp(vm.getBlockTimestamp() + 10);
        }

        (,,, uint256 finalProceeds,,) = Doppler(payable(hook)).state();
        // Allow for small rounding differences (0.001% tolerance)
        uint256 tolerance = targetProceeds / 100_000; // 0.001%
        assertGe(finalProceeds + tolerance, targetProceeds, "Should reach target proceeds");
    }

    function _executeSwapsToTargetProceeds(address hook, uint256 targetProceeds) internal {
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            Doppler(payable(hook)).poolKey();

        PoolKey memory poolKey =
            PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing });

        while (true) {
            (,,, uint256 currentProceeds,,) = Doppler(payable(hook)).state();
            if (currentProceeds >= targetProceeds) {
                break;
            }

            uint256 swapAmount = 0.1 ether;
            deal(address(this), swapAmount);

            (uint160 currentSqrtPrice,,,) = manager.getSlot0(poolKey.toId());
            uint160 priceLimit = currentSqrtPrice > 1000 ? currentSqrtPrice - 1000 : TickMath.MIN_SQRT_PRICE + 1;

            swapRouter.swap{ value: swapAmount }(
                poolKey,
                IPoolManager.SwapParams(true, -int256(swapAmount), priceLimit),
                PoolSwapTest.TestSettings(false, false),
                ""
            );

            vm.warp(vm.getBlockTimestamp() + 100);
        }

        (,,, uint256 finalProceeds,,) = Doppler(payable(hook)).state();
        assertGe(finalProceeds, targetProceeds, "Should reach target proceeds");
    }

    function _executeSwapsWithDelays(address hook, uint256 delay1, uint256 delay2) internal {
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            Doppler(payable(hook)).poolKey();

        PoolKey memory poolKey =
            PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing });

        uint256 swapAmount = 5 ether;
        deal(address(this), swapAmount);

        (uint160 currentSqrtPrice,,,) = manager.getSlot0(poolKey.toId());
        uint160 priceLimit;
        if (currentSqrtPrice > TickMath.MIN_SQRT_PRICE + 1000) {
            priceLimit = currentSqrtPrice - 1000;
        } else {
            priceLimit = TickMath.MIN_SQRT_PRICE + 1;
        }

        try swapRouter.swap{ value: swapAmount }(
            poolKey,
            IPoolManager.SwapParams(true, -int256(swapAmount), priceLimit),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) { } catch { }

        vm.warp(vm.getBlockTimestamp() + delay1);

        (,,, uint256 totalProceeds,,) = Doppler(payable(hook)).state();
        if (totalProceeds < Doppler(payable(hook)).minimumProceeds()) {
            // Second swap
            deal(address(this), swapAmount);
            (currentSqrtPrice,,,) = manager.getSlot0(poolKey.toId());
            if (currentSqrtPrice > TickMath.MIN_SQRT_PRICE + 1000) {
                priceLimit = currentSqrtPrice - 1000;
            } else {
                priceLimit = TickMath.MIN_SQRT_PRICE + 1;
            }

            try swapRouter.swap{ value: swapAmount }(
                poolKey,
                IPoolManager.SwapParams(true, -int256(swapAmount), priceLimit),
                PoolSwapTest.TestSettings(false, false),
                ""
            ) { } catch { }

            vm.warp(vm.getBlockTimestamp() + delay2);

            while (true) {
                (,,, totalProceeds,,) = Doppler(payable(hook)).state();
                if (totalProceeds >= Doppler(payable(hook)).minimumProceeds()) {
                    break;
                }

                deal(address(this), swapAmount);
                (currentSqrtPrice,,,) = manager.getSlot0(poolKey.toId());
                if (currentSqrtPrice > TickMath.MIN_SQRT_PRICE + 1000) {
                    priceLimit = currentSqrtPrice - 1000;
                } else {
                    priceLimit = TickMath.MIN_SQRT_PRICE + 1;
                }

                try swapRouter.swap{ value: swapAmount }(
                    poolKey,
                    IPoolManager.SwapParams(true, -int256(swapAmount), priceLimit),
                    PoolSwapTest.TestSettings(false, false),
                    ""
                ) { } catch {
                    break;
                }

                vm.warp(vm.getBlockTimestamp() + 200);
            }
        }
    }

    function _executeSingleSwap(address hook, uint256 amount) internal {
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            Doppler(payable(hook)).poolKey();
        PoolKey memory poolKey =
            PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing });

        deal(address(this), amount);
        swapRouter.swap{ value: amount }(
            poolKey,
            IPoolManager.SwapParams(true, -int256(amount), MIN_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    struct BalanceSnapshot {
        uint256 dopplerAsset;
        uint256 dopplerETH;
        uint256 poolManagerAsset;
        uint256 poolManagerETH;
        uint256 timelockAsset;
        uint256 timelockWETH;
        uint256 airlockAsset;
        uint256 airlockWETH;
        uint256 airlockETH;
        uint256 v3PoolAsset;
        uint256 v3PoolWETH;
        uint256 lockerNftCount;
    }

    function _getBalances(
        address hook,
        address asset,
        address timelock,
        address migrationPool
    ) internal view returns (BalanceSnapshot memory) {
        address weth = address(migrator.WETH());

        return BalanceSnapshot({
            dopplerAsset: ERC20(asset).balanceOf(hook),
            dopplerETH: hook.balance,
            poolManagerAsset: ERC20(asset).balanceOf(address(manager)),
            poolManagerETH: address(manager).balance,
            timelockAsset: ERC20(asset).balanceOf(timelock),
            timelockWETH: ERC20(weth).balanceOf(timelock),
            airlockAsset: ERC20(asset).balanceOf(address(airlock)),
            airlockWETH: ERC20(weth).balanceOf(address(airlock)),
            airlockETH: address(airlock).balance,
            v3PoolAsset: ERC20(asset).balanceOf(migrationPool),
            v3PoolWETH: ERC20(weth).balanceOf(migrationPool),
            lockerNftCount: ERC721(address(NFPM)).balanceOf(address(migrator.CUSTOM_V3_LOCKER()))
        });
    }

    function _assertBalances(
        BalanceSnapshot memory beforeSnapshot,
        BalanceSnapshot memory afterSnapshot,
        address asset
    ) internal view {
        address weth = address(migrator.WETH());

        uint256 assetTakenFromPoolManager = beforeSnapshot.poolManagerAsset - afterSnapshot.poolManagerAsset;
        uint256 ethTakenFromPoolManager = beforeSnapshot.poolManagerETH - afterSnapshot.poolManagerETH;

        uint256 assetFeesRetained = afterSnapshot.airlockAsset - beforeSnapshot.airlockAsset;
        uint256 wethFeesRetained = (afterSnapshot.airlockWETH + afterSnapshot.airlockETH)
            - (beforeSnapshot.airlockWETH + beforeSnapshot.airlockETH);

        uint256 totalAssetMigrated = beforeSnapshot.dopplerAsset + assetTakenFromPoolManager;
        uint256 totalETHMigrated = beforeSnapshot.dopplerETH + ethTakenFromPoolManager;

        uint256 timelockAssetDust = afterSnapshot.timelockAsset - beforeSnapshot.timelockAsset;
        uint256 timelockWETHDust = afterSnapshot.timelockWETH - beforeSnapshot.timelockWETH;

        assertEq(
            afterSnapshot.v3PoolAsset + timelockAssetDust + assetFeesRetained,
            totalAssetMigrated,
            "Asset balance invariant: v3 pool + timelock dust + fees should equal total migrated"
        );

        assertEq(
            afterSnapshot.v3PoolWETH + timelockWETHDust + wethFeesRetained,
            totalETHMigrated,
            "ETH/WETH balance invariant: v3 pool + timelock dust + fees should equal total ETH migrated"
        );

        assertGe(
            afterSnapshot.timelockAsset, beforeSnapshot.timelockAsset, "Timelock asset balance should not decrease"
        );
        assertGe(afterSnapshot.timelockWETH, beforeSnapshot.timelockWETH, "Timelock WETH balance should not decrease");
        assertGt(beforeSnapshot.dopplerAsset, 0, "Doppler should have unsold tokens");
        assertGt(beforeSnapshot.dopplerETH, 0, "Doppler should have ETH proceeds");
        assertEq(afterSnapshot.dopplerAsset, 0, "Doppler should have no asset left");
        assertEq(afterSnapshot.dopplerETH, 0, "Doppler should have no ETH left");
        assertEq(ERC20(asset).balanceOf(address(migrator)), 0, "Migrator should have no asset left");
        assertEq(ERC20(weth).balanceOf(address(migrator)), 0, "Migrator should have no WETH left");
        assertTrue(timelockAssetDust > 0 || timelockWETHDust > 0, "Timelock should receive dust tokens");
        assertEq(afterSnapshot.lockerNftCount - beforeSnapshot.lockerNftCount, 1, "Locker should have got one NFT");
    }

    function _assertDopplerInitialState(
        address hook
    ) internal view {
        (uint256 initialTokensSold, uint256 initialProceeds) = (0, 0);
        (,, initialTokensSold, initialProceeds,,) = Doppler(payable(hook)).state();
        assertEq(initialTokensSold, 0, "Should start with no tokens sold");
        assertEq(initialProceeds, 0, "Should start with no proceeds");
    }
}
