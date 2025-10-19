// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import "../src/StakeVault.sol";
import {DeployStakeVault} from "../script/DeployStakeVault.s.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {ERC20Mock} from "./mocks/Erc20Mocks.sol";
import {PriceConverter} from "../src/PriceConverter.sol";
import {BadReciever} from "./mocks/BadReciever.sol";
import {MockV3Aggregator} from "@chainlink/src/v0.8/tests/MockV3Aggregator.sol";

contract StakeVaultTest is Test {
    using PriceConverter for uint256;

    HelperConfig helper;
    DeployStakeVault deployer;
    StakeVault vault;
    BadReciever bad;
    MockV3Aggregator mock;

    address private priceFeed;
    address private usdcAddress;

    int256 initialAnswer = 0;
    uint8 decimals = 8;

    address user = makeAddr("user");

    uint256 private constant STARTING_USER_BALANCE = 200 ether;
    uint256 private constant USDC_STARTING_USER_BALANCE = 200000e6;
    uint256 private constant STAKING_AMOUNT = 1 ether;
    uint256 private constant DEPOSIT_AMOUNT = 2 ether;
    uint256 private constant USDC_DEPOSIT_AMOUNT = 1000e6;
    uint256 private constant USDC_STAKING_AMOUNT = 100e6;

    /* Events */
    event Deposited(address indexed sender, uint256 amount);
    event Staked(address indexed sender, uint256 amount);
    event UnStaked(address indexed sender, uint256 reward);
    event RewardProvidedETH(uint256 reward);
    event RewardProvidedUSDC(uint256 reward);
    event Withdraw(address indexed sender, uint256 amount);
    event ETHRewardNotify(uint256 reward, uint256 time, uint256 providedReward);
    event USDCRewardNotify(uint256 reward, uint256 time, uint256 providedReward);
    event NotifyRewardUSDC(uint256 amount);
    event NotifyRewardETH(uint256 amount);

    function setUp() external {
        deployer = new DeployStakeVault();
        helper = new HelperConfig();
		(vault, helper) = deployer.run();
        (priceFeed, usdcAddress) = helper.activeNetworkConfig();
		
        bad = new BadReciever();

        deal(user, STARTING_USER_BALANCE);

        ERC20Mock(usdcAddress).mint(user, USDC_STARTING_USER_BALANCE);
		
        ERC20Mock(usdcAddress).mint(address(bad), USDC_STARTING_USER_BALANCE);
		vm.prank(address(bad));
		ERC20Mock(usdcAddress).approve(address(bad), USDC_STARTING_USER_BALANCE);
    }

    //________________________________________
    // Modifiers
    //________________________________________

    modifier isPaused() {
        vm.prank(msg.sender);
        vault.pause();
        _;
    }

    modifier depositEth() {
        vm.startPrank(user);
        vault.depositETH{value: DEPOSIT_AMOUNT}();
        vm.stopPrank();
        _;
    }

    modifier depositUsdc() {
        vm.prank(user);
        ERC20Mock(usdcAddress).approve(address(vault), USDC_STARTING_USER_BALANCE);

        vm.prank(user);
        vault.depositUSDC(USDC_DEPOSIT_AMOUNT);
        _;
    }

    modifier stakedETH() {
        vm.prank(user);
        vault.stake(StakeVault.TokenType.ETH, STAKING_AMOUNT);

        console.log(vault.getSakedValueInUsd(user), "amount");
        _;
    }

    modifier stakedUSDC() {
        vm.prank(user);
        vault.stake(StakeVault.TokenType.USDC, USDC_STAKING_AMOUNT);
        _;
    }

    modifier fundETHPool() {
        uint256 fundedAmount = 20000000000 ether;

        vm.deal(address(vault), fundedAmount);

        vm.prank(msg.sender);
        vault.fundProvidedReward(StakeVault.TokenType.ETH, fundedAmount);
        _;
    }

    modifier fundUSDCPool() {
        uint256 fundedUSDCAmount = 100000e6;

        ERC20Mock(usdcAddress).mint(address(vault), fundedUSDCAmount);

        vm.prank(msg.sender);
        vault.fundProvidedReward(StakeVault.TokenType.USDC, fundedUSDCAmount);
        _;
    }

    modifier fundETHDepositorsPool() {
        uint256 fundedAmount = 1000 ether;

        vm.deal(address(vault), fundedAmount);

        vm.prank(msg.sender);
        vault.fundDepositorsProvidedPool(StakeVault.TokenType.ETH, fundedAmount);
        _;
    }

    modifier fundUSDCDepositorsPool() {
        uint256 fundedAmount = 5000000e6;

        ERC20Mock(usdcAddress).mint(address(vault), 5000000e6);

        vm.prank(msg.sender);
        vault.fundDepositorsProvidedPool(StakeVault.TokenType.USDC, fundedAmount);
        _;
    }

    modifier unStaked() {
        vm.prank(user);
        vault.unStake();
        _;
    }

    modifier time() {
        vm.warp(block.timestamp + 60 days);
        _;
    }

    //________________________________________
    // Tests
    //________________________________________

    function testVersionOfThePriceFeedNode() public view {
        uint256 version = PriceConverter.getVersion(MockV3Aggregator(priceFeed));

        assertEq(version, 4);
    }

    function testStakerRewardRateReturnRate() public view {
        uint256 rate = 5000;

        uint256 rewardRate = vault.getStakerRewardRate();

        assertEq(rewardRate, rate);
    }

    //________________________________________
    // pause
    //________________________________________

    function testRevertIfContractIsAlreadyPaused() public isPaused {
        vm.expectRevert(StakeVault__ContractIsPaused.selector);
        vm.prank(msg.sender);
        vault.pause();
    }

    function testRevertIfNotOwnerCalledPause() public {
        vm.expectRevert(StakeVault__UnAuthorized.selector);
        vm.prank(user);
        vault.pause();
    }

    function testRevertWhenContractIsPause() public isPaused {
        vm.expectRevert(StakeVault__ContractIsPaused.selector);
        vm.prank(user);
        vault.depositETH{value: DEPOSIT_AMOUNT}();
    }

    function testPauseOnWithoutTrnx() public isPaused {
        vm.expectRevert(StakeVault__ContractIsPaused.selector);
        vm.prank(user);
        vault.depositETH{value: DEPOSIT_AMOUNT}();

        assertEq(vault.getETHBalanceOfUser(user), 0);
        assert(vault.getDepositor(user) == false);
        assert(vault.getContractState() == true);
    }

    ///________________________________________
    /// UnPaused
    ///________________________________________

    function testUnPausedRevertWhenContractIsNotPaused() public {
        vm.expectRevert(StakeVault__ContractIsNotPaused.selector);
        vm.prank(msg.sender);
        vault.unPause();
    }

    function testRevertWhenUnpausedIsCalledByUser() public {
        vm.expectRevert(StakeVault__UnAuthorized.selector);
        vm.prank(user);
        vault.unPause();
    }

    function testtrnxPassedWhenContractIsUnPaused() public isPaused {
        vm.prank(msg.sender);
        vault.unPause();
		
		vm.prank(user);
		ERC20Mock(usdcAddress).approve(address(vault), USDC_STARTING_USER_BALANCE);

        vm.prank(user);
        vault.depositETH{value: DEPOSIT_AMOUNT}();
    }

    ////________________________________________
    /// Deposit Ether
    ////________________________________________

    function testDepositEtherRevertWhenDeposiMinValue() public {
        vm.expectRevert(StakeVault__DepositFailed.selector);
        vm.prank(user);
        vault.depositETH();
    }

    function testDepostETHRevertWhenDepositMax() public {
        vm.expectRevert(StakeVault__DepositFailed.selector);
        vm.prank(user);
        vault.depositETH{value: STARTING_USER_BALANCE}();
    }

    function testDepositETHPassedWhenMinAmount() public {
        vm.prank(user);
        vault.depositETH{value: DEPOSIT_AMOUNT}();

        assertEq(vault.getDepositor(user), true);
    }

    function testDepositEthPaseedWhenDepositMaxAmount() public {
        vm.prank(user);
        vault.depositETH{value: 22.2 ether}();

        assertEq(vault.getDepositor(user), true);
    }

    function testDepositPassedEmitEventUpdateTimeAndBalance() public {
        vm.expectEmit();
        emit Deposited(user, DEPOSIT_AMOUNT);

        vm.prank(user);
        vault.depositETH{value: DEPOSIT_AMOUNT}();

        assertEq(vault.getETHBalanceOfUser(user), DEPOSIT_AMOUNT);
        assert(vault.getDepositorTimeStamp(user) == block.timestamp);
    }

    function testDepositETHRevertWhenContractIsPaused() public isPaused {
        vm.expectRevert(StakeVault__ContractIsPaused.selector);
        vm.prank(user);
        vault.depositETH{value: DEPOSIT_AMOUNT}();
    }

    function testDepositPassedWhenContractIsUnlocked() public isPaused {
        vm.prank(msg.sender);
        vault.unPause();

        vm.prank(user);
        vault.depositETH{value: DEPOSIT_AMOUNT}();
    }

    function testMultipleDepositByUser() public {
        vm.prank(user);
        vault.depositETH{value: DEPOSIT_AMOUNT}();

        uint256 balanceOfUser = vault.getETHBalanceOfUser(user);
        assertEq(balanceOfUser, DEPOSIT_AMOUNT);

        uint256 secondDeposit = 0.3 ether;
        vm.prank(user);
        vault.depositETH{value: secondDeposit}();

        uint256 balanceAfter = vault.getETHBalanceOfUser(user);
        uint256 expectedTotal = secondDeposit + DEPOSIT_AMOUNT;

        assertEq(balanceAfter, expectedTotal, "user balance should increase after each deposit");
        assertEq(vault.getDepositor(user), true);
    }

    //________________________________________
    // Deposit USDC
    //________________________________________

    function testDepositUSDCRevertWhenSendBelowMinmumDeposit() public {
        uint256 amountBelowMinimum = 1e6;

        vm.prank(user);
        ERC20Mock(usdcAddress).approve(address(vault), amountBelowMinimum);

        vm.expectRevert(StakeVault__DepositFailed.selector);
        vm.prank(user);
        vault.depositUSDC(amountBelowMinimum);
    }

    function testDepositUSDCRevertIfMoreThanMaximum() public {
        uint256 higherBalance = 200_000e6;

        ERC20Mock(usdcAddress).approve(address(vault), higherBalance);
        vm.expectRevert(StakeVault__DepositFailed.selector);
        vm.prank(user);
        vault.depositUSDC(higherBalance);
    }

    function testDepositUSDCPassedWhenDepositMinimumUsdc() public {
        uint256 mini_USDC = 10e6;

        vm.prank(user);
        ERC20Mock(usdcAddress).approve(address(vault), USDC_STARTING_USER_BALANCE);

        vm.prank(user);
        vault.depositUSDC(mini_USDC);

        assertEq(vault.getDepositor(user), true);
    }

    function testDepositUsdcPassedWhenMaxUsdcIsDeposited() public {
        uint256 maxDeposit = 100_000e6;

        vm.prank(user);
        ERC20Mock(usdcAddress).approve(address(vault), USDC_STARTING_USER_BALANCE);

        vm.prank(user);
        vault.depositUSDC(maxDeposit);

        assertEq(vault.getUSDCBalanceOfDepositor(user), maxDeposit);
    }

    function testDepositUsdcRevertWhenContractIsPaused() public isPaused {
        vm.prank(user);
        ERC20Mock(usdcAddress).approve(address(vault), USDC_STARTING_USER_BALANCE);

        vm.expectRevert(StakeVault__ContractIsPaused.selector);
        vm.prank(user);
        vault.depositUSDC(USDC_DEPOSIT_AMOUNT);
    }

    function testDepositUSDCPassedWhenContractIsUnPused() public isPaused {
        vm.prank(msg.sender);
        vault.unPause();

        vm.prank(user);
        ERC20Mock(usdcAddress).approve(address(vault), USDC_STARTING_USER_BALANCE);

        vm.prank(user);
        vault.depositUSDC(USDC_DEPOSIT_AMOUNT);

        assertEq(vault.getUSDCBalanceOfDepositor(user), USDC_DEPOSIT_AMOUNT);
    }

    function testDepositUSDCPassedEmitEventUpdateTimeAndBalance() public {
        vm.prank(user);
        ERC20Mock(usdcAddress).approve(address(vault), USDC_STARTING_USER_BALANCE);

        vm.expectEmit(true, false, false, true);
        emit Deposited(user, USDC_DEPOSIT_AMOUNT);

        vm.prank(user);
        vault.depositUSDC(USDC_DEPOSIT_AMOUNT);

        assertEq(vault.getUSDCBalanceOfDepositor(user), USDC_DEPOSIT_AMOUNT);
        assertEq(vault.getDepositor(user), true);
        assertEq(vault.getDepositorTimeStamp(user), block.timestamp);
    }

    function testMultipleDepositUSDCByUser() public {
        uint256 newDeposit = 100e6;

        vm.prank(user);
        ERC20Mock(usdcAddress).approve(address(vault), USDC_STARTING_USER_BALANCE);

        vm.startPrank(user);
        vault.depositUSDC(USDC_DEPOSIT_AMOUNT);
        vault.depositUSDC(newDeposit);
        vm.stopPrank();

        uint256 newBalance = USDC_DEPOSIT_AMOUNT + newDeposit;

        assertEq(vault.getUSDCBalanceOfDepositor(user), newBalance);
        assertEq(vault.getDepositor(user), true);
        assertEq(vault.getDepositorTimeStamp(user), block.timestamp);
    }

    function testDepositUSDCRevertWhenUserHasNoAllowance() public {
        vm.expectRevert();
        vm.prank(user);
        vault.depositUSDC(USDC_DEPOSIT_AMOUNT);
    }

    function testDepositUSDCRevertWhenUserHasInsufficientBalance() public {
        address john = makeAddr("john");
        ERC20Mock(usdcAddress).mint(john, 2000e6);

        uint256 depositedAmount = 2001e6;

        vm.prank(john);
        ERC20Mock(usdcAddress).approve(address(vault), depositedAmount);

        vm.expectRevert();
        vm.prank(john);
        vault.depositUSDC(depositedAmount);
    }

    //________________________________________
    // Stake ETH
    //________________________________________

    function testStakeETHRevertIfNotDepositor() public {
        vm.expectRevert(StakeVault__NotDepositor.selector);
        vm.prank(user);
        vault.stake(StakeVault.TokenType.ETH, 0.1 ether);
    }

    function testRevertIfBalanceIsLessThanAmount() public depositEth {
        uint256 stakedAmount = 3 ether;

        vm.expectRevert(StakeVault__InsufficientFunds.selector);
        vm.prank(user);
        vault.stake(StakeVault.TokenType.ETH, stakedAmount);
    }

    function testRevertIfStakeBelowMiniumStake() public depositEth {
        uint256 stakedValue = 0.0001 ether;

        vm.expectRevert(StakeVault__StakeLimitExceded.selector);
        vm.prank(user);
        vault.stake(StakeVault.TokenType.ETH, stakedValue);
    }

    function testRevertIfDepositIsAboveMaxStake() public {
        uint256 maxStake = 22.22 ether;

        vm.startPrank(user);
        vault.depositETH{value: maxStake}();
        vault.depositETH{value: maxStake}();

        vm.expectRevert(StakeVault__StakeLimitExceded.selector);
        vault.stake(StakeVault.TokenType.ETH, 23 ether);
        vm.stopPrank();
    }

    function testStakeETHPassedOnMin() public depositEth {
        uint256 stakedValue = 0.1111 ether;

        vm.prank(user);
        vault.stake(StakeVault.TokenType.ETH, stakedValue);

        uint256 expectedValue = stakedValue.getConversionRate(MockV3Aggregator(priceFeed));

        assertEq(vault.getSakedValueInUsd(user), expectedValue);
    }

    function testStakePaasedOnMax() public {
        uint256 stakedValue = 22.22 ether;
        uint256 depositedETH = 22 ether;

        vm.startPrank(user);
        vault.depositETH{value: depositedETH}();
        vault.depositETH{value: depositedETH}();
        vault.stake(StakeVault.TokenType.ETH, stakedValue);

        uint256 expectedTotalStaked = stakedValue.getConversionRate(MockV3Aggregator(priceFeed));
        uint256 expectedBalance = (depositedETH * 2) - stakedValue;

        assertEq(vault.getSakedValueInUsd(user), expectedTotalStaked);
        assertEq(vault.getETHBalanceOfUser(user), expectedBalance);
    }

    function testStakeETHPassedEmitEvenRecordStakerUpdateTimeAndUpdateBalances() public depositEth {
        vm.expectEmit();
        emit Staked(user, STAKING_AMOUNT);

        vm.prank(user);
        vault.stake(StakeVault.TokenType.ETH, STAKING_AMOUNT);

        uint256 expectedBalance = DEPOSIT_AMOUNT - STAKING_AMOUNT;
        uint256 expectedTotalStaked = STAKING_AMOUNT.getConversionRate(MockV3Aggregator(priceFeed));

        assertEq(vault.getSakedValueInUsd(user), expectedTotalStaked);
        assertEq(vault.getStakedTime(user), block.timestamp);
        assertEq(vault.getETHBalanceOfUser(user), expectedBalance);
        assertEq(vault.getStakers(user), true);
        assert(vault.getStakedTokenType(user) == StakeVault.TokenType.ETH);
    }

    function testStakeEthRevertWhenContractIsPaused() public depositEth isPaused {
        vm.expectRevert(StakeVault__ContractIsPaused.selector);
        vm.prank(user);
        vault.stake(StakeVault.TokenType.ETH, STAKING_AMOUNT);
    }

    function testStakeETHPassedWhenContractIsUnlock() public depositEth isPaused {
        vm.prank(msg.sender);
        vault.unPause();

        vm.prank(user);
        vault.stake(StakeVault.TokenType.ETH, STAKING_AMOUNT);

        assertEq(vault.getStakers(user), true);
    }

    function testMultipleStakesETHWithoutUnstaking() public depositEth stakedETH {
        vm.warp(block.timestamp + 10 days);

        uint256 deposited = 0.5 ether;

        vm.prank(user);
        vault.stake(StakeVault.TokenType.ETH, deposited);

        uint256 totalStaked = STAKING_AMOUNT + deposited;
        uint256 expectedStaked = vault.getSakedValueInUsd(user).getConversionRateUsdToEth(MockV3Aggregator(priceFeed));

        assertEq(expectedStaked, totalStaked);
    }

    function testMultipleUsersStake() public {
        uint256 indexOfStakers = 30;

        for (uint256 i = 0; i < indexOfStakers; i++) {
            address stakers = makeAddr(string(abi.encodePacked("stakers", i)));

            hoax(stakers, STARTING_USER_BALANCE);
            vault.depositETH{value: DEPOSIT_AMOUNT}();

            vm.startPrank(stakers);
            vault.stake(StakeVault.TokenType.ETH, STAKING_AMOUNT);
            vm.stopPrank();

            uint256 expectedTotalStaked = STAKING_AMOUNT.getConversionRate(MockV3Aggregator(priceFeed));
            uint256 expectedBalance = DEPOSIT_AMOUNT - STAKING_AMOUNT;

            assertEq(vault.getStakedTime(stakers), block.timestamp);
            assert(vault.getStakers(stakers) == true);
            assertEq(vault.getSakedValueInUsd(stakers), expectedTotalStaked);
            assertEq(vault.getETHBalanceOfUser(stakers), expectedBalance);
        }
    }

    //________________________________________
    // STAKE USDC
    //________________________________________

    function testStakeUsdcRevertWhenContractIsPaused() public depositUsdc isPaused {
        vm.expectRevert(StakeVault__ContractIsPaused.selector);
        vm.prank(user);
        vault.stake(StakeVault.TokenType.USDC, USDC_STAKING_AMOUNT);
    }

    function testRevertWhenUserSelectWrongTokenType() public depositUsdc {
        vm.expectRevert(StakeVault__InsufficientFunds.selector);
        vm.prank(user);
        vault.stake(StakeVault.TokenType.USDC, 0.01 ether);
    }

    function testRevertWhenUserDepositEthAndTryToStakeUsdc() public depositEth {
        vm.expectRevert(StakeVault__InsufficientFunds.selector);
        vm.prank(user);
        vault.stake(StakeVault.TokenType.USDC, USDC_STAKING_AMOUNT);
    }

    function testRevertWhenUserIsNotADepositorButTryToStake() public {
        vm.expectRevert(StakeVault__NotDepositor.selector);
        vm.prank(user);
        vault.stake(StakeVault.TokenType.USDC, USDC_STAKING_AMOUNT);
    }

    function testRevertWhenUserIsTryingToStakeMoreThanBalance() public depositUsdc {
        vm.expectRevert(StakeVault__InsufficientFunds.selector);
        vm.prank(user);
        vault.stake(StakeVault.TokenType.USDC, USDC_STARTING_USER_BALANCE);
    }

    function testRevertWhenOwnerTriesToStakeWithoutDeposit() public depositUsdc {
        vm.expectRevert(StakeVault__NotDepositor.selector);
        vm.prank(msg.sender);
        vault.stake(StakeVault.TokenType.USDC, USDC_STAKING_AMOUNT);
    }

    function testRevertWhenContractTriesToStakeForUser() public depositUsdc {
        vm.expectRevert(StakeVault__NotDepositor.selector);
        vm.prank(address(this));
        vault.stake(StakeVault.TokenType.USDC, USDC_STAKING_AMOUNT);
    }

    function testRevertWhenUserDepositUsdcAndTryToStakeEth() public depositUsdc {
        vm.expectRevert(StakeVault__InsufficientFunds.selector);
        vm.prank(user);
        vault.stake(StakeVault.TokenType.ETH, STAKING_AMOUNT);
    }

    function testRevertWhenRandomAddressTriesToStakeUserFunds() public depositUsdc depositEth {
        address bob = makeAddr("bob");

        vm.expectRevert(StakeVault__NotDepositor.selector);
        vm.prank(bob);
        vault.stake(StakeVault.TokenType.USDC, USDC_STAKING_AMOUNT);
    }

    function testStakeUsdPassWhenContractIsUnPaused() public depositUsdc isPaused {
        vm.prank(msg.sender);
        vault.unPause();

        vm.prank(user);
        vault.stake(StakeVault.TokenType.USDC, USDC_STAKING_AMOUNT);

        assert(vault.getStakers(user) == true);
    }

    function testMultipleStakesUSDCWithoutUnstaking() public depositUsdc stakedUSDC {
        vm.warp(block.timestamp + 5 days);

        vm.prank(user);
        vault.stake(StakeVault.TokenType.USDC, USDC_STAKING_AMOUNT);

        uint256 expextedStakes = USDC_STAKING_AMOUNT * 2;

        assertEq(vault.getSakedValueInUsd(user), expextedStakes);
    }

    function testStakeUsdcPassedWithMinimumStake() public depositUsdc {
        uint256 minimumStake = 50e6;

        vm.prank(user);
        vault.stake(StakeVault.TokenType.USDC, minimumStake);

        assert(vault.getStakedTokenType(user) == StakeVault.TokenType.USDC);
        assertEq(vault.getSakedValueInUsd(user), minimumStake);
        assert(vault.getStakers(user) == true);
    }

    function testStakePassWithMaximumUsdc() public {
        uint256 maxStakeUsdc = 100_000e6;
        address pat = makeAddr("pat");
        ERC20Mock(usdcAddress).mint(pat, maxStakeUsdc);

        vm.startPrank(pat);
        ERC20Mock(usdcAddress).approve(address(vault), maxStakeUsdc);
        vault.depositUSDC(maxStakeUsdc);
        vault.stake(StakeVault.TokenType.USDC, maxStakeUsdc);
        vm.stopPrank();

        assert(vault.getStakedTokenType(pat) == StakeVault.TokenType.USDC);
        assertEq(vault.getSakedValueInUsd(pat), maxStakeUsdc);
        assert(vault.getStakers(pat) == true);
        assertEq(vault.getUSDCBalanceOfDepositor(pat), 0);
    }

    function testMultipleStakePassUpdateBalanceEmitEventAndTime() public depositUsdc {
        uint256 value1 = 60e6;
        uint256 value2 = 55e6;
        uint256 value3 = 500e6;
        uint256 value4 = 105e6;

        vm.expectEmit();
        emit Staked(user, USDC_STAKING_AMOUNT);

        vm.startPrank(user);
        vault.stake(StakeVault.TokenType.USDC, USDC_STAKING_AMOUNT);
        vault.stake(StakeVault.TokenType.USDC, value4);
        vault.stake(StakeVault.TokenType.USDC, value1);
        vault.stake(StakeVault.TokenType.USDC, value3);
        vault.stake(StakeVault.TokenType.USDC, value2);
        vm.stopPrank();

        uint256 expectedStaked = value1 + value2 + value3 + value4 + USDC_STAKING_AMOUNT;
        uint256 expectedBalance = USDC_DEPOSIT_AMOUNT - expectedStaked;

        assert(vault.getStakedTokenType(user) == StakeVault.TokenType.USDC);
        assertEq(vault.getSakedValueInUsd(user), expectedStaked);
        assert(vault.getStakers(user) == true);
        assertEq(vault.getUSDCBalanceOfDepositor(user), expectedBalance);
        assertEq(vault.getStakedTime(user), block.timestamp);
    }

    //________________________________________
    //   UnSTAKE
    //________________________________________

    function testRevertIfNotStaked() public depositEth {
        vm.expectRevert(StakeVault__NotAStaker.selector);
        vm.prank(user);
        vault.unStake();
    }

    function testRevertWhenContractOwnerTryToRevert() public {
        vm.expectRevert(StakeVault__NotAStaker.selector);
        vm.prank(msg.sender);
        vault.unStake();
    }

    function testRevertWhenContractTryToUnstakeForUser() public depositEth stakedETH {
        vm.expectRevert(StakeVault__NotAStaker.selector);
        vm.prank(address(vault));
        vault.unStake();
    }

    function testRevertIfARandomAddrCalledUnStake() public depositEth stakedETH {
        address fishing = makeAddr("fishing");

        vm.expectRevert(StakeVault__NotAStaker.selector);
        vm.prank(fishing);
        vault.unStake();
    }

    function testUnstakedPassIsStaked() public depositUsdc stakedUSDC {
        vm.prank(user);
        vault.unStake();
    }

    function testRevertIfUserTryToUnStakeWrongTokeidity() public depositEth stakedETH fundETHPool {
        vm.prank(user);
        vault.unStake();
    }

    function testUnstakeRevertWhenContractIsPaused() public depositUsdc stakedUSDC isPaused {
        vm.expectRevert(StakeVault__ContractIsPaused.selector);
        vm.prank(user);
        vault.unStake();
    }

    function testRevertIfETHRewardMoreThanRwardPool() public depositEth stakedETH {
        vm.warp(block.timestamp + 200 days);

        vm.prank(msg.sender);
        vault.fundProvidedReward(StakeVault.TokenType.ETH, 0.0001 ether);

        vm.expectRevert(StakeVault__InsufficientRewardPool.selector);
        vm.prank(user);
        vault.unStake();
    }

    function testRevertIfUSDCRewardMoreThanPool() public depositUsdc stakedUSDC {
        vm.warp(block.timestamp + 50 days);

        vm.prank(msg.sender);
        vault.fundProvidedReward(StakeVault.TokenType.USDC, 10e6);

        vm.expectRevert(StakeVault__InsufficientRewardPool.selector);
        vm.prank(user);
        vault.unStake();
    }

    function testUnstakePassedWhenContractIsUnPause() public depositEth stakedETH isPaused {
        vm.prank(msg.sender);
        vault.unPause();

        vm.prank(user);
        vault.unStake();

        assertEq(vault.getSakedValueInUsd(user), 0);
        assertEq(vault.getUnStakedTime(user), block.timestamp + 1 days);
    }

    function testUnstakeCountdownContinueWhenContractIsPaused() public depositEth stakedETH {
        vm.prank(msg.sender);
        vault.fundProvidedReward(StakeVault.TokenType.ETH, 1000 ether);

        vm.prank(user);
        vault.unStake();

        uint256 unstakeTime = vault.getUnStakedTime(user);

        vm.prank(msg.sender);
        vault.pause();

        vm.warp(block.timestamp + 120);

        vm.prank(msg.sender);
        vault.unPause();

        vm.warp(block.timestamp + 60);
        uint256 expectedTime = vault.getUnStakedTime(user);

        assert(expectedTime == unstakeTime);
    }

    function testunstakePaseedUpdateAllStateAndEmitEventForETH() public depositEth stakedETH {
        uint256 providedETHReward = 1000e18;

        vm.expectEmit();
        emit RewardProvidedETH(providedETHReward);
        vm.prank(msg.sender);
        vault.fundProvidedReward(StakeVault.TokenType.ETH, providedETHReward);

        vm.warp(block.timestamp + 50 days);

        uint256 reward = vault._pendingReward(user).getConversionRateUsdToEth(MockV3Aggregator(priceFeed));
        uint256 amountStakedInUsd =
            vault.getSakedValueInUsd(user).getConversionRateUsdToEth(MockV3Aggregator(priceFeed));

        uint256 totalPayout = reward + amountStakedInUsd;

        vm.expectEmit();
        emit UnStaked(user, totalPayout);

        vm.prank(user);
        vault.unStake();

        uint256 expectedUnStakeTime = block.timestamp + 1 days;

        assertEq(vault.getUnStakedTime(user), expectedUnStakeTime);
        assertEq(vault.getStakerReward(user), totalPayout);
        assertEq(vault.getSakedValueInUsd(user), 0);
        assertEq(vault.getStakedTime(user), 0);
        assert(vault.getStakers(user) == false);
    }

    function testUnStakePaseedUpdateAllStateAndEmitEventForUSDC() public depositUsdc stakedUSDC {
        vm.warp(block.timestamp + 100 days);

        uint256 poolReward = 10000000e6;

        vm.expectEmit();
        emit RewardProvidedUSDC(poolReward);

        vm.prank(msg.sender);
        vault.fundProvidedReward(StakeVault.TokenType.USDC, poolReward);

        uint256 reward = vault._pendingReward(user);
        uint256 amountStakedInUsd = vault.getSakedValueInUsd(user);
        uint256 totalPayout = reward + amountStakedInUsd;

        vm.expectEmit();
        emit UnStaked(user, totalPayout);

        vm.prank(user);
        vault.unStake();

        uint256 expectedUnStakeTime = block.timestamp + 1 days;

        assertEq(vault.getUnStakedTime(user), expectedUnStakeTime);
        assertEq(vault.getStakerReward(user), totalPayout);
        assertEq(vault.getSakedValueInUsd(user), 0);
        assertEq(vault.getStakedTime(user), 0);
        assert(vault.getStakers(user) == false);
    }

    function testMultipleUsersUnStakedETH() public {
        uint256 fundingAmount = 1000000 ether;
        uint256 indexedOfUsers = 100;

        for (uint256 i = 0; i < indexedOfUsers; i++) {
            address users = makeAddr(string(abi.encodePacked("users", i)));

            hoax(users, STARTING_USER_BALANCE);
            vault.depositETH{value: DEPOSIT_AMOUNT}();

            vm.prank(users);
            vault.stake(StakeVault.TokenType.ETH, STAKING_AMOUNT);

            uint256 stakedValue = vault.getSakedValueInUsd(users).getConversionRateUsdToEth(MockV3Aggregator(priceFeed));

            vm.expectEmit();
            emit RewardProvidedETH(fundingAmount);

            vm.prank(msg.sender);
            vault.fundProvidedReward(StakeVault.TokenType.ETH, fundingAmount);

            vm.warp(block.timestamp + i * 198 days);

            uint256 unStakeTime = block.timestamp + 1 days;

            uint256 reward = vault._pendingReward(users).getConversionRateUsdToEth(MockV3Aggregator(priceFeed));

            uint256 totalPayout = stakedValue + reward;

            vm.expectEmit();
            emit UnStaked(users, totalPayout);

            vm.prank(users);
            vault.unStake();

            assertEq(vault.getStakerReward(users), totalPayout);
            assertEq(vault.getUnStakedTime(users), unStakeTime);
            assertEq(vault.getSakedValueInUsd(users), 0);
            assert(vault.getStakers(users) == false);
            assertEq(vault.getStakedTime(users), 0);
        }
    }

    function testMultipleUsersUnStakedUSDC() public {
        uint256 indexedOfUsers = 70;
        uint256 fundingAmount = 20_000_000_000e6;

        for (uint256 i = 0; i < indexedOfUsers; i++) {
            address users = makeAddr(string(abi.encodePacked("users", i)));

            ERC20Mock(usdcAddress).mint(users, USDC_STARTING_USER_BALANCE);

            vm.prank(users);
            ERC20Mock(usdcAddress).approve(address(vault), USDC_DEPOSIT_AMOUNT);

            hoax(users, USDC_STARTING_USER_BALANCE);
            vault.depositUSDC(USDC_DEPOSIT_AMOUNT);

            vm.prank(msg.sender);
            vault.fundProvidedReward(StakeVault.TokenType.USDC, fundingAmount);

            vm.prank(users);
            vault.stake(StakeVault.TokenType.USDC, USDC_STAKING_AMOUNT);

            uint256 stakingValue = vault.getSakedValueInUsd(users);

            vm.warp(block.timestamp + i * 1 days);

            uint256 unStakingTime = block.timestamp + 1 days;

            uint256 usersReward = vault._pendingReward(users);

            uint256 totalPayout = stakingValue + usersReward;

            vm.expectEmit();
            emit UnStaked(users, totalPayout);

            vm.prank(users);
            vault.unStake();

            assertEq(vault.getStakerReward(users), totalPayout);
            assertEq(vault.getUnStakedTime(users), unStakingTime);
            assertEq(vault.getSakedValueInUsd(user), 0);
            assertEq(vault.getStakedTime(users), 0);
            assert(vault.getStakers(users) == false);
        }
    }

    //________________________________________
    // WithdrawStaked
    //________________________________________

    function testWithdrawRevertIfNoUnStakeReward() public depositEth stakedETH fundETHPool unStaked {
        vm.expectRevert(StakeVault__CoolDownPeriodIsActive.selector);
        vm.prank(user);
        vault.withdraw(StakeVault.TokenType.ETH);
    }

    function testWithdrawETHRevertWhenCooldownActive() public depositEth stakedETH fundETHPool unStaked {
        vm.prank(user);
        vm.expectRevert(StakeVault__CoolDownPeriodIsActive.selector);
        vault.withdraw(StakeVault.TokenType.ETH);
    }

    function testWithdrawUSDCRevertWhenCooldownActive() public depositUsdc stakedUSDC fundUSDCPool unStaked {
        vm.prank(user);
        vm.expectRevert(StakeVault__CoolDownPeriodIsActive.selector);
        vault.withdraw(StakeVault.TokenType.USDC);
    }

    function testWithdrwaStakedRevertIfContractIsPaused()
        public
        depositUsdc
        stakedUSDC
        fundUSDCPool
        unStaked
        isPaused
    {
        vm.expectRevert(StakeVault__ContractIsPaused.selector);
        vm.prank(user);
        vault.withdraw(StakeVault.TokenType.USDC);
    }

    function testWithdrawStakedPassedWhenContractIsUnPaused()
        public
        depositEth
        stakedETH
        fundETHPool
        unStaked
        isPaused
    {
        vm.prank(msg.sender);
        vault.unPause();

        vm.warp(block.timestamp + 3 days);

        vm.prank(user);
        vault.withdraw(StakeVault.TokenType.ETH);

        assertEq(vault.getUSDCBalanceOfDepositor(user), 0);
        assert(vault.getDepositor(user) == false);
    }

    function testWithdrawETHTransferFails() public depositEth stakedETH time {
        uint256 fundingAmount = 1000 ether;

        vm.prank(msg.sender);
        vault.fundProvidedReward(StakeVault.TokenType.ETH, fundingAmount);

        vm.prank(user);
        vault.unStake();

        vm.warp(block.timestamp + 2 days);

        vm.expectRevert(StakeVault__WithdrawFailed.selector);
        vm.prank(user);
        vault.withdraw(StakeVault.TokenType.ETH);
    }

    function testWithdrawUSDCTransferFails() public depositUsdc stakedUSDC fundUSDCPool time unStaked {
	   vm.warp(block.timestamp + 1 days);

        ERC20Mock(usdcAddress).setBlockedReceiver(user);

        vm.expectRevert(StakeVault__WithdrawFailed.selector);
        vm.prank(user);
        vault.withdraw(StakeVault.TokenType.USDC);
    }

    function testWithdrawStakedETHPassedUpdateStateAndEmitEvent()
        public
        depositEth
        stakedETH
        fundETHPool
        time
        unStaked
    {
        vm.warp(block.timestamp + 1 days);

        uint256 reward = vault.getETHBalanceOfUser(user) + vault.getStakerReward(user);

        vm.expectEmit();
        emit Withdraw(user, reward);

        vm.prank(user);
        vault.withdraw(StakeVault.TokenType.ETH);

        assert(vault.getStakers(user) == false);
        assertEq(vault.getStakerReward(user), 0);
        assertEq(vault.getUnStakedTime(user), 0);
        assert(vault.getDepositor(user) == false);
        assertEq(vault.getETHBalanceOfUser(user), 0);
    }

    function testWithdrawStakedUSDCPassedUpdateStatesAndEmitEvents()
        public
        depositUsdc
        stakedUSDC
        fundUSDCPool
        time
        unStaked
    {
        vm.warp(block.timestamp + 1 days);

        uint256 reward = vault.getUSDCBalanceOfDepositor(user) + vault.getStakerReward(user);

        vm.expectEmit();
        emit Withdraw(user, reward);

        vm.prank(user);
        vault.withdraw(StakeVault.TokenType.USDC);

        assert(vault.getStakers(user) == false);
        assertEq(vault.getStakerReward(user), 0);
        assertEq(vault.getUnStakedTime(user), 0);
        assert(vault.getDepositor(user) == false);
        assertEq(vault.getETHBalanceOfUser(user), 0);
    }

    //________________________________________
    // WithdrawDeposit
    //________________________________________

    function testWithdrawDepositRevertWhenInsufficientETHAndUSDCRewardPool() public depositEth depositUsdc time {
        vm.expectRevert(StakeVault__InsufficientRewardPool.selector);
        vm.startPrank(user);
        vault.withdraw(StakeVault.TokenType.ETH);

        vm.expectRevert(StakeVault__InsufficientRewardPool.selector);
        vault.withdraw(StakeVault.TokenType.USDC);
        vm.stopPrank();
    }

    function testWithdrawDepositETHSuccess() public depositEth fundETHDepositorsPool time {
        uint256 reward = (DEPOSIT_AMOUNT * 60 days * 50) / (10000 * 200 days);

        uint256 expectedWithdraw = reward + DEPOSIT_AMOUNT;

        vm.expectEmit();
        emit Withdraw(user, expectedWithdraw);

        vm.prank(user);
        vault.withdraw(StakeVault.TokenType.ETH);

        assertEq(vault.getETHBalanceOfUser(user), 0);
    }

    function testWithdrawDepositUSDCSuccess() public depositUsdc fundUSDCDepositorsPool time {
        uint256 reward = USDC_DEPOSIT_AMOUNT * 60 days * 50 / (10000 * 200 days);

        uint256 expectedWithdraw = USDC_DEPOSIT_AMOUNT + reward;

        vm.expectEmit();
        emit Withdraw(user, expectedWithdraw);

        vm.prank(user);
        vault.withdraw(StakeVault.TokenType.USDC);

        assert(vault.getDepositor(user) == false);
    }

    function testWithdrawDepositUSDCTransferFails() public {
        vm.startPrank(msg.sender);
        vault.fundDepositorsProvidedPool(StakeVault.TokenType.USDC, 1000e6);
        vm.stopPrank();

        ERC20Mock(usdcAddress).mint(address(bad), USDC_STARTING_USER_BALANCE);

        vm.prank(address(bad));
        ERC20Mock(usdcAddress).approve(address(vault), USDC_STARTING_USER_BALANCE);

        vm.prank(address(bad));
        vault.depositUSDC(USDC_DEPOSIT_AMOUNT);

        vm.warp(block.timestamp + 30 days);

        ERC20Mock(usdcAddress).setBlockedReceiver(address(bad));

        vm.expectRevert(StakeVault__WithdrawFailed.selector);
        vm.prank(address(bad));
        vault.withdraw(StakeVault.TokenType.USDC);
    }

    function testWithdrawDepositETHTransferFails() public depositEth time {
        vm.startPrank(msg.sender);
        vault.fundDepositorsProvidedPool(StakeVault.TokenType.ETH, 100 ether);
        vm.stopPrank();

        vm.expectRevert(StakeVault__WithdrawFailed.selector);
        vm.prank(user);
        vault.withdraw(StakeVault.TokenType.ETH);
    }

    function testWithdrawDepositResetsDepositorStateETH() public depositEth time fundETHDepositorsPool {
        vm.prank(user);
        vault.withdraw(StakeVault.TokenType.ETH);

        assert(vault.getDepositor(user) == false);
        assertEq(vault.getDepositorTimeStamp(user), 0);
        assertEq(vault.getETHBalanceOfUser(user), 0);
    }

    function testWithdrawDepositResetsDepositorStateUSDC() public depositUsdc time fundUSDCDepositorsPool {
        vm.prank(user);
        vault.withdraw(StakeVault.TokenType.USDC);

        assertEq(vault.getDepositorTimeStamp(user), 0);
        assertEq(vault.getUSDCBalanceOfDepositor(user), 0);
        assert(vault.getDepositor(user) == false);
    }

    //________________________________________
    // NotifyRewardAmount
    //________________________________________

    function testNotifyRewardRevertIfZeroRewardWasAdded() public {
        vm.expectRevert(StakeVault__ZeroRewardCantBeAdded.selector);
        vm.startPrank(msg.sender);
        vault.notifyRewardAmount(StakeVault.TokenType.ETH, 0);

        vm.expectRevert(StakeVault__ZeroRewardCantBeAdded.selector);
        vault.notifyRewardAmount(StakeVault.TokenType.USDC, 0);
        vm.stopPrank();
    }

    function testNotifyRewardAmountRevertWhenPaused() public isPaused {
        vm.expectRevert(StakeVault__ContractIsPaused.selector);
        vm.startPrank(msg.sender);
        vault.notifyRewardAmount(StakeVault.TokenType.ETH, 10e18);

        vm.expectRevert(StakeVault__ContractIsPaused.selector);
        vault.notifyRewardAmount(StakeVault.TokenType.USDC, 100e6);
        vm.stopPrank();
    }

    function testNotifyRewardAmountWhenNotPaused() public {
        uint256 notityETHAmount = 100e18;
        uint256 notityUSDCAmount = 100e6;

        vm.startPrank(msg.sender);
        vault.notifyRewardAmount(StakeVault.TokenType.ETH, notityETHAmount);
        vault.pause();
        vm.warp(block.timestamp + 30 days);
        vault.unPause();
        vault.notifyRewardAmount(StakeVault.TokenType.USDC, notityUSDCAmount);
        vm.stopPrank();
    }

    function testNotifyRewardAmountOnlyOwner() public {
        address bob = makeAddr("bob");
        uint256 amountETH = 100 ether;
        uint256 amountUSDC = 100e6;

        vm.expectRevert(StakeVault__UnAuthorized.selector);
        vm.prank(user);
        vault.notifyRewardAmount(StakeVault.TokenType.ETH, amountETH);

        vm.prank(bob);
        vm.expectRevert(StakeVault__UnAuthorized.selector);
        vault.notifyRewardAmount(StakeVault.TokenType.USDC, amountUSDC);
    }

    function testNotifyRewardAmountInitialETH() public {
        uint256 reward = 1000 ether;
        uint256 expectedFinishTime = block.timestamp + 200 days;

        vm.expectEmit();
        emit NotifyRewardETH(reward);

        vm.prank(msg.sender);
        vault.notifyRewardAmount(StakeVault.TokenType.ETH, reward);

        assertEq(vault.getRewardFinishTimeETH(), expectedFinishTime);
        assertEq(vault.getLastUpdateTimeStamp(), block.timestamp);
    }

    function testNotifyRewardAmountInitialUSDC() public {
        uint256 reward = 100e6;
        uint256 expectedFinishTime = block.timestamp + 200 days;

        vm.expectEmit();
        emit NotifyRewardUSDC(reward);

        vm.prank(msg.sender);
        vault.notifyRewardAmount(StakeVault.TokenType.USDC, reward);

        assertEq(vault.getRewardFinishTimeUSDC(), expectedFinishTime);
        assertEq(vault.getLastUpdateTimeStamp(), block.timestamp);
    }

    function testNotifyRewardAmountExtendETHReward() public {
        uint256 reward1 = 100 ether;
        uint256 reward2 = 500 ether;
        uint256 rewardDuration = 200 days;

        vm.prank(msg.sender);
        vault.notifyRewardAmount(StakeVault.TokenType.ETH, reward1);

        uint256 initialTime = vault.getRewardFinishTimeETH();
        uint256 previousReward = vault.getprovidedRewardETH();

        vm.warp(block.timestamp + 120 days);

        uint256 remainingTime = initialTime - block.timestamp;
        uint256 leftOver = remainingTime * previousReward / rewardDuration;
        uint256 expectedReward = leftOver + reward2;
        uint256 expectedTime = rewardDuration + block.timestamp;

        vm.expectEmit();
        emit ETHRewardNotify(reward2, expectedTime, expectedReward);

        vm.prank(msg.sender);
        vault.notifyRewardAmount(StakeVault.TokenType.ETH, reward2);

        assertEq(vault.getRewardFinishTimeETH(), expectedTime);
        assertEq(vault.getprovidedRewardETH(), expectedReward);
        assertEq(vault.getLastUpdateTimeStamp(), block.timestamp);
    }

    function testNotifyRewardAmountExtendUSDCReward() public {
        uint256 reward1 = 10000e6;
        uint256 reward2 = 98798989e6;
        uint256 rewardDuration = 200 days;

        vm.prank(msg.sender);
        vault.notifyRewardAmount(StakeVault.TokenType.USDC, reward1);

        uint256 initialTime = vault.getRewardFinishTimeUSDC();
        uint256 previousReward = vault.getProvidedRewardUSDC();

        vm.warp(block.timestamp + 93 days);

        uint256 remainingTime = initialTime - block.timestamp;
        uint256 leftOver = remainingTime * previousReward / rewardDuration;
        uint256 expectedReward = leftOver + reward2;
        uint256 expectedTime = rewardDuration + block.timestamp;

        vm.expectEmit();
        emit USDCRewardNotify(reward2, expectedTime, expectedReward);

        vm.prank(msg.sender);
        vault.notifyRewardAmount(StakeVault.TokenType.USDC, reward2);

        assertEq(vault.getProvidedRewardUSDC(), expectedReward);
        assertEq(vault.getLastUpdateTimeStamp(), block.timestamp);
        assertEq(vault.getRewardFinishTimeUSDC(), expectedTime);
    }

    function testNotifyRewardAmountOverrideETH() public {
        uint256 reward1 = 239 ether;
        uint256 reward2 = 736 ether;
        uint256 rewardDuration = 200 days;

        vm.prank(msg.sender);
        vault.notifyRewardAmount(StakeVault.TokenType.ETH, reward1);

        vm.warp(block.timestamp + 205 days);

        vm.expectEmit();
        emit NotifyRewardETH(reward2);

        vm.prank(msg.sender);
        vault.notifyRewardAmount(StakeVault.TokenType.ETH, reward2);

        uint256 newTime = vault.getRewardFinishTimeETH();
        uint256 expectedTime = block.timestamp + rewardDuration;

        assertEq(vault.getprovidedRewardETH(), reward2);
        assertEq(vault.getLastUpdateTimeStamp(), block.timestamp);
        assertEq(newTime, expectedTime);
    }

    function testNotifyRewardAmountOverrideUSDC() public {
        uint256 reward1 = 100_000_000e6;
        uint256 reward2 = 770_000e6;
        uint256 rewardDuration = 200 days;

        vm.prank(msg.sender);
        vault.notifyRewardAmount(StakeVault.TokenType.USDC, reward2);

        vm.warp(block.timestamp + 258 days);

        vm.expectEmit();
        emit NotifyRewardUSDC(reward1);

        vm.prank(msg.sender);
        vault.notifyRewardAmount(StakeVault.TokenType.USDC, reward1);

        uint256 expectedTime = block.timestamp + rewardDuration;

        assertEq(vault.getLastUpdateTimeStamp(), block.timestamp);
        assertEq(vault.getRewardFinishTimeUSDC(), expectedTime);
        assertEq(vault.getProvidedRewardUSDC(), reward1);
    }

    //________________________________________
    // PendingReward
    //________________________________________

    function testPendingRewardReturnsZeroForNonStaker() public depositEth {
        assertEq(vault._pendingReward(user), 0);
    }

    function testPendingRewardReturnsZeroForZeroStak() public depositUsdc stakedUSDC unStaked time {
        vm.prank(user);
        vault.withdraw(StakeVault.TokenType.USDC);

        assertEq(vault._pendingReward(user), 0);
    }

    function testPendingRewardReturnsZeroWhenRateIsZero() public depositEth {
        assertEq(vault._pendingReward(user), 0);
    }

    function testPendingRewardReturnsZeroWhenNoTimeElapsed() public depositUsdc stakedUSDC {
        assertEq(vault._pendingReward(user), 0);
    }

    function testPendingRewardCalculatesCorrectly() public depositEth stakedETH time {
        uint256 stakedValue = vault.getSakedValueInUsd(user);
        uint256 stakedTime = block.timestamp - vault.getStakedTime(user);
        uint256 rewardRate = 5000;
        uint256 basisPoint = 10000;
        uint256 rewardDuration = 200 days;

        uint256 expectedReward = (stakedValue * stakedTime * rewardRate) / (basisPoint * rewardDuration);
        uint256 pendingReward = vault._pendingReward(user);
        assertEq(pendingReward, expectedReward);
    }

    //________________________________________
    // CheckUpKeep
    //________________________________________

    function testCheckUpkeepReturnsTrueWhenInitialValueIsZero() public {
        MockV3Aggregator localMock = new MockV3Aggregator(decimals, initialAnswer);
        StakeVault stakeVault = new StakeVault(address(localMock), usdcAddress);

        localMock.updateAnswer(4000);

        (bool upkeepNeed,) = stakeVault.checkUpkeep("");

        assert(upkeepNeed == true);
    }

    function testCheckUpkeepReturnsTrueWhenPriceIncreasesAboveThreshold() public {
        MockV3Aggregator localMock = new MockV3Aggregator(decimals, initialAnswer);
        StakeVault stakeVault = new StakeVault(address(localMock), usdcAddress);

        localMock.updateAnswer(4500e8);

        (bool upkeepNeed,) = stakeVault.checkUpkeep("");

        assert(upkeepNeed == true);
    }

    function testCheckUpkeepReturnsTrueWhenPriceDecreasesAboveThreshold() public {
        MockV3Aggregator localMock = new MockV3Aggregator(decimals, initialAnswer);
        StakeVault stakeVault = new StakeVault(address(localMock), usdcAddress);

        localMock.updateAnswer(4000);

        localMock.updateAnswer(3900);

        (bool upkeepNeed,) = stakeVault.checkUpkeep("");

        assert(upkeepNeed == true);
    }

    //________________________________________
    // PerformUpkeep
    //________________________________________

    function testPerFormUpkeepRevertIfUpkeepNoNeeded() public {
        vault.checkUpkeep("");

        vm.expectRevert(StakeVault__UpkeepNotMNeded.selector);
        vault.performUpkeep("");
    }

    function testPerFormUpkeepUpdatePriceWhenUpKeepNeeded() public {
        MockV3Aggregator localMock = new MockV3Aggregator(decimals, initialAnswer);
        StakeVault stakeVault = new StakeVault(address(localMock), usdcAddress);

        int256 newPrice = 5000e8;
        localMock.updateAnswer(newPrice);

        stakeVault.checkUpkeep("");

        stakeVault.performUpkeep("");

        uint256 expectedPrice = stakeVault.getLatestPrice() / 1e10;

        assert(expectedPrice == uint256(newPrice));
    }
}
