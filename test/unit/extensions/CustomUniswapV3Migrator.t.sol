// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test, console, Vm } from "forge-std/Test.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { ERC721 } from "@solady/tokens/ERC721.sol";
import { CustomUniswapV3Migrator } from "src/extensions/CustomUniswapV3Migrator.sol";
import { ICustomUniswapV3Migrator } from "src/extensions/interfaces/ICustomUniswapV3Migrator.sol";
import { CustomUniswapV3Locker } from "src/extensions/CustomUniswapV3Locker.sol";
import { ICustomUniswapV3Locker } from "src/extensions/interfaces/ICustomUniswapV3Locker.sol";
import { INonfungiblePositionManager } from "src/extensions/interfaces/INonfungiblePositionManager.sol";
import { IUniswapV3Factory, IBaseSwapRouter02 } from "src/extensions/CustomUniswapV3Migrator.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import { Airlock } from "src/Airlock.sol";
import {
    UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE,
    UNISWAP_V3_FACTORY_BASE,
    WETH_BASE,
    UNISWAP_V3_ROUTER_02_BASE
} from "test/shared/Addresses.sol";

contract CustomUniswapV3TestFallbackMigrator is ILiquidityMigrator {
    struct MigrationData {
        address migrator;
        uint160 sqrtPriceX96;
        address token0;
        address token1;
        address recipient;
        uint256 balance0;
        uint256 balance1;
        uint256 liquidity;
    }

    MigrationData public migrationData;

    function setMigrationData(
        MigrationData memory migrationData_
    ) external {
        migrationData = migrationData_;
    }

    function initialize(address, address, bytes calldata) external pure override returns (address) {
        revert("Not implemented");
    }

    function migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) external payable override returns (uint256 liquidity) {
        MigrationData memory data = migrationData;

        if (data.migrator != msg.sender) revert("Invalid migrator");
        if (data.sqrtPriceX96 != sqrtPriceX96) revert("Invalid sqrtPriceX96");
        if (data.token0 != token0) revert("Invalid token0");
        if (data.token1 != token1) revert("Invalid token1");
        if (data.recipient != recipient) revert("Invalid recipient");
        if (data.balance0 != ERC20(token0).balanceOf(address(this))) revert("Invalid balance0");
        if (data.balance1 != ERC20(token1).balanceOf(address(this))) revert("Invalid balance1");

        return data.liquidity;
    }
}

