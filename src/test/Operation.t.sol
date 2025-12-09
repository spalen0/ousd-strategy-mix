// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {AuctionFactory, Auction} from "@periphery/Auctions/AuctionFactory.sol";
import {IMorphoCompounder} from "../interfaces/IMorphoCompounder.sol";

contract OperationTest is Setup {
    function setUp() public virtual override {
        super.setUp();

        vm.startPrank(management);
        IMorphoCompounder(address(strategy)).addRewardToken(
            swapToken,
            IMorphoCompounder.SwapType.UNISWAP_V3
        );

        IMorphoCompounder(address(strategy)).setUniFees(
            swapToken,
            IMorphoCompounder(address(strategy)).base(),
            100
        );

        IMorphoCompounder(address(strategy)).setUniFees(
            IMorphoCompounder(address(strategy)).base(),
            address(asset),
            100
        );
        vm.stopPrank();
    }

    function test_setupStrategyOK() public {
        console.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
        // TODO: add additional check on strat params
    }

    function test_operation(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_profitableReport(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(
            bound(uint256(_profitFactor), 10, MAX_BPS - 100)
        );

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // TODO: implement logic to simulate earning interest.
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        earnProfit(toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_profitableReport_withFees(
        uint256 _amount,
        uint16 _profitFactor
    ) public virtual {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(
            bound(uint256(_profitFactor), 10, MAX_BPS - 100)
        );

        // Set protocol fee to 0 and perf fee to 10%
        setFees(0, 1_000);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // TODO: implement logic to simulate earning interest.
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        earnProfit(toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        // Get the expected fee
        uint256 expectedShares = (profit * 1_000) / MAX_BPS;

        assertEq(strategy.balanceOf(performanceFeeRecipient), expectedShares);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );

        vm.prank(performanceFeeRecipient);
        strategy.redeem(
            expectedShares,
            performanceFeeRecipient,
            performanceFeeRecipient
        );

        checkStrategyTotals(strategy, 0, 0, 0);

        assertGe(
            asset.balanceOf(performanceFeeRecipient),
            expectedShares,
            "!perf fee out"
        );
    }

    function test_tendTrigger(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Skip some time
        skip(1 days);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(keeper);
        strategy.report();

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Unlock Profits
        skip(strategy.profitMaxUnlockTime());

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);
    }

    function test_random_user_cant_deposit() public {
        uint256 amount = 1000e6;
        address randomUser = address(0x123);
        airdrop(ERC20(asset), randomUser, amount);
        vm.startPrank(randomUser);
        ERC20(asset).approve(address(strategy), amount);
        vm.expectRevert("ERC4626: deposit more than max");
        strategy.deposit(amount, randomUser);
    }

    function test_random_user_can_deposit_for_ousd() public {
        uint256 amount = 1000e6;
        address randomUser = address(0x123);
        airdrop(ERC20(asset), randomUser, amount);
        uint256 balanceBefore = strategy.totalAssets();
        vm.startPrank(randomUser);
        ERC20(asset).approve(address(strategy), amount);
        strategy.deposit(amount, OUSD);
        uint256 balanceAfter = strategy.totalAssets();
        assertGt(balanceAfter, balanceBefore, "!balance");
    }

    function _test_uniswapV3_swap() public {
        uint256 amount = 1000e6;
        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(management);
        IMorphoCompounder(address(strategy)).setDoHealthCheck(false);

        airdrop(ERC20(swapToken), address(strategy), amount);

        assertEq(
            ERC20(swapToken).balanceOf(address(strategy)),
            amount,
            "!swap"
        );
        assertEq(asset.balanceOf(address(strategy)), 0, "!asset");

        vm.prank(keeper);
        strategy.report();

        assertEq(ERC20(swapToken).balanceOf(address(strategy)), 0, "!swap");
        assertGt(asset.balanceOf(address(strategy)), 0, "!asset");
    }

    function test_auctionSwap() public {
        uint256 amount = 1000e6;
        mintAndDepositIntoStrategy(strategy, user, amount);

        airdrop(ERC20(swapToken), address(strategy), amount);

        address auction = AuctionFactory(
            0xa076c247AfA44f8F006CA7f21A4EF59f7e4dc605
        ).createNewAuction(address(asset), address(strategy), management);

        vm.prank(management);
        Auction(auction).enable(swapToken);

        vm.prank(management);
        IMorphoCompounder(address(strategy)).setSwapType(
            swapToken,
            IMorphoCompounder.SwapType.AUCTION
        );

        vm.prank(management);
        IMorphoCompounder(address(strategy)).setAuction(address(auction));

        assertEq(
            ERC20(swapToken).balanceOf(address(strategy)),
            amount,
            "!swap"
        );

        vm.prank(keeper);
        uint256 kicked = IMorphoCompounder(address(strategy)).kickAuction(
            swapToken
        );

        assertEq(kicked, amount, "!kicked");
        assertEq(ERC20(swapToken).balanceOf(address(strategy)), 0, "!swap");
        assertEq(asset.balanceOf(address(strategy)), 0, "!asset");
        assertTrue(Auction(auction).isActive(swapToken), "!active");
    }

    function test_allRewardTokens() public {
        vm.expectRevert();
        vm.prank(management);
        IMorphoCompounder(address(strategy)).addRewardToken(
            address(asset),
            IMorphoCompounder.SwapType.UNISWAP_V3
        );

        vm.expectRevert();
        vm.prank(management);
        IMorphoCompounder(address(strategy)).addRewardToken(
            address(vault),
            IMorphoCompounder.SwapType.UNISWAP_V3
        );

        assertEq(
            IMorphoCompounder(address(strategy)).getAllRewardTokens().length,
            1,
            "!length"
        );
        assertEq(
            IMorphoCompounder(address(strategy)).getAllRewardTokens()[0],
            swapToken,
            "!swapToken"
        );

        address toAdd = tokenAddrs["DAI"];

        vm.prank(management);
        IMorphoCompounder(address(strategy)).addRewardToken(
            toAdd,
            IMorphoCompounder.SwapType.UNISWAP_V3
        );

        assertEq(
            IMorphoCompounder(address(strategy)).getAllRewardTokens().length,
            2,
            "!length"
        );
        assertEq(
            IMorphoCompounder(address(strategy)).getAllRewardTokens()[1],
            toAdd,
            "!toAdd"
        );

        vm.prank(management);
        IMorphoCompounder(address(strategy)).removeRewardToken(swapToken);

        assertEq(
            IMorphoCompounder(address(strategy)).getAllRewardTokens().length,
            1,
            "!length"
        );
        assertEq(
            IMorphoCompounder(address(strategy)).getAllRewardTokens()[0],
            toAdd,
            "!toAdd"
        );
        assertEq(
            uint256(IMorphoCompounder(address(strategy)).swapType(swapToken)),
            0,
            "!swapType"
        );

        vm.prank(management);
        IMorphoCompounder(address(strategy)).removeRewardToken(toAdd);

        assertEq(
            IMorphoCompounder(address(strategy)).getAllRewardTokens().length,
            0,
            "!length"
        );
        assertEq(
            uint256(IMorphoCompounder(address(strategy)).swapType(toAdd)),
            0,
            "!swapType"
        );
    }
}
