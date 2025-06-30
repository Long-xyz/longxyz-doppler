// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { Constants } from "@v4-core-test/utils/Constants.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { IQuoterV2 } from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { ERC20, IERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";
import { ERC721 } from "@openzeppelin/token/ERC721/ERC721.sol";
import { CustomUniswapV3Migrator } from "src/extensions/CustomUniswapV3Migrator.sol";
import { CustomUniswapV3Locker, ICustomUniswapV3Locker } from "src/extensions/CustomUniswapV3Locker.sol";
import { INonfungiblePositionManager } from "src/extensions/interfaces/INonfungiblePositionManager.sol";
import { IUniswapV3Factory, IBaseSwapRouter02 } from "src/extensions/CustomUniswapV3Migrator.sol";
import { Airlock } from "src/Airlock.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import {
    UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE,
    UNISWAP_V3_FACTORY_BASE,
    WETH_BASE,
    UNISWAP_V3_ROUTER_02_BASE,
    UNISWAP_V3_QUOTER_V2_BASE
} from "test/shared/Addresses.sol";
import { console } from "forge-std/console.sol";

contract CustomUniswapV3LockerTest is Test {
    uint24 constant FEE_TIER = 10_000;
    address constant LOCKER_OWNER = address(0x4444);
    address constant MIGRATOR_OWNER = address(0x3333);
    address constant DOPPLER_FEE_RECEIVER = address(0x2222);
    address constant INTEGRATOR_FEE_RECEIVER = address(0x1111);
    address constant CREATOR_FEE_RECEIVER = address(0x5555);
    int24 constant DEFAULT_LOWER_TICK = -200;
    int24 constant DEFAULT_UPPER_TICK = 200;

    INonfungiblePositionManager public NFPM = INonfungiblePositionManager(UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE);
    IUniswapV3Factory public FACTORY = IUniswapV3Factory(UNISWAP_V3_FACTORY_BASE);
    IBaseSwapRouter02 public ROUTER_02 = IBaseSwapRouter02(UNISWAP_V3_ROUTER_02_BASE);
    IQuoterV2 public QUOTER_V2 = IQuoterV2(UNISWAP_V3_QUOTER_V2_BASE);

    CustomUniswapV3Locker public locker;
    CustomUniswapV3Migrator public migrator;
    Airlock public airlock = Airlock(payable(address(0xdeadbeef)));
    IUniswapV3Pool public pool;

    TestERC20 public tokenFoo;
    TestERC20 public tokenBar;

    address public timelock = makeAddr("timelock");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_MAINNET_RPC_URL"), 31_118_046);

        tokenFoo = new TestERC20(1e25);
        tokenBar = new TestERC20(1e25);

        migrator = new CustomUniswapV3Migrator(
            MIGRATOR_OWNER,
            address(this), // airlock
            NFPM,
            ROUTER_02,
            DOPPLER_FEE_RECEIVER,
            FEE_TIER
        );
        locker = new CustomUniswapV3Locker(LOCKER_OWNER, NFPM, migrator, DOPPLER_FEE_RECEIVER);
    }

    function test_constructor() public view {
        uint256 maxCreatorFee = locker.MAX_CREATOR_FEE_WAD();
        uint256 dopplerFee = locker.DOPPLER_FEE_WAD();

        assertEq(maxCreatorFee, 1e18 - dopplerFee);
        assertEq(maxCreatorFee, 0.95e18); // 95%

        assertEq(address(locker.NONFUNGIBLE_POSITION_MANAGER()), UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER_BASE);
        assertEq(address(locker.MIGRATOR()), address(migrator));
        assertEq(locker.dopplerFeeReceiver(), DOPPLER_FEE_RECEIVER);
        assertEq(locker.owner(), LOCKER_OWNER);
    }

    function test_initializePosition_Success() public {
        _createPool();

        uint64 minUnlockDate = uint64(block.timestamp + 365 days);
        uint256 creatorFee = 0.1e18; // 10%

        vm.prank(address(migrator));
        locker.initializePosition(
            address(pool), minUnlockDate, CREATOR_FEE_RECEIVER, creatorFee, INTEGRATOR_FEE_RECEIVER
        );

        (
            address _creatorFeeReceiver,
            uint256 _creatorFee,
            address _integratorFeeReceiver,
            address _recipient,
            uint64 _minUnlockDate,
            uint256 _tokenId
        ) = locker.positionStates(address(pool));

        assertEq(_minUnlockDate, minUnlockDate);
        assertEq(_creatorFeeReceiver, CREATOR_FEE_RECEIVER);
        assertEq(_creatorFee, creatorFee);
        assertEq(_integratorFeeReceiver, INTEGRATOR_FEE_RECEIVER);
    }

    function test_initializePosition_WithoutCreatorFee() public {
        _createPool();

        uint64 minUnlockDate = uint64(block.timestamp + 30 days);

        vm.prank(address(migrator));
        locker.initializePosition(address(pool), minUnlockDate, address(0), 0, INTEGRATOR_FEE_RECEIVER);

        (
            address _creatorFeeReceiver,
            uint256 _creatorFee,
            address _integratorFeeReceiver,
            address _recipient,
            uint64 _minUnlockDate,
            uint256 _tokenId
        ) = locker.positionStates(address(pool));

        assertEq(_minUnlockDate, minUnlockDate);
        assertEq(_creatorFeeReceiver, address(0));
        assertEq(_creatorFee, 0);
        assertEq(_integratorFeeReceiver, INTEGRATOR_FEE_RECEIVER);
    }

    function test_initializePosition_RevertsSenderNotMigrator() public {
        _createPool();

        vm.expectRevert(ICustomUniswapV3Locker.SenderNotMigrator.selector);
        locker.initializePosition(
            address(pool), uint64(block.timestamp + 365 days), CREATOR_FEE_RECEIVER, 0.1e18, INTEGRATOR_FEE_RECEIVER
        );
    }

    function test_initializePosition_RevertsPoolAlreadyInitialized() public {
        _createPool();

        vm.startPrank(address(migrator));
        locker.initializePosition(
            address(pool), uint64(block.timestamp + 365 days), address(0), 0, INTEGRATOR_FEE_RECEIVER
        );

        vm.expectRevert(ICustomUniswapV3Locker.PoolAlreadyInitialized.selector);
        locker.initializePosition(
            address(pool), uint64(block.timestamp + 365 days), address(0), 0, INTEGRATOR_FEE_RECEIVER
        );
        vm.stopPrank();
    }

    function test_initializePosition_RevertsZeroFeeReceiverAddress() public {
        _createPool();

        vm.prank(address(migrator));
        vm.expectRevert(ICustomUniswapV3Locker.ZeroFeeReceiverAddress.selector);
        locker.initializePosition(
            address(pool),
            uint64(block.timestamp + 365 days),
            address(0),
            0,
            address(0) // Zero integrator fee receiver
        );
    }

    function test_initializePosition_RevertsInvalidCreatorFeeSetup_MismatchedAddressAndFee() public {
        _createPool();

        vm.prank(address(migrator));
        vm.expectRevert(ICustomUniswapV3Locker.InvalidCreatorFeeSetup.selector);
        locker.initializePosition(
            address(pool), uint64(block.timestamp + 365 days), CREATOR_FEE_RECEIVER, 0, INTEGRATOR_FEE_RECEIVER
        );
    }

    function test_initializePosition_RevertsInvalidCreatorFeeSetup_FeeWithoutReceiver() public {
        _createPool();

        vm.prank(address(migrator));
        vm.expectRevert(ICustomUniswapV3Locker.InvalidCreatorFeeSetup.selector);
        locker.initializePosition(
            address(pool), uint64(block.timestamp + 365 days), address(0), 0.1e18, INTEGRATOR_FEE_RECEIVER
        );
    }

    function test_initializePosition_RevertsInvalidCreatorFeeSetup_FeeTooHigh() public {
        _createPool();

        uint256 maxCreatorFee = 1e18 - locker.DOPPLER_FEE_WAD();

        vm.prank(address(migrator));
        vm.expectRevert(ICustomUniswapV3Locker.InvalidCreatorFeeSetup.selector);
        locker.initializePosition(
            address(pool),
            uint64(block.timestamp + 365 days),
            CREATOR_FEE_RECEIVER,
            maxCreatorFee + 1,
            INTEGRATOR_FEE_RECEIVER
        );
    }

    function test_updatePosition_Success() public returns (uint256 tokenId) {
        _createPool();
        _initializePosition();

        tokenId = _mintPosition();

        vm.prank(address(migrator));
        locker.updatePosition(address(pool), tokenId, timelock);

        (
            address _creatorFeeReceiver,
            uint256 _creatorFee,
            address _integratorFeeReceiver,
            address _recipient,
            uint64 _minUnlockDate,
            uint256 _tokenId
        ) = locker.positionStates(address(pool));

        assertEq(_tokenId, tokenId);
        assertEq(_recipient, timelock);
    }

    function test_updatePosition_RevertsSenderNotMigrator() public {
        _createPool();
        _initializePosition();
        uint256 tokenId = _mintPosition();

        vm.expectRevert(ICustomUniswapV3Locker.SenderNotMigrator.selector);
        locker.updatePosition(address(pool), tokenId, timelock);
    }

    function test_updatePosition_RevertsPoolAlreadyInitialized() public {
        _createPool();
        _initializePosition();
        uint256 tokenId1 = _mintPosition();
        uint256 tokenId2 = _mintPosition();

        vm.startPrank(address(migrator));
        locker.updatePosition(address(pool), tokenId1, timelock);

        vm.expectRevert(ICustomUniswapV3Locker.PoolAlreadyInitialized.selector);
        locker.updatePosition(address(pool), tokenId2, timelock);
        vm.stopPrank();
    }

    function test_updatePosition_RevertsInvalidTokenId() public {
        _createPool();
        _initializePosition();

        vm.prank(address(migrator));
        vm.expectRevert(ICustomUniswapV3Locker.InvalidTokenId.selector);
        locker.updatePosition(address(pool), 0, timelock);
    }

    function test_updatePosition_RevertsInvalidTokenOwnership() public {
        _createPool();
        _initializePosition();
        uint256 tokenId = _mintPositionToOther(address(this));

        vm.prank(address(migrator));
        vm.expectRevert(ICustomUniswapV3Locker.InvalidTokenOwnership.selector);
        locker.updatePosition(address(pool), tokenId, timelock);
    }

    function test_harvestPosition_WithCreatorFee() public {
        _createPool();

        vm.prank(address(migrator));
        locker.initializePosition(
            address(pool), uint64(block.timestamp + 365 days), CREATOR_FEE_RECEIVER, 0.2e18, INTEGRATOR_FEE_RECEIVER
        );

        uint256 tokenId = _mintPosition();
        vm.prank(address(migrator));
        locker.updatePosition(address(pool), tokenId, timelock);

        _generateFees();
        (uint256 collectedAmount0, uint256 collectedAmount1) = _harvest(address(pool), 0.2e18);

        assertGt(collectedAmount0, 0, "Should have collected token0 fees");
        assertGt(collectedAmount1, 0, "Should have collected token1 fees");
    }

    function test_harvestPosition_WithoutCreatorFee() public {
        _createPool();
        _initializePosition();
        uint256 tokenId = _mintPosition();

        vm.prank(address(migrator));
        locker.updatePosition(address(pool), tokenId, timelock);

        _generateFees();
        (uint256 collectedAmount0, uint256 collectedAmount1) = _harvest(address(pool), 0);
        assertGt(collectedAmount0, 0, "Should have collected token0 fees");
        assertGt(collectedAmount1, 0, "Should have collected token1 fees");
    }

    function test_harvestPosition_NoFeesCollected() public {
        _createPool();
        _initializePosition();
        uint256 tokenId = _mintPosition();

        vm.prank(address(migrator));
        locker.updatePosition(address(pool), tokenId, timelock);

        (uint256 collectedAmount0, uint256 collectedAmount1) = locker.harvestPosition(address(pool));
        assertEq(collectedAmount0, 0);
        assertEq(collectedAmount1, 0);
    }

    function test_unlockPosition_WithoutCreatorFee() public {
        _createPool();
        _initializePosition();
        uint256 tokenId = _mintPosition();

        vm.prank(address(migrator));
        locker.updatePosition(address(pool), tokenId, timelock);

        _generateFees();

        vm.warp(block.timestamp + 366 days);

        (uint256 collectedAmount0, uint256 collectedAmount1) = _unlock(address(pool), 0);
        assertGt(collectedAmount0, 0, "Should have collected token0 fees");
        assertGt(collectedAmount1, 0, "Should have collected token1 fees");
    }

    function test_unlockPosition_WithCreatorFee() public {
        _createPool();

        vm.prank(address(migrator));
        locker.initializePosition(
            address(pool), uint64(block.timestamp + 365 days), CREATOR_FEE_RECEIVER, 0.5e18, INTEGRATOR_FEE_RECEIVER
        );

        uint256 tokenId = _mintPosition();
        vm.prank(address(migrator));
        locker.updatePosition(address(pool), tokenId, timelock);

        _generateFees();

        vm.warp(block.timestamp + 366 days);

        (uint256 collectedAmount0, uint256 collectedAmount1) = _unlock(address(pool), 0.5e18);

        assertGt(collectedAmount0, 0, "Should have collected token0 fees");
        assertGt(collectedAmount1, 0, "Should have collected token1 fees");
    }

    function test_unlockPosition_RevertsPoolNotInitialized() public {
        vm.expectRevert(ICustomUniswapV3Locker.PoolNotInitialized.selector);
        locker.unlockPosition(address(pool));
    }

    function test_unlockPosition_RevertsMinUnlockDateNotReached() public {
        _createPool();
        _initializePosition();
        uint256 tokenId = _mintPosition();

        vm.prank(address(migrator));
        locker.updatePosition(address(pool), tokenId, timelock);

        vm.warp(block.timestamp + 1 days);

        vm.expectRevert(ICustomUniswapV3Locker.MinUnlockDateNotReached.selector);
        locker.unlockPosition(address(pool));
    }

    function test_setDopplerFeeReceiver_Success() public {
        address newReceiver = address(0xffff);

        vm.prank(LOCKER_OWNER);
        locker.setDopplerFeeReceiver(newReceiver);

        assertEq(locker.dopplerFeeReceiver(), newReceiver);
    }

    function test_setDopplerFeeReceiver_RevertsWhenNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        locker.setDopplerFeeReceiver(address(0xffff));
    }

    function test_onERC721Received() public view {
        bytes4 selector = locker.onERC721Received(address(0), address(0), 0, "");
        assertEq(selector, locker.onERC721Received.selector);
    }

    function testFuzz_feeDistribution(uint256 creatorFee, uint256 collectedAmount) public {
        creatorFee = bound(creatorFee, 0, locker.MAX_CREATOR_FEE_WAD());
        collectedAmount = bound(collectedAmount, 1, 1e24);

        uint256 dopplerFee = collectedAmount * locker.DOPPLER_FEE_WAD() / 1e18;
        uint256 creatorFeeAmount = collectedAmount * creatorFee / 1e18;
        uint256 integratorFee = 0;

        if (collectedAmount > dopplerFee + creatorFeeAmount) {
            integratorFee = collectedAmount - dopplerFee - creatorFeeAmount;
        }

        assertEq(dopplerFee + creatorFeeAmount + integratorFee, collectedAmount);
        assertGe(collectedAmount, dopplerFee + creatorFeeAmount);
    }

    function testFuzz_harvestWithVariousFees(uint256 creatorFee, uint256 swapAmount) public {
        creatorFee = bound(creatorFee, 0, locker.MAX_CREATOR_FEE_WAD());
        swapAmount = bound(swapAmount, 1e16, 50e18);

        _createPool();

        address creatorFeeReceiver = creatorFee > 0 ? CREATOR_FEE_RECEIVER : address(0);

        vm.prank(address(migrator));
        locker.initializePosition(
            address(pool), uint64(block.timestamp + 365 days), creatorFeeReceiver, creatorFee, INTEGRATOR_FEE_RECEIVER
        );

        uint256 tokenId = _mintPosition();
        vm.prank(address(migrator));
        locker.updatePosition(address(pool), tokenId, timelock);

        _generateFeesWithAmount(swapAmount);
        _harvest(address(pool), creatorFee);
    }

    function testFuzz_multipleHarvests(uint8 harvestCount, uint256 swapAmount) public {
        harvestCount = uint8(bound(harvestCount, 1, 10));
        swapAmount = bound(swapAmount, 1e16, 10e18);

        _createPool();
        _initializePosition();
        uint256 tokenId = _mintPosition();

        vm.prank(address(migrator));
        locker.updatePosition(address(pool), tokenId, timelock);

        (,, address token0, address token1,,,,,,,,) = NFPM.positions(tokenId);

        BalanceSnapshot memory initial = _getBalances(token0, token1);

        for (uint256 i = 0; i < harvestCount; i++) {
            _generateFeesWithAmount(swapAmount);
            _harvest(address(pool), 0);
        }

        BalanceSnapshot memory finalSnapshot = _getBalances(token0, token1);

        assertGt(finalSnapshot.dopplerToken0, initial.dopplerToken0, "No Doppler fees collected");
        assertGt(finalSnapshot.integratorToken0, initial.integratorToken0, "No integrator fees collected");
    }

    function _harvest(
        address pool,
        uint256 expectedCreatorFee
    ) internal returns (uint256 collectedAmount0, uint256 collectedAmount1) {
        (,,,,, uint256 tokenId) = locker.positionStates(pool);
        (,, address token0, address token1,,,,,,,,) = NFPM.positions(tokenId);

        BalanceSnapshot memory before = _getBalances(token0, token1);
        (collectedAmount0, collectedAmount1) = locker.harvestPosition(pool);
        BalanceSnapshot memory afterSnapshot = _getBalances(token0, token1);
        _assertFeeDistribution(before, afterSnapshot, collectedAmount0, collectedAmount1, expectedCreatorFee);
    }

    function _unlock(
        address pool,
        uint256 expectedCreatorFee
    ) internal returns (uint256 collectedAmount0, uint256 collectedAmount1) {
        (,,, address recipient,, uint256 tokenId) = locker.positionStates(pool);
        (,, address token0, address token1,,,,,,,,) = NFPM.positions(tokenId);
        uint256 recipientNftBefore = ERC721(address(NFPM)).balanceOf(recipient);

        BalanceSnapshot memory before = _getBalances(token0, token1);
        (collectedAmount0, collectedAmount1) = locker.unlockPosition(pool);
        BalanceSnapshot memory afterSnapshot = _getBalances(token0, token1);
        _assertFeeDistribution(before, afterSnapshot, collectedAmount0, collectedAmount1, expectedCreatorFee);

        assertEq(NFPM.ownerOf(tokenId), recipient, "NFT should be transferred to recipient");
        assertEq(ERC721(address(NFPM)).balanceOf(recipient), recipientNftBefore + 1, "Recipient should receive NFT");
    }

    function _createPool() internal {
        tokenFoo.transfer(address(this), 1000e18);
        tokenBar.transfer(address(this), 1000e18);

        (address token0, address token1) = address(tokenFoo) > address(tokenBar)
            ? (address(tokenBar), address(tokenFoo))
            : (address(tokenFoo), address(tokenBar));

        pool = IUniswapV3Pool(FACTORY.createPool(token0, token1, FEE_TIER));
        pool.initialize(Constants.SQRT_PRICE_1_1);
    }

    function _initializePosition() internal {
        vm.prank(address(migrator));
        locker.initializePosition(
            address(pool), uint64(block.timestamp + 365 days), address(0), 0, INTEGRATOR_FEE_RECEIVER
        );
    }

    function _mintPosition() internal returns (uint256 tokenId) {
        (address token0, address token1) = address(tokenFoo) > address(tokenBar)
            ? (address(tokenBar), address(tokenFoo))
            : (address(tokenFoo), address(tokenBar));

        IERC20(token0).approve(address(NFPM), 100e18);
        IERC20(token1).approve(address(NFPM), 100e18);

        (tokenId,,,) = NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE_TIER,
                tickLower: DEFAULT_LOWER_TICK,
                tickUpper: DEFAULT_UPPER_TICK,
                amount0Desired: 100e18,
                amount1Desired: 100e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(locker),
                deadline: block.timestamp + 3600
            })
        );
    }

    function _mintPositionToOther(
        address recipient
    ) internal returns (uint256 tokenId) {
        (address token0, address token1) = address(tokenFoo) > address(tokenBar)
            ? (address(tokenBar), address(tokenFoo))
            : (address(tokenFoo), address(tokenBar));

        IERC20(token0).approve(address(NFPM), 100e18);
        IERC20(token1).approve(address(NFPM), 100e18);

        (tokenId,,,) = NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE_TIER,
                tickLower: DEFAULT_LOWER_TICK,
                tickUpper: DEFAULT_UPPER_TICK,
                amount0Desired: 100e18,
                amount1Desired: 100e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: recipient,
                deadline: block.timestamp + 3600
            })
        );
    }

    function _generateFees() internal {
        (,,,,, uint256 _tokenId) = locker.positionStates(address(pool));
        (,, address token0, address token1,,,,,,,,) = NFPM.positions(_tokenId);

        IERC20(token0).approve(address(ROUTER_02), type(uint256).max);
        IERC20(token1).approve(address(ROUTER_02), type(uint256).max);

        ROUTER_02.exactInputSingle(
            IBaseSwapRouter02.ExactInputSingleParams({
                tokenIn: token0,
                tokenOut: token1,
                fee: FEE_TIER,
                recipient: address(this),
                amountIn: 5e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        ROUTER_02.exactInputSingle(
            IBaseSwapRouter02.ExactInputSingleParams({
                tokenIn: token1,
                tokenOut: token0,
                fee: FEE_TIER,
                recipient: address(this),
                amountIn: 4e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function _generateFeesWithAmount(
        uint256 swapAmount
    ) internal {
        (,,,,, uint256 _tokenId) = locker.positionStates(address(pool));
        (,, address token0, address token1,,,,,,,,) = NFPM.positions(_tokenId);

        uint256 currentBalance0 = IERC20(token0).balanceOf(address(this));
        if (currentBalance0 < swapAmount / 2) {
            TestERC20(token0).mint(address(this), swapAmount / 2 - currentBalance0);
        }

        uint256 currentBalance1 = IERC20(token1).balanceOf(address(this));
        if (currentBalance1 < swapAmount / 2) {
            TestERC20(token1).mint(address(this), swapAmount / 2 - currentBalance1);
        }

        IERC20(token0).approve(address(ROUTER_02), swapAmount / 2);
        IERC20(token1).approve(address(ROUTER_02), swapAmount / 2);

        ROUTER_02.exactInputSingle(
            IBaseSwapRouter02.ExactInputSingleParams({
                tokenIn: token0,
                tokenOut: token1,
                fee: FEE_TIER,
                recipient: address(this),
                amountIn: swapAmount / 2,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        ROUTER_02.exactInputSingle(
            IBaseSwapRouter02.ExactInputSingleParams({
                tokenIn: token1,
                tokenOut: token0,
                fee: FEE_TIER,
                recipient: address(this),
                amountIn: swapAmount / 2,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    struct BalanceSnapshot {
        uint256 dopplerToken0;
        uint256 dopplerToken1;
        uint256 creatorToken0;
        uint256 creatorToken1;
        uint256 integratorToken0;
        uint256 integratorToken1;
        uint256 lockerToken0;
        uint256 lockerToken1;
    }

    function _getBalances(address token0, address token1) internal view returns (BalanceSnapshot memory) {
        return BalanceSnapshot({
            dopplerToken0: IERC20(token0).balanceOf(DOPPLER_FEE_RECEIVER),
            dopplerToken1: IERC20(token1).balanceOf(DOPPLER_FEE_RECEIVER),
            creatorToken0: IERC20(token0).balanceOf(CREATOR_FEE_RECEIVER),
            creatorToken1: IERC20(token1).balanceOf(CREATOR_FEE_RECEIVER),
            integratorToken0: IERC20(token0).balanceOf(INTEGRATOR_FEE_RECEIVER),
            integratorToken1: IERC20(token1).balanceOf(INTEGRATOR_FEE_RECEIVER),
            lockerToken0: IERC20(token0).balanceOf(address(locker)),
            lockerToken1: IERC20(token1).balanceOf(address(locker))
        });
    }

    function _assertFeeDistribution(
        BalanceSnapshot memory before,
        BalanceSnapshot memory afterSnapshot,
        uint256 collectedAmount0,
        uint256 collectedAmount1,
        uint256 creatorFee
    ) internal view {
        _assertToken0Distribution(before, afterSnapshot, collectedAmount0, creatorFee);
        _assertToken1Distribution(before, afterSnapshot, collectedAmount1, creatorFee);
        assertEq(afterSnapshot.lockerToken0, 0, "Locker should not hold any token0");
        assertEq(afterSnapshot.lockerToken1, 0, "Locker should not hold any token1");
    }

    function _assertToken0Distribution(
        BalanceSnapshot memory before,
        BalanceSnapshot memory afterSnapshot,
        uint256 collectedAmount0,
        uint256 creatorFee
    ) internal view {
        uint256 expectedDopplerFee0 = collectedAmount0 * locker.DOPPLER_FEE_WAD() / 1e18;
        uint256 expectedCreatorFee0 = collectedAmount0 * creatorFee / 1e18;
        uint256 expectedIntegratorFee0 = 0;

        if (collectedAmount0 > expectedDopplerFee0 + expectedCreatorFee0) {
            expectedIntegratorFee0 = collectedAmount0 - expectedDopplerFee0 - expectedCreatorFee0;
        }

        assertEq(
            afterSnapshot.dopplerToken0 - before.dopplerToken0, expectedDopplerFee0, "Incorrect Doppler fee for token0"
        );

        if (creatorFee > 0) {
            assertEq(
                afterSnapshot.creatorToken0 - before.creatorToken0,
                expectedCreatorFee0,
                "Incorrect creator fee for token0"
            );
        } else {
            assertEq(
                afterSnapshot.creatorToken0,
                before.creatorToken0,
                "Creator should not receive token0 fees when fee is 0"
            );
        }

        assertEq(
            afterSnapshot.integratorToken0 - before.integratorToken0,
            expectedIntegratorFee0,
            "Incorrect integrator fee for token0"
        );

        uint256 totalDistributed0 = expectedDopplerFee0 + expectedCreatorFee0 + expectedIntegratorFee0;
        assertEq(totalDistributed0, collectedAmount0, "Total token0 distributed should equal collected");
    }

    function _assertToken1Distribution(
        BalanceSnapshot memory before,
        BalanceSnapshot memory afterSnapshot,
        uint256 collectedAmount1,
        uint256 creatorFee
    ) internal view {
        uint256 expectedDopplerFee1 = collectedAmount1 * locker.DOPPLER_FEE_WAD() / 1e18;
        uint256 expectedCreatorFee1 = collectedAmount1 * creatorFee / 1e18;
        uint256 expectedIntegratorFee1 = 0;

        if (collectedAmount1 > expectedDopplerFee1 + expectedCreatorFee1) {
            expectedIntegratorFee1 = collectedAmount1 - expectedDopplerFee1 - expectedCreatorFee1;
        }

        assertEq(
            afterSnapshot.dopplerToken1 - before.dopplerToken1, expectedDopplerFee1, "Incorrect Doppler fee for token1"
        );

        if (creatorFee > 0) {
            assertEq(
                afterSnapshot.creatorToken1 - before.creatorToken1,
                expectedCreatorFee1,
                "Incorrect creator fee for token1"
            );
        } else {
            assertEq(
                afterSnapshot.creatorToken1,
                before.creatorToken1,
                "Creator should not receive token1 fees when fee is 0"
            );
        }

        assertEq(
            afterSnapshot.integratorToken1 - before.integratorToken1,
            expectedIntegratorFee1,
            "Incorrect integrator fee for token1"
        );

        uint256 totalDistributed1 = expectedDopplerFee1 + expectedCreatorFee1 + expectedIntegratorFee1;
        assertEq(totalDistributed1, collectedAmount1, "Total token1 distributed should equal collected");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
