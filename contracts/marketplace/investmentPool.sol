// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract InvestmentPool is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // Structs
    struct Investor {
        uint256 depositedAmount; // Amount deposited by the investor
        address stablecoin;      // Address of the stablecoin used for deposit
        uint256 share;          // Share of the pool owned by the investor
        bool hasWithdrawn;      // Whether the investor has withdrawn their funds
        bool isLocked;          // Mutex for preventing reentrancy
    }

    // Constants
    uint8 private constant STANDARD_DECIMALS = 18; // Standard number of decimals for token calculations

    // State variables
    uint256 public immutable maxCapacity;                 // Maximum capacity of the pool
    uint256 public immutable poolLifespan;                // Lifespan in seconds (e.g., 3, 6, 12 months)
    uint256 public immutable poolEndTime;                 // When the pool matures
    uint256 public immutable earlyWithdrawalPenaltyPercent; // Penalty percentage for early withdrawal
    address public immutable marketplace;                 // Address of the authorized Marketplace contract
    uint256 public totalDeposits;                        // Total amount deposited in the pool
    bool public poolActive;                              // Whether the pool is active for deposits
    bool public poolClosed;                              // Whether the pool has been closed for new investments

    // Mappings
    mapping(address => bool) public approvedStablecoins; // Approved stablecoins for this pool
    mapping(address => Investor) public investors;       // Investor information mapping
    address[] public investorList;                       // List of all investors in the pool

    // Events
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
    event StablecoinStatusChanged(address indexed stablecoin, bool status);

    // Modifiers
    modifier notContract(address account) {
        require(account.code.length == 0, "Contract addresses not allowed");
        _;
    }

    modifier lockInvestor(address account) {
        require(!investors[account].isLocked, "Operation in progress");
        investors[account].isLocked = true;
        _;
        investors[account].isLocked = false;
    }

    modifier poolIsActive() {
        require(poolActive, "Pool is not active");
        _;
    }

    modifier onlyMarketplace() {
        require(msg.sender == marketplace, "Only Marketplace can call this function");
        _;
    }

    constructor(
        uint256 maxCapacityAmount,
        uint256 poolLifespanDuration,
        uint256 earlyWithdrawalPenalty,
        address marketplaceAddress
    ) Ownable(msg.sender) {
        require(maxCapacityAmount > 0, "Max capacity must be greater than 0");
        require(poolLifespanDuration > 0, "Pool lifespan must be greater than 0");
        require(earlyWithdrawalPenalty <= 100, "Penalty percentage cannot exceed 100%");
        require(marketplaceAddress != address(0), "Invalid marketplace address");

        maxCapacity = maxCapacityAmount;
        poolLifespan = poolLifespanDuration;
        earlyWithdrawalPenaltyPercent = earlyWithdrawalPenalty;
        marketplace = marketplaceAddress;
        poolActive = true;
        poolEndTime = block.timestamp + poolLifespanDuration;
    }

    function modifyApprovedStablecoin(address stablecoin, bool status)
        external
        onlyOwner
    {
        approvedStablecoins[stablecoin] = status;
        emit StablecoinStatusChanged(stablecoin, status);
    }

    function deposit(address stablecoin, uint256 amount)
        external
        poolIsActive
        nonReentrant
        notContract(msg.sender)
    {
        require(approvedStablecoins[stablecoin], "Stablecoin not approved");
        require(
            totalDeposits + amount <= maxCapacity,
            "Exceeds pool capacity"
        );
        require(investors[msg.sender].depositedAmount == 0, "Already invested");

        // Get balance before transfer
        uint256 balanceBefore = IERC20(stablecoin).balanceOf(address(this));
        
        // Attempt transfer
        require(
            IERC20(stablecoin).transferFrom(msg.sender, address(this), amount),
            "Transfer failed"
        );

        // Calculate actual amount received
        uint256 balanceAfter = IERC20(stablecoin).balanceOf(address(this));
        uint256 actualAmount = balanceAfter - balanceBefore;
        require(actualAmount > 0, "No tokens received");

        // Calculate shares based on actual amount received
        uint256 shares = calculateShares(actualAmount, stablecoin);
        investors[msg.sender] = Investor(actualAmount, stablecoin, shares, false, false);
        investorList.push(msg.sender);

        totalDeposits += actualAmount;

        emit Deposit(msg.sender, stablecoin, actualAmount, shares);

        // Close pool if max capacity is reached
        if (totalDeposits == maxCapacity) {
            poolClosed = true;
            poolActive = false;
            emit PoolClosed();
        }
    }

    function getDecimals(address token) internal view returns (uint8) {
        return IERC20Metadata(token).decimals(); // Retrieve the decimals from the token
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

    function earlyWithdraw() 
        external 
        poolIsActive 
        nonReentrant 
        notContract(msg.sender)
        lockInvestor(msg.sender)
    {
        Investor storage investor = investors[msg.sender];
        require(investor.depositedAmount > 0, "No deposit found");
        require(!investor.hasWithdrawn, "Already withdrawn");

        // Calculate amounts
        uint256 depositedAmount = investor.depositedAmount;
        uint256 penalty = (depositedAmount * earlyWithdrawalPenaltyPercent) / 100;
        uint256 payout = depositedAmount - penalty;

        // Update state before external call (checks-effects-interactions pattern)
        investor.share = 0;
        investor.hasWithdrawn = true;
        investor.depositedAmount = 0;
        totalDeposits -= depositedAmount;

        // Emit event before external call
        emit EarlyWithdrawal(msg.sender, penalty, payout);

        // External call as last operation
        require(
            IERC20(investor.stablecoin).transfer(msg.sender, payout),
            "Early withdrawal transfer failed"
        );
    }

    // Withdraw funds after pool maturity
    function withdrawAfterMaturity() external nonReentrant {
        _withdrawAfterMaturity(msg.sender);
    }

    // Withdraw funds after pool maturity on behalf of a user
    function withdrawAfterMaturityFor(address account) external onlyMarketplace nonReentrant {
        _withdrawAfterMaturity(account);
    }

    // Internal function to handle withdrawal logic
    function _withdrawAfterMaturity(address account) 
        internal 
        notContract(account)
        lockInvestor(account)
    {
        require(block.timestamp >= poolEndTime, "Pool has not matured yet");
        Investor storage investor = investors[account];
        require(investor.depositedAmount > 0, "No deposit found");
        require(!investor.hasWithdrawn, "Already withdrawn");

        // Store amount before state changes
        uint256 depositedAmount = investor.depositedAmount;

        // Update state before external call (checks-effects-interactions pattern)
        investor.share = 0;
        investor.hasWithdrawn = true;
        investor.depositedAmount = 0;

        // Emit event before external call
        emit WithdrawalAfterMaturity(account, depositedAmount);

        // External call as last operation
        require(
            IERC20(investor.stablecoin).transfer(account, depositedAmount),
            "Maturity withdrawal transfer failed"
        );
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
            require(
                IERC20(investor.stablecoin).transfer(investorAddress, profitShare),
                "Profit transfer failed"
            );
        }

        emit ProfitAdded(profitAmount);
    }

    // Helper function to check if pool is fully subscribed
    function isPoolFullySubscribed() external view returns (bool) {
        return totalDeposits == maxCapacity;
    }
}