contract CustomUniswapV3MigratorTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event IncreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    CustomUniswapV3Migrator public migrator;
    uint24 public feeTier;
    int24 public tickSpacing;
    int24 public minUsableTick;
    int24 public maxUsableTick;

    IUniswapV3Factory public factory = IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE);
    INonfungiblePositionManager public nfpm = INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE);
    ERC20 public weth = ERC20(WETH_BASE);

    uint256 public nonce;

    address constant MIGRATOR_OWNER = address(0x3333);
    address constant DOPPLER_FEE_RECEIVER = address(0x2222);
    address constant INTEGRATOR_FEE_RECEIVER = address(0x1111);

    bytes public liquidityMigratorData = abi.encode(INTEGRATOR_FEE_RECEIVER, address(0), 0, type(uint64).max);

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
        nonce = 0;
    }

    modifier setupMigrator() {
        _setupMigrator(10_000);
        _;
    }

    modifier setupMigratorWithFeeTier(
        uint24 feeTier_
    ) {
        _setupMigrator(feeTier_);
        _;
    }

    function _setupMigrator(
        uint24 feeTier_
    ) internal {
        migrator = new CustomUniswapV3Migrator(
            MIGRATOR_OWNER,
            address(this),
            nfpm,
            IBaseSwapRouter02(UNISWAP_V3_ROUTER_02_BASE),
            DOPPLER_FEE_RECEIVER,
            feeTier_
        );
        feeTier = feeTier_;
        tickSpacing = factory.feeAmountTickSpacing(feeTier_);
        minUsableTick = TickMath.minUsableTick(tickSpacing);
        maxUsableTick = TickMath.maxUsableTick(tickSpacing);
        assertNotEq(tickSpacing, 0, "Tick spacing should be non-zero");
        assertEq(migrator.FEE_TIER(), feeTier_);
    }

    function test_constantValues() public setupMigrator {
        assertEq(address(migrator.NONFUNGIBLE_POSITION_MANAGER()), UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE);
        assertEq(address(migrator.FACTORY()), UNISWAP_V3_FACTORY_BASE);
        assertEq(address(migrator.WETH()), WETH_BASE);
        assertEq(migrator.FEE_TIER(), feeTier);
        assertTrue(address(migrator.CUSTOM_V3_LOCKER()) != address(0), "Locker should be deployed");
    }

    function test_receive_ReceivesETHFromAirlock() public setupMigrator {
        uint256 preBalance = address(migrator).balance;
        deal(address(this), 1 ether);
        payable(address(migrator)).transfer(1 ether);
        assertEq(address(migrator).balance, preBalance + 1 ether, "Wrong balance");
    }

    function test_initialize_CreatesPair() public setupMigrator {
        TokenPair memory tp = _createTokenPair();
        address pair = migrator.initialize(tp.token0, tp.token1, liquidityMigratorData);
        assertEq(pair, IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE).getPool(tp.token0, tp.token1, feeTier), "Wrong pair");
    }

    function test_initialize_DoesNotFailWhenPairIsAlreadyCreated() public setupMigrator {
        TokenPair memory tp = _createTokenPair();
        IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE).createPool(tp.token0, tp.token1, feeTier);
        address pair = migrator.initialize(tp.token0, tp.token1, liquidityMigratorData);
        assertEq(pair, IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE).getPool(tp.token0, tp.token1, feeTier), "Wrong pair");
    }

    function test_initialize_RevertsWithInvalidLengthData() public setupMigrator {
        vm.expectRevert(abi.encodeWithSelector(ICustomUniswapV3Migrator.InvalidLiquidityMigratorDataLength.selector));
        migrator.initialize(address(0x1111), address(0x2222), hex"00");
    }

    function test_initialize_RevertsWithZeroFeeReceiver() public setupMigrator {
        bytes memory invalidData = abi.encode(address(0), address(0), 0, type(uint64).max);
        vm.expectRevert(abi.encodeWithSelector(ICustomUniswapV3Locker.ZeroFeeReceiverAddress.selector));
        migrator.initialize(address(0x1111), address(0x2222), invalidData);
    }

    function test_initialize_RevertsWithInvalidMinUnlockDate() public setupMigrator {
        bytes memory invalidData = abi.encode(INTEGRATOR_FEE_RECEIVER, address(0), 0, vm.getBlockTimestamp() - 1);
        vm.expectRevert(abi.encodeWithSelector(ICustomUniswapV3Locker.InvalidMinUnlockDate.selector));
        migrator.initialize(address(0x1111), address(0x2222), invalidData);
    }

    function test_initialize_UsesWETHForNumeraireZero() public setupMigrator {
        TestERC20 token = new TestERC20(1e30);

        address pool = migrator.initialize(address(token), address(0), liquidityMigratorData);

        (address token0, address token1) = _sortTokens(address(token), address(weth));
        assertEq(pool, IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE).getPool(token0, token1, feeTier), "Wrong pool");
    }

    function test_initialize_SetsLockerPositionState() public setupMigrator {
        bytes memory data = abi.encode(INTEGRATOR_FEE_RECEIVER, address(0xcccc), 0.1e18, vm.getBlockTimestamp() + 100);

        TokenPair memory tp = _createTokenPair();
        address pool = migrator.initialize(tp.token0, tp.token1, data);
        (
            address creatorFeeReceiver,
            uint256 creatorFee,
            address integratorFeeReceiver,
            address recipient,
            uint64 minUnlockDate,
            uint256 tokenId
        ) = migrator.CUSTOM_V3_LOCKER().positionStates(pool);

        assertEq(integratorFeeReceiver, INTEGRATOR_FEE_RECEIVER, "Wrong integrator fee receiver");
        assertEq(creatorFeeReceiver, address(0xcccc), "Wrong creator fee receiver");
        assertEq(creatorFee, 0.1e18, "Wrong creator fee");
        assertEq(minUnlockDate, vm.getBlockTimestamp() + 100, "Wrong min unlock date");
        assertEq(recipient, address(0), "Wrong recipient");
        assertEq(tokenId, 0, "Wrong token ID");
    }

    function testFuzz_initialize_InitializesPoolAtExtremePrice(
        uint256 seed
    ) public setupMigrator {
        TokenPair memory tp = _createTokenPair(seed, false);

        address pool = migrator.initialize(address(tp.tokenA), address(tp.tokenB), liquidityMigratorData);
        _assertPoolInitialized(pool);

        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 expectedTick = address(tp.tokenA) == tp.token0 ? minUsableTick + tickSpacing : maxUsableTick - tickSpacing;
        assertEq(tick, expectedTick, "Pool should be initialized at extreme tick");
    }

    function test_migrate_RevertsWhenSenderNotAirlock() public setupMigrator {
        vm.prank(address(0xbeef));
        vm.expectRevert(SenderNotAirlock.selector);
        migrator.migrate(uint160(0), address(0x1111), address(0x2222), address(0));
    }

    // function test_migrate_RevertsWhenPoolDoesNotExist() public setupMigrator {
    //     TokenPair memory tp = _createTokenPair();
    //     _transferTokensToMigrator(tp, 1e28, 1e28);

    //     CustomUniswapV3Migrator migrator_ = migrator;

    //     _setupMigrator(10_000);
    //     vm.prank(MIGRATOR_OWNER);
    //     migrator.setFallbackLiquidityMigrator(migrator_);

    //     vm.expectRevert(abi.encodeWithSelector(ICustomUniswapV3Migrator.PoolDoesNotExist.selector));
    //     migrator.migrate(SQRT_PRICE_1_1, tp.token0, tp.token1, address(0xbeef));
    // }

    function test_migrate_RevertsWhenZeroAmounts() public setupMigrator {
        TokenPair memory tp = _createTokenPair();

        migrator.initialize(tp.token0, tp.token1, liquidityMigratorData);

        vm.expectRevert();
        migrator.migrate(SQRT_PRICE_1_1, tp.token0, tp.token1, address(0xbeef));
    }

    function test_migrate_BasicScenario() public setupMigrator {
        TokenPair memory tp = _createTokenPair();

        migrator.initialize(tp.token0, tp.token1, liquidityMigratorData);
        _transferTokensToMigrator(tp, 1e24, 1e24);

        uint160 targetPrice = SQRT_PRICE_3_2;
        address recipient = address(0xbeef);

        _migrate(tp, targetPrice, recipient, false);
    }

    function test_migrate_PreInitializedPool() public setupMigrator {
        TokenPair memory tp = _createTokenPair();

        address pool = factory.createPool(tp.token0, tp.token1, feeTier);
        assertNotEq(factory.getPool(tp.token0, tp.token1, feeTier), address(0), "Pool should be created");

        IUniswapV3Pool(pool).initialize(SQRT_PRICE_1_1);
        _assertPoolInitialized(pool);

        address existingPool = migrator.initialize(tp.token0, tp.token1, liquidityMigratorData);
        assertEq(existingPool, pool, "Pool addresses should be the same");

        _transferTokensToMigrator(tp, 1e24, 1e24);

        uint160 targetPrice = SQRT_PRICE_3_2;
        address recipient = address(0xbeef);

        _migrate(tp, targetPrice, recipient, true);
    }

    function testFuzz_migrate_ethTokenPriceInversionLogic(
        uint256 seed
    ) public setupMigrator {
        TokenPair memory tp = _createTokenPair(seed, true);
        bool isTokenLower = address(tp.token1) < address(weth);

        address pool = migrator.initialize(tp.token1, tp.token0, liquidityMigratorData);

        if (isTokenLower) {
            assertEq(IUniswapV3Pool(pool).token0(), address(tp.token1), "Token should be token0");
            assertEq(IUniswapV3Pool(pool).token1(), address(weth), "WETH should be token1");
        } else {
            assertEq(IUniswapV3Pool(pool).token0(), address(weth), "WETH should be token0");
            assertEq(IUniswapV3Pool(pool).token1(), address(tp.token1), "High token should be token1");
        }

        _transferTokensToMigrator(tp, 10 ether, 20e18);

        _migrate(tp, SQRT_PRICE_1_2, address(0xbeef), false);

        uint160 targetPrice = isTokenLower ? SQRT_PRICE_2_1 : SQRT_PRICE_1_2;
        (uint160 poolPrice,,,,,,) = IUniswapV3Pool(pool).slot0();
        assertApproxEqRel(poolPrice, targetPrice, 0.0001e18);
    }

    function test_migrate_ETHHandling() public setupMigrator {
        TokenPair memory tp = _createTokenPair(0, true);
        migrator.initialize(tp.token1, tp.token0, liquidityMigratorData);
        _transferTokensToMigrator(tp, 10 ether, 10e18);
        _migrate(tp, SQRT_PRICE_3_2, address(0xbeef), false);
    }

    function testFuzz_migrate_WithVariousPricesAndAmounts(
        uint160 targetSqrtPriceX96,
        uint256 amount0,
        uint256 amount1,
        uint256 seed,
        bool withEth
    ) public setupMigrator {
        amount0 = bound(amount0, 1e10, 1e18);
        amount1 = bound(amount1, 1e10, 1e18);

        targetSqrtPriceX96 =
            uint160(bound(uint256(targetSqrtPriceX96), TickMath.MIN_SQRT_PRICE * 1e18, TickMath.MAX_SQRT_PRICE / 1e18));

        TokenPair memory tp = _createTokenPair(seed, withEth);
        _transferTokensToMigrator(tp, amount0, amount1);

        migrator.initialize(tp.token1, tp.token0, liquidityMigratorData);

        address recipient = address(0xbeef);

        _migrate(tp, targetSqrtPriceX96, recipient, false);
    }

    function testFuzz_initialize_WithVariousAddresses(
        address asset,
        address numeraire,
        address integratorFeeReceiver
    ) public setupMigrator {
        vm.assume(asset != address(0));
        vm.assume(integratorFeeReceiver != address(0));
        vm.assume(asset != numeraire);

        vm.assume(uint160(asset) > 255);
        vm.assume(uint160(numeraire) > 255 || numeraire == address(0));
        vm.assume(uint160(integratorFeeReceiver) > 255);

        bytes memory fuzzData = abi.encode(integratorFeeReceiver, address(0), 0, type(uint64).max);

        address pool = migrator.initialize(asset, numeraire, fuzzData);
        _assertPoolInitialized(pool);

        address expectedNumeraire = numeraire == address(0) ? address(migrator.WETH()) : numeraire;
        (address token0, address token1) = _sortTokens(asset, expectedNumeraire);

        assertEq(pool, factory.getPool(token0, token1, feeTier), "Pool address mismatch");
        (
            address creatorFeeReceiver,
            uint256 creatorFee,
            address integratorFeeReceiver_,
            address recipient,
            uint64 minUnlockDate,
            uint256 tokenId
        ) = migrator.CUSTOM_V3_LOCKER().positionStates(pool);
        assertEq(creatorFeeReceiver, address(0), "Wrong creator fee receiver");
        assertEq(creatorFee, 0, "Wrong creator fee");
        assertEq(minUnlockDate, type(uint64).max, "Wrong min unlock date");
        assertEq(integratorFeeReceiver_, integratorFeeReceiver, "Wrong integrator fee receiver");
        assertEq(recipient, address(0), "Wrong recipient");
        assertEq(tokenId, 0, "Wrong token ID");

        bool isAssetToken0 = asset == token0;

        (uint160 sqrtPriceX96, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 expectedTick = isAssetToken0 ? minUsableTick + tickSpacing : maxUsableTick - tickSpacing;
        assertEq(tick, expectedTick, "Pool should be initialized at extreme tick");
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(expectedTick), "Pool should be initialized at extreme price");
    }

    function test_migrate_PreexistingLiquidity() public {
        _testMigratePreexistingLiquidity(TickMath.MAX_SQRT_PRICE - 1, 10e18, (SQRT_PRICE_1_1 * 11) / 10, 50e18);
        _testMigratePreexistingLiquidity(TickMath.MAX_SQRT_PRICE - 1, 51e18, (SQRT_PRICE_1_1 * 11) / 10, 1e18);
        _testMigratePreexistingLiquidity(TickMath.MAX_SQRT_PRICE - 1, 51e18, TickMath.MAX_SQRT_PRICE - 1, 50e18);
        _testMigratePreexistingLiquidity(TickMath.MAX_SQRT_PRICE - 1, 10e18, (SQRT_PRICE_1_1 * 9) / 10, 50e18);
        _testMigratePreexistingLiquidity(SQRT_PRICE_1_1 * 9 / 10, 10e18, (SQRT_PRICE_1_1 * 8) / 10, 50e18);
    }

    function _testMigratePreexistingLiquidity(
        uint160 initializationPrice,
        uint256 preexistingToken1Amount,
        uint160 preexistingSqrtPriceX96,
        uint256 migratorAmounts
    ) internal setupMigrator {
        TokenPair memory tp = _createTokenPair(0, false);
        address pool = factory.createPool(tp.token0, tp.token1, feeTier);
        IUniswapV3Pool(pool).initialize(initializationPrice);

        address liquidityProvider = address(0x1234);

        if (address(tp.tokenB) == tp.token1) {
            tp.tokenB.transfer(liquidityProvider, preexistingToken1Amount);
        } else {
            tp.tokenA.transfer(liquidityProvider, preexistingToken1Amount);
        }

        vm.startPrank(liquidityProvider);
        ERC20(tp.token1).approve(address(nfpm), preexistingToken1Amount);

        int24 currentTick = TickMath.getTickAtSqrtPrice(preexistingSqrtPriceX96);
        int24 tickUpper = ((currentTick - tickSpacing) / tickSpacing) * tickSpacing;
        int24 tickLower = tickUpper - tickSpacing;

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            token0: tp.token0,
            token1: tp.token1,
            fee: feeTier,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: 0,
            amount1Desired: preexistingToken1Amount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: liquidityProvider,
            deadline: block.timestamp
        });

        (uint256 tokenId, uint128 addedLiquidity,,) = nfpm.mint(mintParams);
        vm.stopPrank();

        assertGt(addedLiquidity, 0, "Liquidity should have been added");
        assertEq(nfpm.ownerOf(tokenId), liquidityProvider, "LP should own the NFT");
        (uint160 currentPrice,,,,,,) = IUniswapV3Pool(pool).slot0();
        assertEq(currentPrice, initializationPrice, "Pool should still be at initialization price");
        address migratorPool = migrator.initialize(tp.token0, tp.token1, liquidityMigratorData);
        assertEq(migratorPool, pool, "Should return the existing pool");

        _transferTokensToMigrator(tp, migratorAmounts, migratorAmounts);

        address recipient = address(0xbeef);
        uint160 targetPrice = SQRT_PRICE_1_1;
        _migrate(tp, targetPrice, recipient, true);
    }

    function test_migrate_fallbackLiquidityMigrator() public {
        migrator = new CustomUniswapV3Migrator(
            MIGRATOR_OWNER,
            address(this),
            INonfungiblePositionManager(address(0)), // NFPM set to 0, mint will revert
            IBaseSwapRouter02(UNISWAP_V3_ROUTER_02_BASE),
            DOPPLER_FEE_RECEIVER,
            10_000
        );
        CustomUniswapV3TestFallbackMigrator fallbackMigrator = new CustomUniswapV3TestFallbackMigrator();

        TokenPair memory tp = _createTokenPair();

        address pool = migrator.initialize(tp.token0, tp.token1, liquidityMigratorData);
        _assertPoolInitialized(pool);

        uint256 transferAmount0 = 1e24;
        uint256 transferAmount1 = 1e24;
        _transferTokensToMigrator(tp, transferAmount0, transferAmount1);

        uint160 targetPrice = SQRT_PRICE_3_2;
        address recipient = address(0xbeef);

        vm.expectRevert(abi.encodeWithSelector(ICustomUniswapV3Migrator.InvalidFallbackLiquidityMigrator.selector));
        migrator.migrate(targetPrice, tp.token0, tp.token1, recipient);

        vm.prank(MIGRATOR_OWNER);
        migrator.setFallbackLiquidityMigrator(fallbackMigrator);

        CustomUniswapV3TestFallbackMigrator(fallbackMigrator).setMigrationData(
            CustomUniswapV3TestFallbackMigrator.MigrationData({
                migrator: address(migrator),
                sqrtPriceX96: targetPrice,
                token0: tp.token0,
                token1: tp.token1,
                recipient: recipient,
                balance0: transferAmount0,
                balance1: transferAmount1,
                liquidity: 1000
            })
        );

        assertEq(migrator.migrate(targetPrice, tp.token0, tp.token1, recipient), 1000);
    }

    function _migrate(
        address token0,
        address token1,
        uint160 targetPrice,
        address recipient,
        bool isPreexistingLiquidity
    ) internal {
        address tokenA = token0;
        address tokenB = token1;
        uint160 poolExpectedPrice = targetPrice;

        if (token0 == address(0)) {
            (tokenA, tokenB) = _sortTokens(address(weth), tokenB);
            if (tokenB == address(weth)) {
                poolExpectedPrice = uint160((1 << 192) / targetPrice);
            }
        }
        address pool = factory.getPool(tokenA, tokenB, feeTier);
        assertNotEq(pool, address(0), "Pool should exist");

        BalanceSnapshot memory before = _getBalances(tokenA, tokenB, recipient, pool);
        uint256 liquidity = migrator.migrate(targetPrice, token0, token1, recipient);
        BalanceSnapshot memory afterSnapshot = _getBalances(tokenA, tokenB, recipient, pool);

        if (!isPreexistingLiquidity) {
            _assertMigrationPoolState(pool, poolExpectedPrice, liquidity);
        }
        _assertBalances(pool, before, afterSnapshot, isPreexistingLiquidity);
    }

    function _migrate(
        TokenPair memory tp,
        uint160 targetPrice,
        address recipient,
        bool isPreexistingLiquidity
    ) internal {
        _migrate(tp.token0, tp.token1, targetPrice, recipient, isPreexistingLiquidity);
    }

    function _getBalances(
        address token0,
        address token1,
        address recipient,
        address pool
    ) internal view returns (BalanceSnapshot memory) {
        address airlock = address(migrator.airlock());

        uint256 migratorToken0 = ERC20(token0).balanceOf(address(migrator));
        uint256 migratorToken1 = ERC20(token1).balanceOf(address(migrator));

        if (token0 == address(weth)) {
            migratorToken0 += address(migrator).balance;
        }
        if (token1 == address(weth)) {
            migratorToken1 += address(migrator).balance;
        }

        return BalanceSnapshot({
            migratorToken0: migratorToken0,
            migratorToken1: migratorToken1,
            migratorETH: address(migrator).balance,
            recipientToken0: ERC20(token0).balanceOf(recipient),
            recipientToken1: ERC20(token1).balanceOf(recipient),
            recipientETH: recipient.balance,
            recipientWETH: weth.balanceOf(recipient),
            poolToken0: ERC20(token0).balanceOf(pool),
            poolToken1: ERC20(token1).balanceOf(pool),
            lockerNftCount: ERC721(address(nfpm)).balanceOf(address(migrator.CUSTOM_V3_LOCKER())),
            airlockToken0: ERC20(token0).balanceOf(airlock),
            airlockToken1: ERC20(token1).balanceOf(airlock),
            airlockETH: airlock.balance,
            airlockWETH: weth.balanceOf(airlock)
        });
    }

    function _getBalances(
        TokenPair memory tp,
        address recipient,
        address pool
    ) internal view returns (BalanceSnapshot memory) {
        return _getBalances(tp.token0, tp.token1, recipient, pool);
    }

    function _assertBalances(
        address pool,
        BalanceSnapshot memory before,
        BalanceSnapshot memory afterSnapshot,
        bool isPreexistingLiquidity
    ) internal view {
        assertEq(afterSnapshot.migratorToken0, 0, "Migrator should have no token0 left");
        assertEq(afterSnapshot.migratorToken1, 0, "Migrator should have no token1 left");
        assertEq(afterSnapshot.migratorETH, 0, "Migrator should have no ETH left");
        assertEq(afterSnapshot.recipientETH, before.recipientETH, "Recipient should receive no ETH");

        // Handle cases where pool balance might decrease due to swaps
        uint256 poolToken0Increase =
            afterSnapshot.poolToken0 > before.poolToken0 ? afterSnapshot.poolToken0 - before.poolToken0 : 0;
        uint256 poolToken1Increase =
            afterSnapshot.poolToken1 > before.poolToken1 ? afterSnapshot.poolToken1 - before.poolToken1 : 0;

        // If pool balance decreased, track the decrease
        uint256 poolToken0Decrease =
            before.poolToken0 > afterSnapshot.poolToken0 ? before.poolToken0 - afterSnapshot.poolToken0 : 0;
        uint256 poolToken1Decrease =
            before.poolToken1 > afterSnapshot.poolToken1 ? before.poolToken1 - afterSnapshot.poolToken1 : 0;
        uint256 token0Refund = afterSnapshot.recipientToken0 - before.recipientToken0;
        uint256 token1Refund = afterSnapshot.recipientToken1 - before.recipientToken1;

        if (!isPreexistingLiquidity) {
            assertLt(token0Refund, before.migratorToken0, "Some token0 should be used for liquidity");
            assertLt(token1Refund, before.migratorToken1, "Some token1 should be used for liquidity");
        }

        // In the presence of swaps, the balance invariant is more complex
        // The migrator's initial balance = pool increase + refund + amount used in swap
        // For a swap moving from infinite price to 1:1, token0 goes into the pool, token1 comes out
        if (poolToken1Decrease > 0) {
            // Token1 came out of pool due to swap, so it should be in the refund
            assertEq(
                before.migratorToken0,
                poolToken0Increase + token0Refund + poolToken0Decrease,
                "Token0 balance invariant with swap"
            );
            assertEq(
                before.migratorToken1 + poolToken1Decrease,
                poolToken1Increase + token1Refund,
                "Token1 balance invariant with swap"
            );
        } else {
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

        if (!isPreexistingLiquidity) {
            (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
            (uint256 expectedAmount0, uint256 expectedAmount1) =
                _computeDepositAmounts(before.migratorToken0, before.migratorToken1, sqrtPriceX96);
            if (expectedAmount1 > before.migratorToken1) {
                (, expectedAmount1) = _computeDepositAmounts(expectedAmount0, before.migratorToken1, sqrtPriceX96);
            } else {
                (expectedAmount0,) = _computeDepositAmounts(before.migratorToken0, expectedAmount1, sqrtPriceX96);
            }

            if (_absDiff(expectedAmount0, poolToken0Increase) > 100) {
                assertApproxEqRel(
                    poolToken0Increase, expectedAmount0, 0.02e18, "Pool should receive the correct amount of token0"
                );
            }
            if (_absDiff(expectedAmount1, poolToken1Increase) > 100) {
                assertApproxEqRel(
                    poolToken1Increase, expectedAmount1, 0.02e18, "Pool should receive the correct amount of token1"
                );
            }

            if (before.migratorToken0 != 0 && before.migratorToken1 != 0) {
                assertEq(
                    afterSnapshot.lockerNftCount, before.lockerNftCount + 1, "Locker should have received exactly 1 NFT"
                );
            }
        }
    }

    struct TokenPair {
        TestERC20 tokenA;
        TestERC20 tokenB;
        address token0;
        address token1;
    }

    function _createTokenPair() internal returns (TokenPair memory) {
        return _createTokenPair(0, false);
    }

    function _createTokenPair(uint256 seed, bool withEth) internal returns (TokenPair memory) {
        seed = seed % type(uint128).max;

        TestERC20 tokenA;
        if (!withEth) {
            tokenA = new TestERC20{ salt: bytes32(nonce + seed) }(type(uint256).max);
            nonce++;
        } else {
            tokenA = TestERC20(address(0));
        }
        TestERC20 tokenB = new TestERC20{ salt: bytes32(nonce + seed) }(type(uint256).max);
        nonce++;

        if (seed & 1 == 1) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }

        address token0 = address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB);
        address token1 = address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA);

        return TokenPair({ tokenA: tokenA, tokenB: tokenB, token0: token0, token1: token1 });
    }

    function _transferTokensToMigrator(
        TestERC20 tokenA,
        TestERC20 tokenB,
        address token0,
        uint256 amount0,
        uint256 amount1
    ) internal {
        if (address(tokenA) == token0) {
            _transferTokenOrEthToMigrator(address(tokenA), amount0);
            _transferTokenOrEthToMigrator(address(tokenB), amount1);
        } else {
            _transferTokenOrEthToMigrator(address(tokenA), amount1);
            _transferTokenOrEthToMigrator(address(tokenB), amount0);
        }
    }

    function _transferTokensToMigrator(TokenPair memory tp, uint256 amount0, uint256 amount1) internal {
        _transferTokensToMigrator(tp.tokenA, tp.tokenB, tp.token0, amount0, amount1);
    }

    function _transferTokenOrEthToMigrator(address token, uint256 amount) internal {
        if (token == address(0)) {
            vm.deal(address(migrator), amount);
        } else {
            ERC20(token).transfer(address(migrator), amount);
        }
    }

    function _assertMigrationPoolState(
        address pool,
        uint160 expectedSqrtPriceX96,
        uint256 expectedLiquidity
    ) internal view {
        (uint160 currentSqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint128 currentLiquidity = IUniswapV3Pool(pool).liquidity();

        assertApproxEqRel(currentSqrtPriceX96, expectedSqrtPriceX96, 0.0001e18, "Pool price mismatch");
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

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _computeDepositAmounts(
        uint256 balance0,
        uint256 balance1,
        uint160 sqrtPriceX96
    ) internal pure returns (uint256 depositAmount0, uint256 depositAmount1) {
        uint256 ratioX192;
        uint256 ratioScale;

        if (sqrtPriceX96 <= type(uint128).max) {
            ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
            ratioScale = 192;
        } else {
            ratioX192 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            ratioScale = 128;
        }

        uint256 required1ForAllToken0 = FullMath.mulDiv(balance0, ratioX192, 1 << ratioScale);

        if (required1ForAllToken0 <= balance1) {
            depositAmount0 = balance0;
            depositAmount1 = required1ForAllToken0;
        } else {
            depositAmount1 = balance1;
            depositAmount0 = FullMath.mulDiv(balance1, 1 << ratioScale, ratioX192);
        }
    }
}
