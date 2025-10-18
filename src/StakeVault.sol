// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";
import {PriceConverter} from "./PriceConverter.sol";

error StakeVault__UnAuthorized();
error StakeVault__ContractIsPaused();
error StakeVault__ContractIsNotPaused();
error StakeVault__DepositFailed();
error StakeVault__TransferFromFailed();
error StakeVault__NotDepositor();
error StakeVault__StakeLimitExceded();
error StakeVault__InsufficientFunds();
error StakeVault__UpkeepNotMNeded();
error StakeVault__ZeroRewardCantBeAdded();
error StakeVault__NotAStaker();
error StakeVault__NoStakeAsset();
error StakeVault__InsufficientRewardPool();
error StakeVault__WithdrawFailed();
error StakeVault__CoolDownPeriodIsActive();
error StakeVault__NotADepositorOrStaker();

/*
 * @title StakeVault
 * @author psalmsprint
 * @notice Simple dual asset staking vault for ETH and USDC
 * @dev Users can deposit, stake, and withdraw with cooldown logic. 
 *      Includes reward tracking and reentrancy protection.
 */

contract StakeVault is ReentrancyGuard {
    using PriceConverter for uint256;

    //____________________
    // STATE VARIABLES
    //____________________

    bool s_pause;

    address private immutable i_owner;
    AggregatorV3Interface private immutable i_priceFeed;
    address private immutable i_usdcAddress;

    // Minimums, maximums, and base reward constants
    uint256 private constant MINIMUM_DEPOSIT_AMOUNT = 10e18;
    uint256 private constant MAX_DEPOSIT_AMOUNT = 100_000e18;
    uint256 private constant MINIMUM_STAKE_AMOUNT = 50e18;
    uint256 private constant MAX_STAKE_AMOUNT = 100_000e18;
    uint256 private constant USDC_MINIMUM_DEPOSIT = 10e6;
    uint256 private constant USDC_MINMUM_STAKE = 50e6;
    uint256 private constant USDC_MAX_STAKE = 100_000e6;
    uint256 private constant USDC_MAX_DEPOSIT = 100_000e6;
    uint256 private constant STAKERS_REWARD_RATE = 5000;
    uint256 private constant DEPOSITOR_REWARD_RATE = 50;
    uint256 private constant REWARD_DURATION = 200 days;
    uint256 private constant BASIS_POINT = 10000;

    // User tracking
    mapping(address => bool) private s_isStaker;
    mapping(address => bool) private s_isDepositor;
    mapping(address => uint256) private s_balance;
    mapping(address => uint256) private s_usdcBalance;
    mapping(address => uint256) private s_rewards;
    mapping(address => uint256) private s_unstakeTime;
    mapping(address => uint256) private s_stakeValueInUsd;
    mapping(address => uint256) private s_userStakeTimeStamp;
    mapping(address => uint256) private s_userDepositTimeStamp;
    mapping(address => TokenType) private s_tokenType;

    // Reward pools and tracking
    uint256 private s_providedRewardETH;
    uint256 private s_providedRewardUSDC;
    uint256 private s_ethDepositorRewardPool;
    uint256 private s_usdcDepositorRewardPool;
    uint256 private s_rewardFinishTimeETH;
    uint256 private s_rewardFinishTimeUSDC;
    uint256 private s_lastUpdateTimeStamp;
    uint256 private s_lastEthPrice;

    //____________________
    // ENUMS
    //____________________

    enum TokenType {
        ETH,
        USDC
    }

    //____________________
    // 	EVENTS
    //____________________

    event Deposited(address indexed sender, uint256 amount);
    event Staked(address indexed sender, uint256 amount);
    event ETHRewardNotify(uint256 reward, uint256 time, uint256 providedReward);
    event USDCRewardNotify(uint256 reward, uint256 time, uint256 providedReward);
    event UnStaked(address indexed sender, uint256 amount);
    event Withdraw(address indexed sender, uint256 amount);
    event RewardProvidedETH(uint256 reward);
    event RewardProvidedUSDC(uint256 reward);
    event NotifyRewardUSDC(uint256 amount);
    event NotifyRewardETH(uint256 amount);

    //______________________
    // CONSTRUCTOR
    //______________________

    constructor(address priceFeed, address usdcAddress) {
        i_owner = msg.sender;
        i_priceFeed = AggregatorV3Interface(priceFeed);
        i_usdcAddress = usdcAddress;
        s_lastEthPrice = PriceConverter.getPrice(i_priceFeed);
    }

    //______________________
    // MODIFIERS
    //______________________

    modifier onlyOwner() {
        if (msg.sender != i_owner) {
            revert StakeVault__UnAuthorized();
        }
        _;
    }

    modifier whenNotPaused() {
        if (s_pause) {
            revert StakeVault__ContractIsPaused();
        }
        _;
    }

    //______________________
    // ADMIN CONTROL
    //______________________

    /// @notice Pause all core operations (deposit, stake, withdraw)
    function pause() public onlyOwner {
        if (s_pause) {
            revert StakeVault__ContractIsPaused();
        }
        s_pause = true;
    }

    /// @notice Resume operations after pause.
    function unPause() public onlyOwner {
        if (!s_pause) {
            revert StakeVault__ContractIsNotPaused();
        }
        s_pause = false;
    }

    //______________________
    // DEPOSIT Functions
    //______________________

    /// @notice Deposit ETH to begin staking or holding
    function depositETH() external payable whenNotPaused nonReentrancy {
        if (
            msg.value.getConversionRate(i_priceFeed) < MINIMUM_DEPOSIT_AMOUNT
                || msg.value.getConversionRate(i_priceFeed) > MAX_DEPOSIT_AMOUNT
        ) {
            revert StakeVault__DepositFailed();
        }

        s_userDepositTimeStamp[msg.sender] = block.timestamp;

        if (!s_isDepositor[msg.sender]) {
            s_isDepositor[msg.sender] = true;
        }
        s_balance[msg.sender] += msg.value;

        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Deposit USDC using ERC20 transferFrom.
    function depositUSDC(uint256 amount) external whenNotPaused nonReentrancy {
        if (amount < USDC_MINIMUM_DEPOSIT || amount > USDC_MAX_DEPOSIT) {
            revert StakeVault__DepositFailed();
        }

        s_userDepositTimeStamp[msg.sender] = block.timestamp;

        if (!s_isDepositor[msg.sender]) {
            s_isDepositor[msg.sender] = true;
        }
        s_usdcBalance[msg.sender] += amount;

        (bool success) = IERC20(i_usdcAddress).transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert StakeVault__TransferFromFailed();
        }

        emit Deposited(msg.sender, amount);
    }

    //______________________
    // STAKE LOGIC
    //______________________

    /// @dev Internal ETH staking logic
    function stakeETH(uint256 amount) internal whenNotPaused {
        uint256 valueInUsd = amount.getConversionRate(i_priceFeed);

        if (!s_isDepositor[msg.sender]) {
            revert StakeVault__NotDepositor();
        }

        if (s_balance[msg.sender] < amount) {
            revert StakeVault__InsufficientFunds();
        }

        if (valueInUsd < MINIMUM_STAKE_AMOUNT || valueInUsd > MAX_STAKE_AMOUNT) {
            revert StakeVault__StakeLimitExceded();
        }

        if (!s_isStaker[msg.sender]) {
            s_isStaker[msg.sender] = true;
            s_userStakeTimeStamp[msg.sender] = block.timestamp;
        }

        s_balance[msg.sender] -= amount;
        s_tokenType[msg.sender] = TokenType.ETH;
        s_stakeValueInUsd[msg.sender] += amount.getConversionRate(i_priceFeed);

        emit Staked(msg.sender, amount);
    }

    /// @dev Internal USDC staking logic
    function stakeUSDC(uint256 amount) internal whenNotPaused {
        if (!s_isDepositor[msg.sender]) {
            revert StakeVault__NotDepositor();
        }

        if (s_usdcBalance[msg.sender] < amount) {
            revert StakeVault__InsufficientFunds();
        }

        if (amount < USDC_MINMUM_STAKE || amount > USDC_MAX_STAKE) {
            revert StakeVault__StakeLimitExceded();
        }

        if (!s_isStaker[msg.sender]) {
            s_isStaker[msg.sender] = true;
            s_userStakeTimeStamp[msg.sender] = block.timestamp;
        }

        s_usdcBalance[msg.sender] -= amount;
        s_tokenType[msg.sender] = TokenType.USDC;
        s_stakeValueInUsd[msg.sender] += amount;

        emit Staked(msg.sender, amount);
    }

    /// @notice Public staking entry point
    function stake(TokenType tokenType, uint256 amount) public whenNotPaused {
        if (tokenType == TokenType.ETH) {
            stakeETH(amount);
        } else if (tokenType == TokenType.USDC) {
            stakeUSDC(amount);
        }
    }

    //______________________
    // UNSTAKE / WITHDRAW
    //______________________

    /// @notice Ends staking and calculates rewards
    function unStake() external whenNotPaused nonReentrancy {
        if (!s_isStaker[msg.sender]) {
            revert StakeVault__NotAStaker();
        }
        uint256 reward = _pendingReward(msg.sender);
        uint256 totalPayOut;

        if (s_tokenType[msg.sender] == TokenType.ETH) {
            if (reward > s_providedRewardETH) {
                revert StakeVault__InsufficientRewardPool();
            }

            s_providedRewardETH = s_providedRewardETH - reward;
            totalPayOut = reward.getConversionRateUsdToEth(i_priceFeed)
                + s_stakeValueInUsd[msg.sender].getConversionRateUsdToEth(i_priceFeed);

            s_rewards[msg.sender] = totalPayOut;
            s_unstakeTime[msg.sender] = block.timestamp + 1 days;
        } else if (s_tokenType[msg.sender] == TokenType.USDC) {
            if (reward > s_providedRewardUSDC) {
                revert StakeVault__InsufficientRewardPool();
            }
            s_providedRewardUSDC = s_providedRewardUSDC - reward;

            totalPayOut = reward + s_stakeValueInUsd[msg.sender];
            s_rewards[msg.sender] = totalPayOut;
            s_unstakeTime[msg.sender] = block.timestamp + 1 days;
        }

        s_stakeValueInUsd[msg.sender] = 0;
        s_userStakeTimeStamp[msg.sender] = 0;
        s_isStaker[msg.sender] = false;

        emit UnStaked(msg.sender, totalPayOut);
    }

    /// @dev Internal withdrawal for stakers (after cooldown)
    function withdrawStaked() internal whenNotPaused {
        uint256 currentTime = block.timestamp;

        if (s_unstakeTime[msg.sender] > currentTime) {
            revert StakeVault__CoolDownPeriodIsActive();
        }

        if (s_tokenType[msg.sender] == TokenType.ETH) {
            s_balance[msg.sender] += s_rewards[msg.sender];
            s_rewards[msg.sender] = 0;
            uint256 amount = s_balance[msg.sender];
            s_balance[msg.sender] = 0;
            s_unstakeTime[msg.sender] = 0;
            s_isDepositor[msg.sender] = false;
            (bool success,) = payable(msg.sender).call{value: amount}("");
            if (success) {
                emit Withdraw(msg.sender, amount);
            } else {
                revert StakeVault__WithdrawFailed();
            }
        } else if (s_tokenType[msg.sender] == TokenType.USDC) {
            s_usdcBalance[msg.sender] += s_rewards[msg.sender];
            s_rewards[msg.sender] = 0;
            uint256 amount = s_usdcBalance[msg.sender];
            s_usdcBalance[msg.sender] = 0;
            s_unstakeTime[msg.sender] = 0;
            s_isDepositor[msg.sender] = false;

            bool success = IERC20(i_usdcAddress).transfer(msg.sender, amount);
            if (success) {
                emit Withdraw(msg.sender, amount);
            } else {
                revert StakeVault__WithdrawFailed();
            }
        }
    }

    /// @dev Internal deposit withdrawal (non-stakers)
    function withdrawDeposit() internal whenNotPaused {
        uint256 currentTime = block.timestamp;
        if (s_balance[msg.sender] > 0) {
            uint256 depositTime = currentTime - s_userDepositTimeStamp[msg.sender];
            uint256 reward =
                (s_balance[msg.sender] * DEPOSITOR_REWARD_RATE * depositTime) / (BASIS_POINT * REWARD_DURATION);

            if (s_ethDepositorRewardPool < reward) {
                revert StakeVault__InsufficientRewardPool();
            }
            s_ethDepositorRewardPool = s_ethDepositorRewardPool - reward;
            reward += s_balance[msg.sender];

            s_balance[msg.sender] = 0;
            s_isDepositor[msg.sender] = false;
            s_userDepositTimeStamp[msg.sender] = 0;

            (bool success,) = payable(msg.sender).call{value: reward}("");
            if (success) {
                emit Withdraw(msg.sender, reward);
            } else {
                revert StakeVault__WithdrawFailed();
            }
        } else if (s_usdcBalance[msg.sender] > 0) {
            uint256 depositTime = currentTime - s_userDepositTimeStamp[msg.sender];
            uint256 reward =
                (s_usdcBalance[msg.sender] * depositTime * DEPOSITOR_REWARD_RATE) / (BASIS_POINT * REWARD_DURATION);

            if (s_usdcDepositorRewardPool < reward) {
                revert StakeVault__InsufficientRewardPool();
            }
            s_usdcDepositorRewardPool = s_usdcDepositorRewardPool - reward;
            reward += s_usdcBalance[msg.sender];

            s_isDepositor[msg.sender] = false;
            s_usdcBalance[msg.sender] = 0;
            s_userDepositTimeStamp[msg.sender] = 0;

            (bool success) = IERC20(i_usdcAddress).transfer(msg.sender, reward);
            if (success) {
                emit Withdraw(msg.sender, reward);
            } else {
                revert StakeVault__WithdrawFailed();
            }
        } else {
            revert StakeVault__InsufficientFunds();
        }
    }

    /// @notice Withdraw user funds depending on status (stake/deposit)
    function withdraw(TokenType tokenType) external whenNotPaused nonReentrancy {
        if (s_tokenType[msg.sender] == tokenType && s_rewards[msg.sender] > 0) {
            withdrawStaked();
        } else if (s_isDepositor[msg.sender]) {
            withdrawDeposit();
        } else {
            revert StakeVault__NotADepositorOrStaker();
        }
    }

    //______________________
    // REWARD HANDLING
    //______________________

    /// @notice Notify vault of new reward funding
    function notifyRewardAmount(TokenType tokenType, uint256 reward) external whenNotPaused onlyOwner {
        uint256 currentTime = block.timestamp;

        if (reward == 0) {
            revert StakeVault__ZeroRewardCantBeAdded();
        }

        if (tokenType == TokenType.ETH && s_providedRewardETH == 0) {
            s_providedRewardETH = reward;
            s_rewardFinishTimeETH = currentTime + REWARD_DURATION;
            s_lastUpdateTimeStamp = currentTime;
            emit NotifyRewardETH(reward);
        } else if (tokenType == TokenType.USDC && s_providedRewardUSDC == 0) {
            s_providedRewardUSDC = reward;
            s_rewardFinishTimeUSDC = currentTime + REWARD_DURATION;
            s_lastUpdateTimeStamp = currentTime;
            emit NotifyRewardUSDC(reward);
        } else if (tokenType == TokenType.ETH && s_rewardFinishTimeETH > currentTime) {
            uint256 remainingTime = s_rewardFinishTimeETH - currentTime;
            uint256 leftOver = (remainingTime * s_providedRewardETH) / REWARD_DURATION;
            s_providedRewardETH = leftOver + reward;
            s_rewardFinishTimeETH = currentTime + REWARD_DURATION;
            s_lastUpdateTimeStamp = currentTime;

            emit ETHRewardNotify(reward, s_rewardFinishTimeETH, s_providedRewardETH);
        } else if (tokenType == TokenType.USDC && s_rewardFinishTimeUSDC > currentTime) {
            uint256 remainingTime = s_rewardFinishTimeUSDC - currentTime;
            uint256 leftOver = (remainingTime * s_providedRewardUSDC) / REWARD_DURATION;
            s_providedRewardUSDC = leftOver + reward;
            s_rewardFinishTimeUSDC = currentTime + REWARD_DURATION;
            s_lastUpdateTimeStamp = currentTime;

            emit USDCRewardNotify(reward, s_rewardFinishTimeUSDC, s_providedRewardUSDC);
        } else if (tokenType == TokenType.ETH && s_rewardFinishTimeETH < currentTime) {
            s_providedRewardETH = reward;
            s_rewardFinishTimeETH = currentTime + REWARD_DURATION;
            s_lastUpdateTimeStamp = currentTime;
            emit NotifyRewardETH(reward);
        } else if (tokenType == TokenType.USDC && s_rewardFinishTimeUSDC < currentTime) {
            s_providedRewardUSDC = reward;
            s_rewardFinishTimeUSDC = currentTime + REWARD_DURATION;
            s_lastUpdateTimeStamp = currentTime;
            emit NotifyRewardUSDC(reward);
        }
    }

    /// @dev Internal reward calculator (view only)
    function _pendingReward(address user) public view returns (uint256) {
        if (!s_isStaker[user]) {
            return 0;
        }

        if (s_stakeValueInUsd[user] == 0) {
            return 0;
        }

        if (STAKERS_REWARD_RATE == 0) {
            return 0;
        }

        uint256 elapsedTime = block.timestamp - s_userStakeTimeStamp[user];

        if (elapsedTime == 0) {
            return 0;
        }

        uint256 expectedReward =
            (s_stakeValueInUsd[user] * STAKERS_REWARD_RATE * elapsedTime) / (BASIS_POINT * REWARD_DURATION);

        return expectedReward;
    }

    //______________________
    // OWNER FUNDING
    //______________________

    /// @notice Adds reward funds for stakers (ETH or USDC)
    /// @dev Only callable by the owner
    function _addReward(TokenType tokenType, uint256 amount) internal onlyOwner {
        if (tokenType == TokenType.ETH) {
            s_providedRewardETH += amount;
            emit RewardProvidedETH(amount);
        } else if (tokenType == TokenType.USDC) {
            s_providedRewardUSDC += amount;
            emit RewardProvidedUSDC(amount);
        }
    }

    /// @notice Adds reward funds for depositors (ETH or USDC)
    function _addDepositorReward(TokenType tokenType, uint256 amount) internal onlyOwner {
        if (tokenType == TokenType.ETH) {
            s_ethDepositorRewardPool += amount;
            emit RewardProvidedETH(amount);
        } else if (tokenType == TokenType.USDC) {
            s_usdcDepositorRewardPool += amount;
            emit RewardProvidedUSDC(amount);
        }
    }

    /// @notice External function to fund staking reward pool
    function fundProvidedReward(TokenType tokenType, uint256 amount) external onlyOwner {
        _addReward(tokenType, amount);
    }

    /// @notice External function to fund depositor reward pool
    function fundDepositorsProvidedPool(TokenType tokenType, uint256 amount) external onlyOwner {
        _addDepositorReward(tokenType, amount);
    }

    //______________________
    // CHAINLINK UPKEEP
    //______________________

    /// @notice Checks if upkeep is needed based on ETH price change
    /// @return upkeepNeeded True if price deviation exceeds threshold
    function checkUpkeep(bytes memory /* checkData */ )
        public
        view
        returns (bool upkeepNeeded, bytes memory /* performData */ )
    {
        uint256 rate = 200;
        uint256 initialValue = s_lastEthPrice;
        uint256 currentValue = PriceConverter.getPrice(i_priceFeed);

        bool updatePrice;

        if (initialValue == 0) {
            updatePrice = true;
        } else if (currentValue > initialValue) {
            uint256 increaseValue = ((currentValue - initialValue) * BASIS_POINT) / initialValue;
            if (increaseValue >= rate) {
                updatePrice = true;
            }
        } else if (currentValue < initialValue) {
            uint256 decreaseValue = ((initialValue - currentValue) * BASIS_POINT) / initialValue;
            if (decreaseValue >= rate) {
                updatePrice = true;
            }
        }

        upkeepNeeded = updatePrice;

        return (upkeepNeeded, "");
    }

    /// @notice Updates stored ETH price when upkeep is needed
    /// @dev Reverts if upkeep condition is not met
    function performUpkeep(bytes memory /* performData */ ) external {
        (bool upkeepNeeded,) = checkUpkeep("");
        if (!upkeepNeeded) {
            revert StakeVault__UpkeepNotMNeded();
        }

        s_lastEthPrice = PriceConverter.getPrice(i_priceFeed);
    }

    //____________________
    // Getter Functions
    //____________________

    function getDepositor(address depositor) external view returns (bool) {
        return s_isDepositor[depositor];
    }

    function getStakerRewardRate() external pure returns (uint256) {
        return STAKERS_REWARD_RATE;
    }

    function getETHBalanceOfUser(address user) external view returns (uint256) {
        return s_balance[user];
    }

    function getUSDCBalanceOfDepositor(address user) external view returns (uint256) {
        return s_usdcBalance[user];
    }

    function getDepositorTimeStamp(address user) external view returns (uint256) {
        return s_userDepositTimeStamp[user];
    }

    function getContractState() external view returns (bool) {
        return s_pause;
    }

    function getSakedValueInUsd(address user) external view returns (uint256) {
        return s_stakeValueInUsd[user];
    }

    function getStakedTime(address user) external view returns (uint256) {
        return s_userStakeTimeStamp[user];
    }

    function getStakers(address user) external view returns (bool) {
        return s_isStaker[user];
    }

    function getStakedTokenType(address user) external view returns (TokenType) {
        return s_tokenType[user];
    }

    function getUnStakedTime(address user) external view returns (uint256) {
        return s_unstakeTime[user];
    }

    function getprovidedRewardETH() external view returns (uint256) {
        return s_providedRewardETH;
    }

    function getProvidedRewardUSDC() external view returns (uint256) {
        return s_providedRewardUSDC;
    }

    function getStakerReward(address user) external view returns (uint256) {
        return s_rewards[user];
    }

    function getRewardFinishTimeETH() external view returns (uint256) {
        return s_rewardFinishTimeETH;
    }

    function getRewardFinishTimeUSDC() external view returns (uint256) {
        return s_rewardFinishTimeUSDC;
    }

    function getLastUpdateTimeStamp() external view returns (uint256) {
        return s_lastUpdateTimeStamp;
    }

    function getLatestPrice() external view returns (uint256) {
        return s_lastEthPrice;
    }
}
