// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IERC20 {
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    function transfer(address recipient, uint256 amount)
        external
        returns (bool);

    function balanceOf(address account) external view returns (uint256);

    function decimals() external view returns (uint8);
}

contract InvestmentPool is ReentrancyGuard, Ownable {
    struct Investor {
        uint256 depositedAmount;
        address stablecoin; // Tracks the stablecoin used by the investor
        uint256 share; // Tracks the share of the pool
        bool hasWithdrawn;
    }

    uint256 public immutable maxCapacity;
    uint256 public totalDeposits;
    uint256 public immutable poolLifespan; // Lifespan in seconds (e.g., 3, 6, 12 months)
    uint256 public immutable poolEndTime; // When the pool matures
    uint256 public immutable earlyWithdrawalPenaltyPercent; // Penalty percentage for early withdrawal
    bool public poolActive;
    bool public poolClosed; // Whether the pool has been closed for new investments

    mapping(address => bool) public approvedStablecoins; // Approved stablecoins
    mapping(address => Investor) public investors;
    address[] public investorList;

    event Deposit(
        address indexed investor,
        address stablecoin,
        uint256 amount,
        uint256 shares
    );
    event EarlyWithdrawal(
        address indexed investor,
        uint256 penalty,
        uint256 payout
    );
    event WithdrawalAfterMaturity(address indexed investor, uint256 payout);
    event PoolClosed();
    event ProfitAdded(uint256 profitAmount);

    modifier poolIsActive() {
        require(poolActive, "Pool is not active");
        _;
    }

    constructor(
        uint256 _maxCapacity,
        uint256 _poolLifespan,
        uint256 _earlyWithdrawalPenaltyPercent
    ) Ownable(msg.sender) {
        maxCapacity = _maxCapacity;
        poolLifespan = _poolLifespan;
        earlyWithdrawalPenaltyPercent = _earlyWithdrawalPenaltyPercent;
        poolActive = true;
        poolEndTime = block.timestamp + poolLifespan;
    }

    function modifyApprovedStablecoin(address _stablecoin, bool _status)
        external
        onlyOwner
    {
        approvedStablecoins[_stablecoin] = _status;
    }

    function deposit(address _stablecoin, uint256 _amount)
        external
        poolIsActive
        nonReentrant
    {
        require(approvedStablecoins[_stablecoin], "Stablecoin not approved");
        require(
            totalDeposits + _amount <= maxCapacity,
            "Exceeds pool capacity"
        );
        require(investors[msg.sender].depositedAmount == 0, "Already invested");

        IERC20(_stablecoin).transferFrom(msg.sender, address(this), _amount);

        uint256 shares = calculateShares(_amount, _stablecoin);
        investors[msg.sender] = Investor(_amount, _stablecoin, shares, false);
        investorList.push(msg.sender);

        totalDeposits += _amount;

        emit Deposit(msg.sender, _stablecoin, _amount, shares);

        // Close pool if max capacity is reached
        if (totalDeposits == maxCapacity) {
            poolClosed = true;
            poolActive = false;
            emit PoolClosed();
        }
    }

    function getDecimals(address token) internal view returns (uint8) {
        return IERC20(token).decimals(); // Retrieve the decimals from the token
    }

    function normalizeAmount(address token, uint256 amount)
        internal
        view
        returns (uint256)
    {
        uint8 tokenDecimals = getDecimals(token);
        uint8 standardDecimals = 18; // Standardizing to 18 decimals (adjustable based on your needs)

        if (tokenDecimals < standardDecimals) {
            // If token has less than 18 decimals, scale up
            return amount * (10**(standardDecimals - tokenDecimals));
        } else if (tokenDecimals > standardDecimals) {
            // If token has more decimals, scale down
            return amount / (10**(tokenDecimals - standardDecimals));
        }
        return amount; // No scaling needed if it's already standardized
    }

    function calculateShares(uint256 amount, address tokenAddress)
        internal
        view
        returns (uint256)
    {
        uint256 normalizedAmount = normalizeAmount(tokenAddress, amount);
        return (normalizedAmount * 1e18) / maxCapacity;
    }

    // uint256 profitShare = (profitAmount * investor.share) / 1e18;  // Normalized profit calculation

    function earlyWithdraw() external poolIsActive nonReentrant {
        Investor storage investor = investors[msg.sender];
        require(investor.depositedAmount > 0, "No deposit found");
        require(!investor.hasWithdrawn, "Already withdrawn");

        uint256 penalty = (investor.depositedAmount *
            earlyWithdrawalPenaltyPercent) / 100;
        uint256 payout = investor.depositedAmount - penalty;

        IERC20(investor.stablecoin).transfer(msg.sender, payout);

        investor.share = 0; // "Burn" the shares
        investor.hasWithdrawn = true;
        totalDeposits -= investor.depositedAmount; // Reduce total pool deposits

        emit EarlyWithdrawal(msg.sender, penalty, payout);
    }

    // Withdraw funds after pool maturity
    function withdrawAfterMaturity() external nonReentrant {
        require(block.timestamp >= poolEndTime, "Pool has not matured yet");
        Investor storage investor = investors[msg.sender];
        require(investor.depositedAmount > 0, "No deposit found");
        require(!investor.hasWithdrawn, "Already withdrawn");

        uint256 payout = investor.depositedAmount;
        IERC20(investor.stablecoin).transfer(msg.sender, payout);

        investor.share = 0;
        investor.hasWithdrawn = true;

        emit WithdrawalAfterMaturity(msg.sender, payout);
    }

    // Admin function to close the pool for new investments
    function closePool() external onlyOwner {
        require(poolActive, "Pool is already closed");
        poolActive = false;
        emit PoolClosed();
    }

    // Admin function to add profit to the pool after maturity
    function addProfit(uint256 profitAmount) external onlyOwner nonReentrant {
        require(block.timestamp >= poolEndTime, "Pool has not matured yet");
        require(poolClosed, "Pool must be closed before adding profit");

        for (uint256 i = 0; i < investorList.length; i++) {
            address investorAddress = investorList[i];
            Investor storage investor = investors[investorAddress];
            uint256 profitShare = (profitAmount * investor.share) / 1e18;
            IERC20(investor.stablecoin).transfer(investorAddress, profitShare);
        }

        emit ProfitAdded(profitAmount);
    }

    // Helper function to check if pool is fully subscribed
    function isPoolFullySubscribed() external view returns (bool) {
        return totalDeposits == maxCapacity;
    }
}
