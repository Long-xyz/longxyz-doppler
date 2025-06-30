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
import { IPositionManager } from "@v4-periphery/interfaces/IPositionManager.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { BaseTest } from "test/shared/BaseTest.sol";
import { DopplerImplementation } from "test/shared/DopplerImplementation.sol";
import { MineV4Params, mineV4 } from "test/shared/AirlockMiner.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { Airlock, AssetData, ModuleState, CreateParams } from "src/Airlock.sol";
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

contract BaseTestExtension is BaseTest {
    function buyUntilMinProceeds() internal returns (uint256 totalBought, uint256 totalSpent) {
        while (true) {
            (uint256 bought, uint256 spent) = buyExactIn(hook.minimumProceeds());
            totalBought += bought;
            totalSpent += spent;

            (,,, uint256 totalProceeds,,) = hook.state();
            if (totalProceeds > hook.minimumProceeds()) break;

            goToNextEpoch();
        }
    }

    function buyUntilMaxProceeds() internal returns (uint256 totalBought, uint256 totalSpent) {
        while (true) {
            (uint256 bought, uint256 spent) = buyExactIn(hook.maximumProceeds());
            totalBought += bought;
            totalSpent += spent;

            (,,, uint256 totalProceeds,,) = hook.state();
            if (totalProceeds > hook.maximumProceeds()) break;

            goToNextEpoch();
        }
    }
}

