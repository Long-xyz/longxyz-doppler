// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test, console, Vm } from "forge-std/Test.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { ERC721 } from "@solady/tokens/ERC721.sol";
import { CustomUniswapV3Migrator } from "src/extensions/CustomUniswapV3Migrator.sol";
import { ICustomUniswapV3Migrator } from "src/extensions/interfaces/ICustomUniswapV3Migrator.sol";
import { INonfungiblePositionManager } from "src/extensions/interfaces/INonfungiblePositionManager.sol";
import { IUniswapV3Factory, IBaseSwapRouter02 } from "src/extensions/CustomUniswapV3Migrator.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import { CustomUniswapV3Locker } from "src/extensions/CustomUniswapV3Locker.sol";
import {
    UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE,
    UNISWAP_V3_FACTORY_BASE,
    WETH_BASE,
    UNISWAP_V3_ROUTER_02_BASE
} from "test/shared/Addresses.sol";

contract CustomUniswapV3MigratorTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event IncreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    CustomUniswapV3Migrator public migrator;
    IUniswapV3Factory public factory;
    INonfungiblePositionManager public nfpm;

    uint24 constant FEE_TIER = 10_000;
    address constant DOPPLER_FEE_RECEIVER = address(0x2222);
    address constant INTEGRATOR_FEE_RECEIVER = address(0x1111);

    bytes public liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER);

    // Common price ratios for testing
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336; // sqrt(1) * 2^96
    uint160 constant SQRT_PRICE_3_2 = 97_129_730_664_471_554_368_111_755_648; // sqrt(1.5) * 2^96
    uint160 constant SQRT_PRICE_2_1 = 112_045_541_949_572_279_837_463_876_454; // sqrt(2) * 2^96
    uint160 constant SQRT_PRICE_1_2 = 56_022_770_974_786_139_918_731_938_227; // sqrt(0.5) * 2^96

    // Helper struct for comprehensive balance tracking
    struct BalanceSnapshot {
        uint256 migratorToken0;
        uint256 migratorToken1;
        uint256 migratorETH;
        uint256 recipientToken0;
        uint256 recipientToken1;
        uint256 recipientETH;
        uint256 recipientWETH;
        uint256 poolToken0;
        uint256 poolToken1;
        uint256 lockerNftCount;
        uint256 airlockToken0;
        uint256 airlockToken1;
        uint256 airlockETH;
        uint256 airlockWETH;
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_MAINNET_RPC_URL"), 31_118_046);

        factory = IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE);
        nfpm = INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE);

        migrator = new CustomUniswapV3Migrator(
            address(this), nfpm, IBaseSwapRouter02(UNISWAP_V3_ROUTER_02_BASE), DOPPLER_FEE_RECEIVER, FEE_TIER
        );
    }

    function test_constantValues() public view {
        assertEq(address(migrator.NONFUNGIBLE_POSITION_MANAGER()), UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE);
        assertEq(address(migrator.FACTORY()), UNISWAP_V3_FACTORY_BASE);
        assertEq(address(migrator.WETH()), WETH_BASE);
        assertEq(migrator.FEE_TIER(), FEE_TIER);
        assertTrue(address(migrator.CUSTOM_V3_LOCKER()) != address(0), "Locker should be deployed");
    }

    function test_receive_ReceivesETHFromAirlock() public {
        uint256 preBalance = address(migrator).balance;
        deal(address(this), 1 ether);
        payable(address(migrator)).transfer(1 ether);
        assertEq(address(migrator).balance, preBalance + 1 ether, "Wrong balance");
    }

    function test_initialize_CreatesPair() public {
        address token0 = address(0x1111);
        address token1 = address(0x2222);
        address pair = migrator.initialize(token0, token1, liquidityMigratorData);
        assertEq(pair, IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE).getPool(token0, token1, FEE_TIER), "Wrong pair");
    }

    function test_initialize_DoesNotFailWhenPairIsAlreadyCreated() public {
        address token0 = address(0x1111);
        address token1 = address(0x2222);
        IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE).createPool(token0, token1, FEE_TIER);
        address pair = migrator.initialize(token0, token1, liquidityMigratorData);
        assertEq(pair, IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE).getPool(token0, token1, FEE_TIER), "Wrong pair");
    }

    function test_initialize_RevertsWithEmptyData() public {
        vm.expectRevert(abi.encodeWithSelector(ICustomUniswapV3Migrator.EmptyLiquidityMigratorData.selector));
        migrator.initialize(address(0x1111), address(0x2222), "");
    }

    function test_initialize_RevertsWithZeroFeeReceiver() public {
        bytes memory invalidData = abi.encode(address(0));
        vm.expectRevert(abi.encodeWithSelector(ICustomUniswapV3Migrator.ZeroFeeReceiverAddress.selector));
        migrator.initialize(address(0x1111), address(0x2222), invalidData);
    }

    function test_initialize_UsesWETHForNumeraireZero() public {
        TestERC20 token = new TestERC20(1e30);

        address pool = migrator.initialize(address(token), address(0), liquidityMigratorData);

        address weth = address(migrator.WETH());
        (address token0, address token1) = _sortTokens(address(token), weth);

        assertEq(pool, IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE).getPool(token0, token1, FEE_TIER), "Wrong pool");
    }

    function test_initialize_SetsPoolFeeReceivers() public {
        address token0 = address(0x3333);
        address token1 = address(0x4444);

        address pool = migrator.initialize(token0, token1, liquidityMigratorData);
        assertEq(migrator.poolFeeReceivers(pool), INTEGRATOR_FEE_RECEIVER, "Wrong fee receiver");
    }

    function test_initialize_InitializesPoolAtExtremePrice() public {
        TestERC20 tokenA = new TestERC20(1e30);
        TestERC20 tokenB = new TestERC20(1e30);

        (address token0, address token1) = _sortTokens(address(tokenA), address(tokenB));

        address pool = migrator.initialize(token0, token1, liquidityMigratorData);
        _assertPoolInitialized(pool);

        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        int24 tickSpacing = 200;
        int24 expectedTick = address(tokenA) == token0
            ? TickMath.minUsableTick(tickSpacing) + tickSpacing
            : TickMath.maxUsableTick(tickSpacing) - tickSpacing;

        assertEq(tick, expectedTick, "Pool should be initialized at extreme tick");
    }

    function test_migrate_RevertsWhenSenderNotAirlock() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(SenderNotAirlock.selector);
        migrator.migrate(uint160(0), address(0x1111), address(0x2222), address(0));
    }

    function test_migrate_RevertsWhenPoolDoesNotExist() public {
        TestERC20 token0 = new TestERC20(1e30);
        TestERC20 token1 = new TestERC20(1e30);

        token0.transfer(address(migrator), 1e28);
        token1.transfer(address(migrator), 1e28);

        vm.expectRevert(abi.encodeWithSelector(ICustomUniswapV3Migrator.PoolDoesNotExist.selector));
        migrator.migrate(SQRT_PRICE_1_1, address(token0), address(token1), address(0xbeef));
    }

    function test_migrate_RevertsWhenZeroAmounts() public {
        TestERC20 tokenA = new TestERC20(type(uint256).max);
        TestERC20 tokenB = new TestERC20(type(uint256).max);

        (address token0, address token1) = _sortTokens(address(tokenA), address(tokenB));

        address pool = migrator.initialize(token0, token1, liquidityMigratorData);
        _assertPoolInitialized(pool);

        vm.expectRevert();
        migrator.migrate(SQRT_PRICE_1_1, token0, token1, address(0xbeef));
    }

    function test_migrate_BasicScenario() public {
        uint24 testFeeTier = 3000;
        migrator = _setupMigratorWithFeeTier(testFeeTier);

        (TestERC20 tokenA, TestERC20 tokenB, address token0, address token1) = _createTokenPair();

        address pool = migrator.initialize(token0, token1, liquidityMigratorData);
        _assertPoolInitialized(pool);

        assertEq(migrator.poolFeeReceivers(pool), INTEGRATOR_FEE_RECEIVER, "Fee receiver should be registered");

        uint256 transferAmount0 = 1e24;
        uint256 transferAmount1 = 1e24;
        _transferTokensToMigrator(tokenA, tokenB, token0, transferAmount0, transferAmount1);

        uint160 targetPrice = SQRT_PRICE_3_2;
        address recipient = address(0xbeef);

        BalanceSnapshot memory before = _getBalances(token0, token1, recipient, pool);
        uint256 liquidity = migrator.migrate(targetPrice, token0, token1, recipient);
        BalanceSnapshot memory afterMigration = _getBalances(token0, token1, recipient, pool);

        _assertMigrationPoolState(pool, targetPrice, liquidity);

        int24 tickSpacing = factory.feeAmountTickSpacing(testFeeTier);
        (int24 tickLower, int24 tickUpper) = _getTickRange(targetPrice, tickSpacing);
        bool isExtreme = _isExtremePrice(targetPrice, tickLower, tickUpper);
        _assertBalances(before, afterMigration, isExtreme);
    }

    function test_migrate_PreInitializedPool() public {
        uint24 testFeeTier = 3000;
        migrator = _setupMigratorWithFeeTier(testFeeTier);

        (TestERC20 tokenA, TestERC20 tokenB, address token0, address token1) = _createTokenPair();

        address pool = factory.createPool(token0, token1, testFeeTier);
        assertNotEq(factory.getPool(token0, token1, testFeeTier), address(0), "Pool should be created");
        IUniswapV3Pool(pool).initialize(SQRT_PRICE_1_1);
        _assertPoolInitialized(pool);

        address existingPool = migrator.initialize(token0, token1, liquidityMigratorData);
        assertEq(existingPool, pool, "Pool addresses should be the same");

        uint256 transferAmount0 = 1e24;
        uint256 transferAmount1 = 1e24;
        _transferTokensToMigrator(tokenA, tokenB, token0, transferAmount0, transferAmount1);

        uint160 targetPrice = SQRT_PRICE_3_2;
        address recipient = address(0xbeef);

        BalanceSnapshot memory before = _getBalances(token0, token1, recipient, pool);
        uint256 liquidity = migrator.migrate(targetPrice, token0, token1, recipient);
        BalanceSnapshot memory afterMigration = _getBalances(token0, token1, recipient, pool);

        _assertMigrationPoolState(pool, targetPrice, liquidity);

        int24 tickSpacing = factory.feeAmountTickSpacing(testFeeTier);
        (int24 tickLower, int24 tickUpper) = _getTickRange(targetPrice, tickSpacing);
        bool isExtreme = _isExtremePrice(targetPrice, tickLower, tickUpper);
        _assertBalances(before, afterMigration, isExtreme);
    }

    function test_migrate_ETHHandling() public {
        address weth = address(migrator.WETH());
        TestERC20 token = new TestERC20(type(uint256).max);

        (address token0, address token1) = _sortTokens(address(token), weth);

        address pool = migrator.initialize(address(token), address(0), liquidityMigratorData);

        uint256 ethAmount = 10 ether;
        uint256 tokenAmount = 10e18;
        deal(address(migrator), ethAmount);
        token.transfer(address(migrator), tokenAmount);

        uint160 targetPrice = SQRT_PRICE_3_2;
        address recipient = address(0xbeef);

        BalanceSnapshot memory before = _getBalances(token0, token1, recipient, pool);
        uint256 liquidity = migrator.migrate(targetPrice, token0, token1, recipient);
        BalanceSnapshot memory afterSnapshot = _getBalances(token0, token1, recipient, pool);

        _assertMigrationPoolState(pool, targetPrice, liquidity);

        int24 tickSpacing = factory.feeAmountTickSpacing(FEE_TIER);
        (int24 tickLower, int24 tickUpper) = _getTickRange(targetPrice, tickSpacing);
        bool isExtreme = _isExtremePrice(targetPrice, tickLower, tickUpper);
        _assertBalances(before, afterSnapshot, isExtreme);
    }

    function test_migrate_DifferentPriceScenarios() public {
        _testMigrationAtPrice(SQRT_PRICE_1_2);
        _testMigrationAtPrice(SQRT_PRICE_3_2);
        _testMigrationAtPrice(SQRT_PRICE_2_1);
    }

    function testFuzz_initialize_WithVariousAddresses(
        address asset,
        address numeraire,
        address integratorFeeReceiver
    ) public {
        vm.assume(asset != address(0));
        vm.assume(integratorFeeReceiver != address(0));
        vm.assume(asset != numeraire);

        vm.assume(uint160(asset) > 255);
        vm.assume(uint160(numeraire) > 255 || numeraire == address(0));
        vm.assume(uint160(integratorFeeReceiver) > 255);

        bytes memory fuzzData = abi.encode(integratorFeeReceiver);

        address pool = migrator.initialize(asset, numeraire, fuzzData);
        _assertPoolInitialized(pool);

        address expectedNumeraire = numeraire == address(0) ? address(migrator.WETH()) : numeraire;
        (address token0, address token1) = _sortTokens(asset, expectedNumeraire);

        assertEq(pool, factory.getPool(token0, token1, FEE_TIER), "Pool address mismatch");
        assertEq(migrator.poolFeeReceivers(pool), integratorFeeReceiver, "Fee receiver mismatch");
    }

    function testFuzz_migrate_WithVariousPrices(
        uint160 targetSqrtPriceX96
    ) public {
        uint256 bounded = bound(
            uint256(targetSqrtPriceX96),
            uint256(79_228_162_514_264_337_593_543_950_336) / 100, // 0.01x price
            uint256(79_228_162_514_264_337_593_543_950_336) * 100 // 100x price
        );
        targetSqrtPriceX96 = uint160(bounded);

        TestERC20 tokenA = new TestERC20(type(uint256).max);
        TestERC20 tokenB = new TestERC20(type(uint256).max);

        (address token0, address token1) = _sortTokens(address(tokenA), address(tokenB));

        address pool = migrator.initialize(token0, token1, liquidityMigratorData);
        _assertPoolInitialized(pool);

        uint256 amount = 1e24;
        _transferTokensToMigrator(tokenA, tokenB, token0, amount, amount);

        address recipient = address(0xbeef);

        BalanceSnapshot memory before = _getBalances(token0, token1, recipient, pool);
        uint256 liquidity = migrator.migrate(targetSqrtPriceX96, token0, token1, recipient);
        BalanceSnapshot memory afterMigration = _getBalances(token0, token1, recipient, pool);

        _assertMigrationPoolState(pool, targetSqrtPriceX96, liquidity);

        int24 tickSpacing = factory.feeAmountTickSpacing(FEE_TIER);
        (int24 tickLower, int24 tickUpper) = _getTickRange(targetSqrtPriceX96, tickSpacing);
        bool isExtreme = _isExtremePrice(targetSqrtPriceX96, tickLower, tickUpper);
        _assertBalances(before, afterMigration, isExtreme);
    }

    function testFuzz_migrate_WithVariousAmounts(uint128 amount0, uint128 amount1) public {
        amount0 = uint128(bound(amount0, 1e18, 1e30));
        amount1 = uint128(bound(amount1, 1e18, 1e30));

        TestERC20 tokenA = new TestERC20(type(uint256).max);
        TestERC20 tokenB = new TestERC20(type(uint256).max);

        (address token0, address token1) = _sortTokens(address(tokenA), address(tokenB));

        address pool = migrator.initialize(token0, token1, liquidityMigratorData);

        _transferTokensToMigrator(tokenA, tokenB, token0, amount0, amount1);

        address recipient = address(0xbeef);

        uint160 targetSqrtPriceX96 = SQRT_PRICE_3_2;
        BalanceSnapshot memory before = _getBalances(token0, token1, recipient, pool);
        uint256 liquidity = migrator.migrate(targetSqrtPriceX96, token0, token1, recipient);
        BalanceSnapshot memory afterMigration = _getBalances(token0, token1, recipient, pool);

        _assertMigrationPoolState(pool, targetSqrtPriceX96, liquidity);

        int24 tickSpacing = factory.feeAmountTickSpacing(FEE_TIER);
        (int24 tickLower, int24 tickUpper) = _getTickRange(targetSqrtPriceX96, tickSpacing);
        bool isExtreme = _isExtremePrice(targetSqrtPriceX96, tickLower, tickUpper);
        _assertBalances(before, afterMigration, isExtreme);
    }

    function testFuzz_migrate_AtVariousTicks(
        int24 targetTick
    ) public {
        uint24 testFeeTier = 500;
        int24 tickSpacing = 10;

        targetTick = int24(bound(targetTick, -46_000, 46_000));
        targetTick = (targetTick / tickSpacing) * tickSpacing;

        migrator = _setupMigratorWithFeeTier(testFeeTier);

        TestERC20 tokenA = new TestERC20(type(uint256).max);
        TestERC20 tokenB = new TestERC20(type(uint256).max);

        (address token0, address token1) = _sortTokens(address(tokenA), address(tokenB));

        address pool = migrator.initialize(token0, token1, liquidityMigratorData);
        _assertPoolInitialized(pool);

        (uint160 initialSqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 initialTick = TickMath.getTickAtSqrtPrice(initialSqrtPriceX96);
        bool isAssetToken0 = (address(tokenA) == token0 && address(tokenB) == token1)
            || (address(tokenB) == token0 && address(tokenA) == token1);
        if (isAssetToken0) {
            assertLt(initialTick, 0, "Tick should be negative when asset is token0");
        } else {
            assertGt(initialTick, 0, "Tick should be positive when asset is token1");
        }

        uint256 amount = 1e24;
        _transferTokensToMigrator(tokenA, tokenB, token0, amount, amount);

        uint160 targetSqrtPriceX96 = TickMath.getSqrtPriceAtTick(targetTick);
        address recipient = address(0xbeef);

        BalanceSnapshot memory before = _getBalances(token0, token1, recipient, pool);
        uint256 liquidity = migrator.migrate(targetSqrtPriceX96, token0, token1, recipient);
        BalanceSnapshot memory afterSnapshot = _getBalances(token0, token1, recipient, pool);

        _assertMigrationPoolState(pool, targetSqrtPriceX96, liquidity);

        (int24 tickLower, int24 tickUpper) = _getTickRange(targetSqrtPriceX96, tickSpacing);
        bool isExtreme = _isExtremePrice(targetSqrtPriceX96, tickLower, tickUpper);
        _assertBalances(before, afterSnapshot, isExtreme);
    }

    function _testMigrationAtPrice(
        uint160 targetPrice
    ) internal {
        TestERC20 tokenA = new TestERC20(type(uint256).max);
        TestERC20 tokenB = new TestERC20(type(uint256).max);

        (address token0, address token1) = _sortTokens(address(tokenA), address(tokenB));

        migrator = _setupMigratorWithFeeTier(3000);

        address pool = migrator.initialize(token0, token1, liquidityMigratorData);

        uint256 amount0 = 1e24;
        uint256 amount1 = 1e24;
        _transferTokensToMigrator(tokenA, tokenB, token0, amount0, amount1);

        address recipient = address(0xbeef);

        BalanceSnapshot memory before = _getBalances(token0, token1, recipient, pool);
        uint256 liquidity = migrator.migrate(targetPrice, token0, token1, recipient);
        BalanceSnapshot memory afterSnapshot = _getBalances(token0, token1, recipient, pool);

        int24 tickSpacing = factory.feeAmountTickSpacing(3000);
        (int24 tickLower, int24 tickUpper) = _getTickRange(targetPrice, tickSpacing);
        bool isExtreme = _isExtremePrice(targetPrice, tickLower, tickUpper);
        _assertMigrationPoolState(pool, targetPrice, liquidity);
        _assertBalances(before, afterSnapshot, isExtreme);
    }

    function test_migrate_OnTickBoundary() public {
        uint24 testFeeTier = 3000;
        migrator = _setupMigratorWithFeeTier(testFeeTier);

        int24 boundaryTick = 0;
        uint160 boundaryPrice = TickMath.getSqrtPriceAtTick(boundaryTick);

        TestERC20 tokenA = new TestERC20(type(uint256).max);
        TestERC20 tokenB = new TestERC20(type(uint256).max);

        (address token0, address token1) = _sortTokens(address(tokenA), address(tokenB));

        migrator = _setupMigratorWithFeeTier(3000);

        address pool = migrator.initialize(token0, token1, liquidityMigratorData);

        uint256 amount0 = 1e24;
        uint256 amount1 = 1e24;
        _transferTokensToMigrator(tokenA, tokenB, token0, amount0, amount1);

        address recipient = address(0xbeef);

        BalanceSnapshot memory before = _getBalances(token0, token1, recipient, pool);
        uint256 liquidity = migrator.migrate(boundaryPrice, token0, token1, recipient);
        BalanceSnapshot memory afterSnapshot = _getBalances(token0, token1, recipient, pool);

        _assertMigrationPoolState(pool, boundaryPrice, liquidity);

        int24 tickSpacing = factory.feeAmountTickSpacing(testFeeTier);
        (int24 tickLower, int24 tickUpper) = _getTickRange(boundaryPrice, tickSpacing);
        bool isExtreme = _isExtremePrice(boundaryPrice, tickLower, tickUpper);
        _assertBalances(before, afterSnapshot, isExtreme);
    }

    function _getBalances(
        address token0,
        address token1,
        address recipient,
        address pool
    ) internal view returns (BalanceSnapshot memory) {
        address weth = address(migrator.WETH());
        address airlock = address(migrator.airlock());

        uint256 migratorToken0 = ERC20(token0).balanceOf(address(migrator));
        uint256 migratorToken1 = ERC20(token1).balanceOf(address(migrator));

        if (token0 == weth) {
            migratorToken0 += address(migrator).balance;
        }
        if (token1 == weth) {
            migratorToken1 += address(migrator).balance;
        }

        return BalanceSnapshot({
            migratorToken0: migratorToken0,
            migratorToken1: migratorToken1,
            migratorETH: address(migrator).balance,
            recipientToken0: ERC20(token0).balanceOf(recipient),
            recipientToken1: ERC20(token1).balanceOf(recipient),
            recipientETH: recipient.balance,
            recipientWETH: ERC20(weth).balanceOf(recipient),
            poolToken0: ERC20(token0).balanceOf(pool),
            poolToken1: ERC20(token1).balanceOf(pool),
            lockerNftCount: ERC721(address(nfpm)).balanceOf(address(migrator.CUSTOM_V3_LOCKER())),
            airlockToken0: ERC20(token0).balanceOf(airlock),
            airlockToken1: ERC20(token1).balanceOf(airlock),
            airlockETH: airlock.balance,
            airlockWETH: ERC20(weth).balanceOf(airlock)
        });
    }

    function _getTickRange(
        uint160 sqrtPriceX96,
        int24 tickSpacing
    ) internal pure returns (int24 tickLower, int24 tickUpper) {
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        int24 compressed = currentTick / tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) compressed--;
        int24 nearestTick = compressed * tickSpacing;

        tickLower = nearestTick;
        tickUpper = nearestTick + tickSpacing;

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

        return (tickLower, tickUpper);
    }

    function _isExtremePrice(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper) internal pure returns (bool) {
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        return sqrtPriceX96 <= sqrtPriceAX96 || sqrtPriceX96 >= sqrtPriceBX96;
    }

    function _assertBalances(
        BalanceSnapshot memory before,
        BalanceSnapshot memory afterSnapshot,
        bool isExtremePrice
    ) internal pure {
        assertEq(afterSnapshot.migratorToken0, 0, "Migrator should have no token0 left");
        assertEq(afterSnapshot.migratorToken1, 0, "Migrator should have no token1 left");
        assertEq(afterSnapshot.migratorETH, 0, "Migrator should have no ETH left");
        assertGt(
            afterSnapshot.recipientToken0 + afterSnapshot.recipientToken1, 0, "Should have some refund due to rounding"
        );
        assertEq(afterSnapshot.lockerNftCount, before.lockerNftCount + 1, "Locker should have received exactly 1 NFT");
        assertEq(afterSnapshot.recipientETH, before.recipientETH, "Recipient should receive no ETH");

        uint256 poolToken0Increase = afterSnapshot.poolToken0 - before.poolToken0;
        uint256 poolToken1Increase = afterSnapshot.poolToken1 - before.poolToken1;
        uint256 token0Refund = afterSnapshot.recipientToken0 - before.recipientToken0;
        uint256 token1Refund = afterSnapshot.recipientToken1 - before.recipientToken1;

        if (!isExtremePrice) {
            assertLt(token0Refund, before.migratorToken0, "Some token0 should be used for liquidity");
            assertLt(token1Refund, before.migratorToken1, "Some token1 should be used for liquidity");
        } else {
            bool token0FullyRefunded = token0Refund == before.migratorToken0;
            bool token1FullyRefunded = token1Refund == before.migratorToken1;

            assertTrue(
                (token0FullyRefunded && !token1FullyRefunded) || (!token0FullyRefunded && token1FullyRefunded),
                "At extreme prices, exactly one token should be fully refunded"
            );
        }

        assertEq(
            before.migratorToken0,
            poolToken0Increase + token0Refund,
            "Token0 balance invariant: initial != pool_increase + refund"
        );
        assertEq(
            before.migratorToken1,
            poolToken1Increase + token1Refund,
            "Token1 balance invariant: initial != pool_increase + refund"
        );
    }

    function _setupMigratorWithFeeTier(
        uint24 feeTier
    ) internal returns (CustomUniswapV3Migrator) {
        return new CustomUniswapV3Migrator(
            address(this),
            INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE),
            IBaseSwapRouter02(UNISWAP_V3_ROUTER_02_BASE),
            DOPPLER_FEE_RECEIVER,
            feeTier
        );
    }

    function _createTokenPair() internal returns (TestERC20 tokenA, TestERC20 tokenB, address token0, address token1) {
        tokenA = new TestERC20(type(uint256).max);
        tokenB = new TestERC20(type(uint256).max);

        (token0, token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
    }

    function _transferTokensToMigrator(
        TestERC20 tokenA,
        TestERC20 tokenB,
        address token0,
        uint256 amount0,
        uint256 amount1
    ) internal {
        if (address(tokenA) == token0) {
            tokenA.transfer(address(migrator), amount0);
            tokenB.transfer(address(migrator), amount1);
        } else {
            tokenA.transfer(address(migrator), amount1);
            tokenB.transfer(address(migrator), amount0);
        }
    }

    function _initializePoolAtExtremePrice(address token0, address token1) internal returns (address pool) {
        pool = migrator.initialize(token0, token1, liquidityMigratorData);

        // Verify pool was initialized at extreme price
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 tickSpacing = factory.feeAmountTickSpacing(migrator.FEE_TIER());

        // Should be at extreme tick based on which token is the asset
        bool isAssetToken0 = token0 < token1;
        int24 expectedTick = isAssetToken0
            ? TickMath.minUsableTick(tickSpacing) + tickSpacing
            : TickMath.maxUsableTick(tickSpacing) - tickSpacing;

        assertEq(tick, expectedTick, "Pool should be initialized at extreme tick");
    }

    function _assertMigrationPoolState(
        address pool,
        uint160 expectedSqrtPriceX96,
        uint256 expectedLiquidity
    ) internal view {
        (uint160 currentSqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint128 currentLiquidity = IUniswapV3Pool(pool).liquidity();

        assertEq(currentSqrtPriceX96, expectedSqrtPriceX96, "Pool price mismatch");
        assertEq(currentLiquidity, expectedLiquidity, "Pool liquidity mismatch");
    }

    function _assertPoolInitialized(
        address pool
    ) internal view {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        assertGt(sqrtPriceX96, 0, "Pool should be initialized");
    }

    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        if (tokenA < tokenB) {
            return (tokenA, tokenB);
        } else {
            return (tokenB, tokenA);
        }
    }

    function _sortTokens(TestERC20 tokenA, TestERC20 tokenB) internal pure returns (address token0, address token1) {
        return _sortTokens(address(tokenA), address(tokenB));
    }
}
