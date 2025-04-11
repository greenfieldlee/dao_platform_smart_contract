// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract BLRStaking is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct PoolInfo {
        uint32 lockupDuration; // max 1095 days (94,608,000 seconds) fits in uint32
        uint16 returnPer; // APY max 222 (22.2%) fits in uint16
        uint16 multiplier; // max 50 (5x) fits in uint16
    }

    struct OrderInfo {
        address beneficiary;
        uint128 amount; // reasonable token amount fits in uint128
        uint32 lockupDuration; // max 1095 days fits in uint32
        uint16 returnPer; // APY max 222 (22.2%) fits in uint16
        uint16 multiplier; // max 50 (5x) fits in uint16
        uint32 starttime; // timestamp fits in uint32 until year 2106
        uint32 endtime; // timestamp fits in uint32 until year 2106
        uint128 claimedReward; // reasonable reward amount fits in uint128
        bool claimed;
        bool locked;
    }

    struct PoolConfig {
        uint256 duration;
        uint256 apy;
        uint256 multiplier;
        bool isActive;
    }

    // Internal constants - migrated from external configuration
    uint256 private constant POOL_1_DURATION = 30 days;
    uint256 private constant POOL_2_DURATION = 180 days;
    uint256 private constant POOL_3_DURATION = 365 days;
    uint256 private constant POOL_4_DURATION = 730 days;
    uint256 private constant POOL_5_DURATION = 1095 days;

    uint256 private constant PENALTY_RATE = 5; // 5% penalty for early withdrawal in Pool 2 (6 months)
    uint256 private constant PRECISION = 1000; // For multiplying APY and multiplier with decimals
    uint256 private constant MINIMUM_RESERVE_RATIO = 105; // 105% - Contract must maintain 5% more than total staked + pending rewards
    uint256 private constant CLAIM_DELAY = 7 days; // Weekly claims to match pool durations (minimum pool is 30 days)
    uint256 private constant MAX_REWARD_PER_CLAIM = 1000 * 1e18; // Maximum reward based on highest APY pool (22.22% for 3 years)

    // Contract state
    IERC20 public immutable blrToken; // Made immutable as it's set once in constructor
    bool private started = true;
    uint256 private latestOrderId = 0;
    uint256 public totalStakers;
    uint256 public totalStaked;
    uint256 public currentStaked;

    // Internal mappings
    mapping(uint256 => PoolInfo) public pooldata;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public totalRewardEarn;
    mapping(uint256 => OrderInfo) public orders;
    mapping(address => uint256[]) private orderIds;
    mapping(address => mapping(uint256 => bool)) public hasStaked;
    mapping(uint256 => uint256) public stakeOnPool;
    mapping(uint256 => uint256) public rewardOnPool;
    mapping(uint256 => uint256) public stakersPlan;
    mapping(address => uint256) private lastClaimTime;
    mapping(address => bool) public hasStakedInAnyPool;
    mapping(uint256 => PoolConfig) public poolConfigs;

    // Events
    event Deposit(
        address indexed user,
        uint256 indexed lockupDuration,
        uint256 amount,
        uint256 returnPer,
        bool locked
    );
    event Withdraw(
        address indexed user,
        uint256 amount,
        uint256 reward,
        uint256 total
    );
    event RewardClaimed(address indexed user, uint256 reward);
    event StakingToggled(bool newState, address indexed operator);
    event ExtraTokensWithdrawn(
        address indexed token,
        uint256 amount,
        address indexed operator
    );
    event EmergencyWithdrawal(address indexed user, uint256 amount, uint256 penalty);

    modifier sufficientReserves() {
        require(checkReserves(), "Insufficient contract reserves");
        _;
    }

    constructor(address _BLRAddress) Ownable(msg.sender) {
        require(_BLRAddress != address(0), "Invalid BLR token address");
        blrToken = IERC20(_BLRAddress);
        
        // Initialize pools with fixed configurations
        pooldata[1] = PoolInfo(uint32(POOL_1_DURATION), 35, 15); // 3.5% APY, 1.5x multiplier
        pooldata[2] = PoolInfo(uint32(POOL_2_DURATION), 80, 20); // 8% APY, 2x multiplier (6 months pool with penalty)
        pooldata[3] = PoolInfo(uint32(POOL_3_DURATION), 125, 30); // 12.5% APY, 3x multiplier
        pooldata[4] = PoolInfo(uint32(POOL_4_DURATION), 170, 40); // 17% APY, 4x multiplier
        pooldata[5] = PoolInfo(uint32(POOL_5_DURATION), 222, 50); // 22.22% APY, 5x multiplier

        poolConfigs[1] = PoolConfig({duration: POOL_1_DURATION, apy: 35, multiplier: 15, isActive: true});
        poolConfigs[2] = PoolConfig({duration: POOL_2_DURATION, apy: 80, multiplier: 20, isActive: true});
        poolConfigs[3] = PoolConfig({duration: POOL_3_DURATION, apy: 125, multiplier: 30, isActive: true});
        poolConfigs[4] = PoolConfig({duration: POOL_4_DURATION, apy: 170, multiplier: 40, isActive: true});
        poolConfigs[5] = PoolConfig({duration: POOL_5_DURATION, apy: 222, multiplier: 50, isActive: true});
    }

    function stake(
        uint256 amount,
        uint256 lockupDuration,
        bool isLocked
    ) external nonReentrant sufficientReserves {
        PoolInfo storage pool = pooldata[lockupDuration];
        require(
            pool.lockupDuration > 0,
            "BLRStaking: asked pool does not exist"
        );
        require(started, "BLRStaking: staking not yet started");
        require(amount > 0, "BLRStaking: stake amount must be non-zero");

        // Get balance before transfer
        uint256 balanceBefore = blrToken.balanceOf(address(this));
        
        // Attempt transfer
        require(
            blrToken.transferFrom(msg.sender, address(this), amount),
            "BLRStaking: BLR transferFrom failed"
        );

        // Calculate actual amount received
        uint256 balanceAfter = blrToken.balanceOf(address(this));
        uint256 actualAmount = balanceAfter - balanceBefore;
        require(actualAmount > 0, "BLRStaking: No tokens received");

        uint256 multiplier = isLocked ? pool.multiplier : PRECISION;

        orders[++latestOrderId] = OrderInfo(
            msg.sender,
            uint128(actualAmount),
            uint32(lockupDuration),
            uint16(pool.returnPer),
            uint16(multiplier),
            uint32(block.timestamp),
            uint32(block.timestamp + lockupDuration),
            uint128(0),
            false,
            isLocked
        );

        if (!hasStaked[msg.sender][lockupDuration]) {
            stakersPlan[lockupDuration] += 1;
            // Only increment totalStakers if this is the first time staking in any pool
            if (!hasStakedInAnyPool[msg.sender]) {
                totalStakers += 1;
                hasStakedInAnyPool[msg.sender] = true;
            }
        }

        hasStaked[msg.sender][lockupDuration] = true;
        stakeOnPool[lockupDuration] += actualAmount;
        totalStaked += actualAmount;
        currentStaked += actualAmount;
        balanceOf[msg.sender] += actualAmount;
        orderIds[msg.sender].push(latestOrderId);

        emit Deposit(
            msg.sender,
            lockupDuration,
            actualAmount,
            pool.returnPer,
            isLocked
        );
    }

    function claim(uint256 orderId) public nonReentrant {
        require(orderId <= latestOrderId, "BLRStaking: INVALID orderId");
        require(
            block.timestamp >= lastClaimTime[msg.sender] + CLAIM_DELAY,
            "BLRStaking: Too frequent claims"
        );

        OrderInfo storage order = orders[orderId];
        require(order.beneficiary == msg.sender, "BLRStaking: Not your order");
        require(!order.claimed, "BLRStaking: Already claimed");

        if (order.locked) {
            require(
                block.timestamp >= order.endtime,
                "BLRStaking: Locked staking cannot claim before the lockup period ends"
            );
        }

        uint256 pendingReward = pendingRewards(orderId);
        require(pendingReward > 0, "BLRStaking: No pending rewards");

        // Calculate the claimable amount (minimum of pending reward and max reward per claim)
        uint256 claimableAmount = pendingReward > MAX_REWARD_PER_CLAIM 
            ? MAX_REWARD_PER_CLAIM 
            : pendingReward;

        // Calculate required reserve amount (105% of total staked + claimable rewards)
        uint256 requiredReserve = ((currentStaked + claimableAmount) *
            MINIMUM_RESERVE_RATIO) / 100;

        // Check if contract has sufficient reserves
        require(
            blrToken.balanceOf(address(this)) >= requiredReserve,
            "BLRStaking: Insufficient contract reserves"
        );

        // Update claimed reward amount
        order.claimedReward += uint128(claimableAmount);
        totalRewardEarn[msg.sender] += claimableAmount;
        lastClaimTime[msg.sender] = block.timestamp;

        // Use SafeERC20 for safer token transfer
        blrToken.safeTransfer(order.beneficiary, claimableAmount);

        emit RewardClaimed(msg.sender, claimableAmount);
    }

    function unstake(uint256 orderId) external nonReentrant {
        require(orderId <= latestOrderId, "BLRStaking: INVALID orderId");

        OrderInfo storage order = orders[orderId];
        require(order.beneficiary == msg.sender, "BLRStaking: Not your order");

        uint256 reward = pendingRewards(orderId);
        uint256 penalty = 0;

        if (order.locked && block.timestamp < order.endtime) {
            penalty = (reward * PENALTY_RATE) / 100; // Apply penalty percentage (e.g., 5%)
            reward -= penalty; // Deduct penalty from the reward
        }

        uint256 totalUnstake = uint256(order.amount) + reward;
        order.claimed = true;

        // Update staking balance and transfer tokens
        currentStaked -= uint256(order.amount);
        balanceOf[msg.sender] -= uint256(order.amount);

        // Use SafeERC20 for safer token transfer
        blrToken.safeTransfer(msg.sender, totalUnstake);

        emit Withdraw(msg.sender, uint256(order.amount), reward, totalUnstake);
    }

    function pendingRewards(uint256 orderId) public view returns (uint256) {
        require(orderId <= latestOrderId, "BLRStaking: INVALID orderId");

        OrderInfo storage orderInfo = orders[orderId];
        if (!orderInfo.claimed) {
            // Calculate the actual time elapsed since staking started
            uint256 timeElapsed = block.timestamp > orderInfo.endtime
                ? orderInfo.endtime - orderInfo.starttime
                : block.timestamp - orderInfo.starttime;

            // Calculate base reward with multiplications first
            uint256 numerator = orderInfo.amount * orderInfo.returnPer * timeElapsed;
            uint256 denominator = PRECISION * 365 days;
            uint256 baseReward = numerator / denominator;

            // Apply multiplier to base reward for locked staking
            uint256 totalReward = orderInfo.locked
                ? baseReward + ((baseReward * (orderInfo.multiplier - PRECISION)) / PRECISION)
                : baseReward;

            // Calculate available reward after deducting claimed amount
            uint256 claimAvailable = totalReward > orderInfo.claimedReward
                ? totalReward - orderInfo.claimedReward
                : 0;

            return claimAvailable;
        } else {
            return 0;
        }
    }

    function toggleStaking(bool start) external onlyOwner returns (bool) {
        started = start;
        emit StakingToggled(start, msg.sender);
        return true;
    }

    function investorOrderIds(
        address investor
    ) external view returns (uint256[] memory ids) {
        uint256[] memory arr = orderIds[investor];
        return arr;
    }

    function withdrawExtraTokens(address token) external onlyOwner {
        IERC20 withdrawToken = IERC20(token);
        uint256 balance = withdrawToken.balanceOf(address(this));
        uint256 withdrawAmount = balance - currentStaked;
        require(
            withdrawToken.transfer(msg.sender, withdrawAmount),
            "withdraw_token transfer failed"
        );
        emit ExtraTokensWithdrawn(token, withdrawAmount, msg.sender);
    }

    function calculateTotalPendingRewards() internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 1; i <= latestOrderId; i++) {
            if (!orders[i].claimed) {
                total += pendingRewards(i);
            }
        }
        return total;
    }

    function checkReserves() internal view returns (bool) {
        uint256 requiredReserve = ((currentStaked + calculateTotalPendingRewards()) * MINIMUM_RESERVE_RATIO) / 100;
        return blrToken.balanceOf(address(this)) >= requiredReserve;
    }

    function emergencyWithdraw(uint256 orderId) external nonReentrant {
        require(!checkReserves(), "Reserves sufficient - use normal withdrawal");
        require(orderId <= latestOrderId, "BLRStaking: INVALID orderId");

        OrderInfo storage order = orders[orderId];
        require(order.beneficiary == msg.sender, "BLRStaking: Not your order");
        require(!order.claimed, "BLRStaking: Already claimed");

        uint256 amount = uint256(order.amount);
        // Higher penalty in emergency (10% vs normal 5%)
        uint256 penalty = (amount * (PENALTY_RATE * 2)) / 100;
        uint256 withdrawAmount = amount - penalty;

        // Check if contract has enough tokens for withdrawal
        require(
            blrToken.balanceOf(address(this)) >= withdrawAmount,
            "BLRStaking: Insufficient contract balance"
        );

        // Update state
        order.claimed = true;
        currentStaked -= amount;
        balanceOf[msg.sender] -= amount;

        // Transfer tokens with penalty
        blrToken.safeTransfer(msg.sender, withdrawAmount);
        if (penalty > 0) {
            blrToken.safeTransfer(owner(), penalty);
        }

        emit EmergencyWithdrawal(msg.sender, withdrawAmount, penalty);
    }
}