contract V3MigratorTest is BaseTestExtension {
    using StateLibrary for IPoolManager;

    address constant DEFAULT_INTEGRATOR = address(0x4444);
    address constant DEFAULT_MIGRATOR_OWNER = address(0x3333);
    address constant DEFAULT_DOPPLER_FEE_RECEIVER = address(0x2222);
    address constant DEFAULT_INTEGRATOR_FEE_RECEIVER = address(0x1111);

    uint256 public constant DEFAULT_MIN_PROCEEDS = 10 ether;
    uint256 public constant DEFAULT_MAX_PROCEEDS = 50 ether;

    address public weth;
    IUniswapV3Factory public factory = IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE);
    INonfungiblePositionManager public nfpm = INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE);
    IBaseSwapRouter02 public v3Router = IBaseSwapRouter02(UNISWAP_V3_ROUTER_02_BASE);

    SetupContractsOptions public options;
    SetupContractsResult public s;

    function setUp() public override {
        vm.createSelectFork(vm.envString("BASE_MAINNET_RPC_URL"), 31_118_046);

        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        vm.label(address(swapRouter), "SwapRouter");

        weth = address(v3Router.WETH9());

        options = SetupContractsOptions({
            feeTier: 10_000,
            dopplerSaleDuration: SALE_DURATION,
            dopplerTickSpacing: 20,
            integrator: DEFAULT_INTEGRATOR,
            migratorOwner: DEFAULT_MIGRATOR_OWNER,
            dopplerFeeReceiver: DEFAULT_DOPPLER_FEE_RECEIVER,
            integratorFeeReceiver: DEFAULT_INTEGRATOR_FEE_RECEIVER,
            isToken0: true,
            ethNumeraire: false
        });
    }

    function test_migrate_BasicScenario() public {
        _setupContracts();

        goToStartingTime();
        buyUntilMinProceeds();

        _migrateExpectRevert();

        goToEndingTime();
        _migrate();
    }

    function test_migrate_WithMaxProceeds() public {
        _setupContracts();

        goToStartingTime();
        buyUntilMaxProceeds();
        _migrate();
    }

    // Run this with more gas limit and increase iterations in AirlockMiner mineV4

    // function testFuzz_migrate_WithVariousOptions(
    //     uint256 feeTierOption,
    //     uint256 dopplerSaleDuration,
    //     uint256 dopplerTickSpacingOption,
    //     bool isToken0,
    //     bool ethNumeraire
    // ) public {
    //     uint24 feeTier;
    //     feeTierOption = bound(feeTierOption, 0, 2);
    //     if (feeTierOption == 0) {
    //         feeTier = 10_000;
    //     } else if (feeTierOption == 1) {
    //         feeTier = 3000;
    //     } else {
    //         feeTier = 500;
    //     }

    //     int24 dopplerTickSpacing;
    //     dopplerTickSpacingOption = bound(dopplerTickSpacingOption, 0, 2);
    //     if (dopplerTickSpacingOption == 0) {
    //         dopplerTickSpacing = 10;
    //     } else if (dopplerTickSpacingOption == 1) {
    //         dopplerTickSpacing = 20;
    //     } else {
    //         dopplerTickSpacing = 30;
    //     }

    //     dopplerSaleDuration = bound(dopplerSaleDuration, 6 hours / DEFAULT_EPOCH_LENGTH, 10 days / DEFAULT_EPOCH_LENGTH)
    //         * DEFAULT_EPOCH_LENGTH;

    //     options.feeTier = feeTier;
    //     options.dopplerSaleDuration = dopplerSaleDuration;
    //     options.dopplerTickSpacing = dopplerTickSpacing;
    //     options.isToken0 = isToken0;
    //     options.ethNumeraire = ethNumeraire;

    //     _setupContracts();

    //     goToStartingTime();
    //     buyUntilMinProceeds();

    //     _migrateExpectRevert();

    //     goToEndingTime();
    //     _migrate();
    // }

    function _migrate() internal {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        vm.assume(sqrtPriceX96 > TickMath.MIN_SQRT_PRICE * 2 && sqrtPriceX96 < TickMath.MAX_SQRT_PRICE / 2);

        BalanceSnapshot memory beforeSnapshot = _getBalancesAndPrices();
        s.airlock.migrate(s.asset);
        BalanceSnapshot memory afterSnapshot = _getBalancesAndPrices();
        _assertBalancesAndPrices(beforeSnapshot, afterSnapshot);
    }

    function _migrateExpectRevert() internal {
        vm.expectRevert(abi.encodeWithSelector(CannotMigrate.selector));
        s.airlock.migrate(s.asset);
    }

    struct BalanceSnapshot {
        uint256 dopplerAsset;
        uint256 dopplerNumeraire;
        uint256 poolManagerAsset;
        uint256 poolManagerNumeraire;
        uint256 timelockAsset;
        uint256 timelockNumeraire;
        uint256 airlockAsset;
        uint256 airlockNumeraire;
        uint256 v3PoolAsset;
        uint256 v3PoolNumeraire;
        uint256 lockerNftCount;
        uint160 poolPrice;
        uint160 migrationPoolPrice;
    }

    function _getBalancesAndPrices() internal view returns (BalanceSnapshot memory) {
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            Doppler(payable(s.hook)).poolKey();

        PoolKey memory poolKey =
            PoolKey({ currency0: currency0, currency1: currency1, hooks: hooks, fee: fee, tickSpacing: tickSpacing });

        (uint160 poolPrice,,,) = s.deployer.poolManager().getSlot0(poolKey.toId());
        (uint160 migrationPoolPrice,,,,,,) = IUniswapV3Pool(s.migrationPool).slot0();

        return BalanceSnapshot({
            dopplerAsset: _balanceOf(s.asset, s.hook),
            dopplerNumeraire: _balanceOf(s.numeraire, s.hook),
            poolManagerAsset: _balanceOf(s.asset, address(manager)),
            poolManagerNumeraire: _balanceOf(s.numeraire, address(manager)),
            timelockAsset: _balanceOf(s.asset, s.timelock),
            timelockNumeraire: _balanceOf(s.numeraire, s.timelock),
            airlockAsset: _balanceOf(s.asset, address(s.airlock)),
            airlockNumeraire: _balanceOf(s.numeraire, address(s.airlock)),
            v3PoolAsset: _balanceOf(s.asset, s.migrationPool),
            v3PoolNumeraire: _balanceOf(s.numeraire, s.migrationPool),
            lockerNftCount: ERC721(address(nfpm)).balanceOf(address(s.migrator.CUSTOM_V3_LOCKER())),
            poolPrice: poolPrice,
            migrationPoolPrice: migrationPoolPrice
        });
    }

    function _balanceOf(address token, address account) internal view returns (uint256) {
        if (token == address(0)) {
            return account.balance + ERC20(weth).balanceOf(account);
        } else {
            return ERC20(token).balanceOf(account);
        }
    }

    function _assertBalancesAndPrices(
        BalanceSnapshot memory beforeSnapshot,
        BalanceSnapshot memory afterSnapshot
    ) internal view {
        uint256 assetTakenFromPoolManager = beforeSnapshot.poolManagerAsset - afterSnapshot.poolManagerAsset;
        uint256 numeraireTakenFromPoolManager = beforeSnapshot.poolManagerNumeraire - afterSnapshot.poolManagerNumeraire;

        uint256 assetFeesRetained = afterSnapshot.airlockAsset - beforeSnapshot.airlockAsset;
        uint256 numeraireFeesRetained = afterSnapshot.airlockNumeraire - beforeSnapshot.airlockNumeraire;

        uint256 totalAssetMigrated = beforeSnapshot.dopplerAsset + assetTakenFromPoolManager;
        uint256 totalNumeraireMigrated = beforeSnapshot.dopplerNumeraire + numeraireTakenFromPoolManager;

        uint256 timelockAssetDust = afterSnapshot.timelockAsset - beforeSnapshot.timelockAsset;
        uint256 timelockNumeraireDust = afterSnapshot.timelockNumeraire - beforeSnapshot.timelockNumeraire;

        assertEq(
            afterSnapshot.v3PoolAsset + timelockAssetDust + assetFeesRetained,
            totalAssetMigrated,
            "Asset balance invariant: v3 pool + timelock dust + fees should equal total migrated"
        );

        assertEq(
            afterSnapshot.v3PoolNumeraire + timelockNumeraireDust + numeraireFeesRetained,
            totalNumeraireMigrated,
            "Numeraire balance invariant: v3 pool + timelock dust + fees should equal total numeraire migrated"
        );

        assertGe(
            afterSnapshot.timelockAsset, beforeSnapshot.timelockAsset, "Timelock asset balance should not decrease"
        );
        assertGe(
            afterSnapshot.timelockNumeraire,
            beforeSnapshot.timelockNumeraire,
            "Timelock numeraire balance should not decrease"
        );
        assertGt(beforeSnapshot.dopplerAsset, 0, "Doppler should have unsold tokens");
        assertGt(beforeSnapshot.dopplerNumeraire, 0, "Doppler should have numeraire proceeds");
        assertEq(afterSnapshot.dopplerAsset, 0, "Doppler should have no asset left");
        assertEq(afterSnapshot.dopplerNumeraire, 0, "Doppler should have no numeraire left");
        assertEq(_balanceOf(s.asset, address(s.migrator)), 0, "Migrator should have no asset left");
        assertEq(_balanceOf(s.numeraire, address(s.migrator)), 0, "Migrator should have no numeraire left");
        assertTrue(timelockAssetDust > 0 || timelockNumeraireDust > 0, "Timelock should receive dust tokens");
        assertEq(afterSnapshot.lockerNftCount - beforeSnapshot.lockerNftCount, 1, "Locker should have got one NFT");
        assertEq(afterSnapshot.poolPrice, beforeSnapshot.poolPrice, "Pool price should not change");

        if (s.ethNumeraire) {
            if (s.asset > address(weth)) {
                assertEq(
                    afterSnapshot.migrationPoolPrice,
                    beforeSnapshot.poolPrice,
                    "Migration pool price should be the pool price"
                );
            } else {
                uint160 inversePrice = uint160((1 << 192) / beforeSnapshot.poolPrice);
                assertEq(
                    afterSnapshot.migrationPoolPrice,
                    inversePrice,
                    "Migration pool price should be the inverse of the pool price"
                );
            }
        }
    }

    struct SetupContractsOptions {
        uint24 feeTier;
        uint256 dopplerSaleDuration;
        int24 dopplerTickSpacing;
        address integrator;
        address migratorOwner;
        address dopplerFeeReceiver;
        address integratorFeeReceiver;
        bool isToken0;
        bool ethNumeraire;
    }

    struct SetupContractsResult {
        CustomUniswapV3Migrator migrator;
        uint24 feeTier;
        int24 tickSpacing;
        int24 minUsableTick;
        int24 maxUsableTick;
        Airlock airlock;
        DopplerDeployer deployer;
        UniswapV4Initializer initializer;
        TokenFactory tokenFactory;
        GovernanceFactory governanceFactory;
        address integrator;
        address numeraire;
        bytes32 salt;
        address hook;
        address asset;
        address pool;
        address governance;
        address timelock;
        address migrationPool;
        address migratorOwner;
        address dopplerFeeReceiver;
        address integratorFeeReceiver;
        bool isToken0;
        bool ethNumeraire;
    }

    function _setupContracts() internal {
        SetupContractsResult memory zero;
        s = zero;

        bool isInitializerToken0 = options.ethNumeraire ? false : options.isToken0;

        s.airlock = new Airlock(address(this));
        s.deployer = new DopplerDeployer(manager);
        s.initializer = new UniswapV4Initializer(address(s.airlock), manager, s.deployer);
        s.migrator = new CustomUniswapV3Migrator(
            options.migratorOwner, address(s.airlock), nfpm, v3Router, options.dopplerFeeReceiver, options.feeTier
        );
        s.tokenFactory = new TokenFactory(address(s.airlock));
        s.governanceFactory = new GovernanceFactory(address(s.airlock));
        s.integrator = makeAddr("integrator");
        s.feeTier = options.feeTier;
        s.tickSpacing = factory.feeAmountTickSpacing(options.feeTier);
        s.minUsableTick = TickMath.minUsableTick(s.tickSpacing);
        s.maxUsableTick = TickMath.maxUsableTick(s.tickSpacing);
        s.migratorOwner = options.migratorOwner;
        s.dopplerFeeReceiver = options.dopplerFeeReceiver;
        s.integratorFeeReceiver = options.integratorFeeReceiver;
        s.isToken0 = options.isToken0;
        s.ethNumeraire = options.ethNumeraire;
        assertNotEq(s.tickSpacing, 0, "Tick spacing should be non-zero");
        assertEq(s.migrator.FEE_TIER(), options.feeTier);

        address[] memory modules = new address[](4);
        modules[0] = address(s.tokenFactory);
        modules[1] = address(s.governanceFactory);
        modules[2] = address(s.initializer);
        modules[3] = address(s.migrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;

        s.airlock.setModuleState(modules, states);

        if (!options.ethNumeraire) {
            // set the numeraire to a mid value to avoid issues with salt mining
            s.numeraire = address(0x8000000000000000000000000000000000000000);
            deployCodeTo("TestERC20.sol:TestERC20", abi.encode(uint256(2 ** 128)), s.numeraire);
            vm.label(s.numeraire, "Numeraire");
            TestERC20(s.numeraire).approve(address(swapRouter), type(uint256).max);
        } else {
            vm.deal(address(this), 2 ** 128);
        }

        address migratorNumeraire = options.ethNumeraire ? address(weth) : address(s.numeraire);
        address minimumAddress;
        address maximumAddress;
        if (options.isToken0) {
            minimumAddress = address(0);
            maximumAddress = migratorNumeraire;
        } else {
            minimumAddress = migratorNumeraire;
            maximumAddress = address(type(uint160).max);
        }

        bytes memory liquidityMigratorData = abi.encode(options.integratorFeeReceiver);

        int24 startTick_ =
            _computeValidTick(options.dopplerTickSpacing, isInitializerToken0 ? DEFAULT_END_TICK : DEFAULT_START_TICK);
        int24 endTick_ =
            _computeValidTick(options.dopplerTickSpacing, isInitializerToken0 ? DEFAULT_START_TICK : DEFAULT_END_TICK);

        bytes memory poolInitializerData = abi.encode(
            DEFAULT_MIN_PROCEEDS,
            DEFAULT_MAX_PROCEEDS,
            vm.getBlockTimestamp(),
            vm.getBlockTimestamp() + options.dopplerSaleDuration,
            startTick_,
            endTick_,
            DEFAULT_EPOCH_LENGTH,
            _computeValidGamma(),
            isInitializerToken0,
            DEFAULT_NUM_PD_SLUGS,
            DEFAULT_FEE,
            options.dopplerTickSpacing
        );

        bytes memory tokenFactoryData =
            abi.encode("Test Token", "TEST", 0, 0, new address[](0), new uint256[](0), "TOKEN_URI");

        MineV4Params memory params = MineV4Params({
            airlock: address(s.airlock),
            poolManager: address(manager),
            initialSupply: 2 ** 128,
            numTokensToSell: DEFAULT_NUM_TOKENS_TO_SELL,
            numeraire: s.numeraire,
            tokenFactory: ITokenFactory(address(s.tokenFactory)),
            tokenFactoryData: tokenFactoryData,
            poolInitializer: UniswapV4Initializer(address(s.initializer)),
            poolInitializerData: poolInitializerData
        });

        (s.salt, s.hook, s.asset) = mineV4(params, minimumAddress, maximumAddress);

        if (options.isToken0) {
            assertLt(uint160(s.asset), uint160(migratorNumeraire), "Asset should be less than numeraire");
        } else {
            assertGt(uint160(s.asset), uint160(migratorNumeraire), "Asset should be greater than numeraire");
        }

        // Setting variables from BaseTest
        asset = s.asset;
        numeraire = s.numeraire;
        hook = DopplerImplementation(payable(s.hook));
        token0 = isInitializerToken0 ? s.asset : s.numeraire;
        token1 = isInitializerToken0 ? s.numeraire : s.asset;
        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: options.dopplerTickSpacing,
            hooks: IHooks(s.hook)
        });
        poolId = key.toId();
        isToken0 = isInitializerToken0;
        usingEth = options.ethNumeraire;
        startTick = startTick_;
        endTick = endTick_;
        uint24 protocolFee = uint24(vm.envOr("PROTOCOL_FEE", uint256(0)));
        protocolFee = (uint24(protocolFee) << 12) | uint24(protocolFee);
        if (protocolFee > 0) {
            vm.startPrank(address(0));
            manager.setProtocolFee(key, protocolFee);
            vm.stopPrank();
        }

        CreateParams memory createParams = CreateParams({
            initialSupply: 2 ** 128,
            numTokensToSell: DEFAULT_NUM_TOKENS_TO_SELL,
            numeraire: s.numeraire,
            tokenFactory: ITokenFactory(address(s.tokenFactory)),
            tokenFactoryData: tokenFactoryData,
            governanceFactory: IGovernanceFactory(address(s.governanceFactory)),
            governanceFactoryData: abi.encode("Test Token", 7200, 50_400, 0),
            poolInitializer: IPoolInitializer(address(s.initializer)),
            poolInitializerData: poolInitializerData,
            liquidityMigrator: ILiquidityMigrator(address(s.migrator)),
            liquidityMigratorData: liquidityMigratorData,
            integrator: s.integrator,
            salt: s.salt
        });

        (, s.pool, s.governance, s.timelock, s.migrationPool) = s.airlock.create(createParams);

        (address miratorToken0, address migratorToken1) =
            s.asset < migratorNumeraire ? (s.asset, migratorNumeraire) : (migratorNumeraire, s.asset);
        address createdMigrationPool =
            IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE).getPool(miratorToken0, migratorToken1, s.feeTier);
        assertNotEq(createdMigrationPool, address(0), "Pool should exist");
        assertEq(createdMigrationPool, s.migrationPool, "Pool should match expected tokens");

        (uint160 initialSqrtPriceX96,,,,,,) = IUniswapV3Pool(s.migrationPool).slot0();
        int24 initialTick = TickMath.getTickAtSqrtPrice(initialSqrtPriceX96);

        int24 tickSpacing = IUniswapV3Pool(s.migrationPool).tickSpacing();
        bool isAssetToken0 = s.asset < migratorNumeraire;
        int24 expectedInitialTick = isAssetToken0
            ? TickMath.minUsableTick(tickSpacing) + tickSpacing
            : TickMath.maxUsableTick(tickSpacing) - tickSpacing;
        assertEq(initialTick, expectedInitialTick, "Pool should be initialized at extreme tick");

        (uint256 initialTokensSold, uint256 initialProceeds) = (0, 0);
        (,, initialTokensSold, initialProceeds,,) = Doppler(payable(s.hook)).state();
        assertEq(initialTokensSold, 0, "Should start with no tokens sold");
        assertEq(initialProceeds, 0, "Should start with no proceeds");
    }

    function _computeValidGamma() internal view returns (int24 gamma) {
        uint256 minGamma = options.dopplerSaleDuration / DEFAULT_EPOCH_LENGTH;
        uint256 safeGamma = minGamma + 1;
        gamma = int24(
            int256(
                (
                    (safeGamma + uint256(int256(options.dopplerTickSpacing)) - 1)
                        / uint256(int256(options.dopplerTickSpacing))
                ) * uint256(int256(options.dopplerTickSpacing))
            )
        );
        if (gamma < options.dopplerTickSpacing * 2) {
            gamma = options.dopplerTickSpacing * 2;
        }
    }

    function _computeValidTick(int24 tickSpacing, int24 tick) internal pure returns (int24) {
        int24 compressedTick = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressedTick--;
        return compressedTick * tickSpacing;
    }
}
