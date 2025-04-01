// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);

    function transfer(address recipient, uint256 amount)
        external
        returns (bool);

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);
}

abstract contract Context {
    function _msgSender() internal view returns (address) {
        return msg.sender;
    }
}

abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    constructor() {
        _transferOwnership(_msgSender());
    }

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function _checkOwner() private view {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
    }

    function renounceOwnership() external onlyOwner {
        _transferOwnership(address(0));
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
        _transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) private {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        _status = _ENTERED;
    }

    function _nonReentrantAfter() private {
        _status = _NOT_ENTERED;
    }

    function _reentrancyGuardEntered() private view returns (bool) {
        return _status == _ENTERED;
    }
}

pragma solidity ^0.8.0;

contract BLRStaking is Ownable, ReentrancyGuard {
    struct PoolInfo {
        uint256 lockupDuration;
        uint256 returnPer; // APY in multiplied form (e.g., 35 for 3.5%)
        uint256 multiplier; // Multiplier in multiplied form (e.g., 15 for 1.5x)
    }

    struct OrderInfo {
        address beneficiary;
        uint256 amount;
        uint256 lockupDuration;
        uint256 returnPer;
        uint256 multiplier; // Applies multiplier for locked staking
        uint256 starttime;
        uint256 endtime;
        uint256 claimedReward;
        bool claimed;
        bool locked; // Determines if the stake is locked or unlocked
    }

    uint256 private constant _1Pool = 30 days;
    uint256 private constant _2Pool = 180 days; // 6 months
    uint256 private constant _3Pool = 365 days;
    uint256 private constant _4Pool = 730 days;
    uint256 private constant _5Pool = 1095 days;

    uint256 private constant PENALTY_RATE = 5; // 5% penalty for early withdrawal in Pool 2 (6 months)

    uint256 private constant PRECISION = 1000; // For multiplying APY and multiplier with decimals

    IERC20 public BLR;

    bool private started = true;
    uint256 private latestOrderId = 0;
    uint256 public totalStakers;
    uint256 public totalStaked;
    uint256 public currentStaked;

    mapping(uint256 => PoolInfo) public pooldata;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public totalRewardEarn;
    mapping(uint256 => OrderInfo) public orders;
    mapping(address => uint256[]) private orderIds;
    mapping(address => mapping(uint256 => bool)) public hasStaked;
    mapping(uint256 => uint256) public stakeOnPool;
    mapping(uint256 => uint256) public rewardOnPool;
    mapping(uint256 => uint256) public stakersPlan;

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

    constructor(address _BLRAddress) {
        BLR = IERC20(_BLRAddress);
        pooldata[1] = PoolInfo(_1Pool, 35, 15);   // 3.5% APY, 1.5x multiplier
        pooldata[2] = PoolInfo(_2Pool, 80, 20);   // 8% APY, 2x multiplier (6 months pool with penalty)
        pooldata[3] = PoolInfo(_3Pool, 125, 30);  // 12.5% APY, 3x multiplier
        pooldata[4] = PoolInfo(_4Pool, 170, 40);  // 17% APY, 4x multiplier
        pooldata[5] = PoolInfo(_5Pool, 222, 50); // 22.22% APY, 5x multiplier
    }

 function stake(uint256 _amount, uint256 _lockupDuration, bool _locked) external nonReentrant {
    PoolInfo storage pool = pooldata[_lockupDuration];
    require(pool.lockupDuration > 0, "BLRStaking: asked pool does not exist");
    require(started, "BLRStaking: staking not yet started");
    require(_amount > 0, "BLRStaking: stake amount must be non-zero");
    require(BLR.transferFrom(msg.sender, address(this), _amount), "BLRStaking: BLR transferFrom failed");

    uint256 multiplier = _locked ? pool.multiplier : PRECISION; 

    orders[++latestOrderId] = OrderInfo(
        msg.sender,
        _amount,
        pool.lockupDuration,
        pool.returnPer,
        multiplier,
        block.timestamp,
        block.timestamp + pool.lockupDuration,
        0,
        false,
        _locked
    );

    if (!hasStaked[msg.sender][_lockupDuration]) {
        stakersPlan[_lockupDuration] += 1;
        totalStakers += 1;
    }

    hasStaked[msg.sender][_lockupDuration] = true;
    stakeOnPool[_lockupDuration] += _amount;
    totalStaked += _amount;
    currentStaked += _amount;
    balanceOf[msg.sender] += _amount;
    orderIds[msg.sender].push(latestOrderId);

    emit Deposit(msg.sender, pool.lockupDuration, _amount, pool.returnPer, _locked);
}


    function claim(uint256 orderId) public nonReentrant {
        require(orderId <= latestOrderId, "BLRStaking: INVALID orderId");

        OrderInfo storage order = orders[orderId];
        require(order.beneficiary == msg.sender, "BLRStaking: Not your order");
        require(!order.claimed, "BLRStaking: Already claimed");
        if (order.locked) {
        require(block.timestamp >= order.endtime, "BLRStaking: Locked staking cannot claim before the lockup period ends");
         }

        uint256 pendingReward = pendingRewards(orderId);
        require(pendingReward > 0, "BLRStaking: No pending rewards");

        totalRewardEarn[msg.sender] += pendingReward;
        order.claimedReward += pendingReward;
        
        // Transfer rewards
        BLR.transfer(order.beneficiary, pendingReward);

        emit RewardClaimed(msg.sender, pendingReward);
    }

   function unstake(uint256 orderId) external nonReentrant {
    require(orderId <= latestOrderId, "BLRStaking: INVALID orderId");

    OrderInfo storage order = orders[orderId];
    require(order.beneficiary == msg.sender, "BLRStaking: Not your order");

    uint256 reward = pendingRewards(orderId);
    uint256 penalty = 0;

    if (order.locked && block.timestamp < order.endtime) {
        penalty = (reward * PENALTY_RATE) / 100; // Apply penalty percentage (e.g., 5%)
        reward -= penalty;  // Deduct penalty from the reward
    }

    uint256 totalUnstake = order.amount + reward;
    order.claimed = true;

    // Update staking balance and transfer tokens
    currentStaked -= order.amount;
    balanceOf[msg.sender] -= order.amount;

    // Transfer staked amount + rewards (minus penalty)
    BLR.transfer(msg.sender, totalUnstake);

    emit Withdraw(msg.sender, order.amount, reward, totalUnstake);
}

function pendingRewards(uint256 orderId) public view returns (uint256) {
    require(orderId <= latestOrderId, "BLRStaking: INVALID orderId");

    OrderInfo storage orderInfo = orders[orderId];
    if (!orderInfo.claimed) {
        uint256 APY = (orderInfo.amount * orderInfo.returnPer) / PRECISION;

        // Calculate the actual time elapsed since staking started
        uint256 timeElapsed = block.timestamp > orderInfo.endtime
            ? orderInfo.endtime - orderInfo.starttime
            : block.timestamp - orderInfo.starttime;

        // Proportionally calculate rewards based on the time elapsed
        uint256 reward = (APY * timeElapsed) / 365 days;

        // Apply the multiplier for locked staking
        if (orderInfo.locked) {
            reward = (reward * orderInfo.multiplier) / PRECISION;
        }

        uint256 claimAvailable = reward > orderInfo.claimedReward
            ? reward - orderInfo.claimedReward
            : 0;

        return claimAvailable;
    } else {
        return 0;
    }
}


    function toggleStaking(bool _start) external onlyOwner returns (bool) {
        started = _start;
        return true;
    }

    function investorOrderIds(address investor)
        external
        view
        returns (uint256[] memory ids)
    {
        uint256[] memory arr = orderIds[investor];
        return arr;
    }

    function withdrawExtraTokens(address _token) external onlyOwner {
    IERC20 withdrawToken = IERC20(_token);
    uint256 balance = withdrawToken.balanceOf(address(this));

    if (_token == address(BLR)) {
        require(
            balance > currentStaked,
            "No extra BLR tokens to withdraw"
        );
        uint256 withdrawAmount = balance - currentStaked;
        require(
            withdrawToken.transfer(msg.sender, withdrawAmount),
            "Withdraw token transfer failed"
        );
    } else {
        require(
            withdrawToken.transfer(msg.sender, balance),
            "Withdraw token transfer failed"
        );
    }
}

}
