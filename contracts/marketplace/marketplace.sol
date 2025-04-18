// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Interface for BLR Token
interface IBlrToken {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

// Interface for Investment Pool
interface IInvestmentPool {
    function deposit(address stablecoin, uint256 amount) external;
    function earlyWithdraw() external;
    function withdrawAfterMaturity() external;
    function modifyApprovedStablecoin(address stablecoin, bool status) external;
    function isPoolFullySubscribed() external view returns (bool);
    function totalDeposits() external view returns (uint256);
    function poolActive() external view returns (bool);
    function poolEndTime() external view returns (uint256);
    function investors(address account) external view returns (
        uint256 depositedAmount,
        address stablecoin,
        uint256 share,
        bool hasWithdrawn
    );
    function withdrawAfterMaturityFor(address account) external;
}

// Interface for Pool Factory
interface IPoolFactory {
    function isPoolExists(address pool) external view returns (bool);
}

contract Marketplace is Ownable, ReentrancyGuard {
    using SafeERC20 for IBlrToken;

    // State variables
    address public immutable blrToken;
    uint256 public immutable tradingFee;
    address public poolFactory;
    uint256 public accumulatedFees;

    // Structs
    struct Listing {
        address seller;
        uint256 amount;
        uint256 pricePerShare;
    }

    // Mappings
    mapping(address => Listing[]) public listings;

    // Events
    event SharesListed(
        address indexed pool,
        address indexed seller,
        uint256 amount,
        uint256 pricePerShare
    );
    event SharesPurchased(
        address indexed pool,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 totalPrice
    );
    event SharesDelisted(
        address indexed pool,
        address indexed seller,
        uint256 amount
    );
    event FeesWithdrawn(address indexed owner, uint256 amount);
    event Paused(address indexed owner);
    event Unpaused(address indexed owner);

    constructor(
        address blrTokenAddress,
        uint256 tradingFeeAmount,
        address poolFactoryAddress
    ) Ownable(msg.sender) {
        require(blrTokenAddress != address(0), "Invalid BLR token address");
        require(poolFactoryAddress != address(0), "Invalid pool factory address");
        blrToken = blrTokenAddress;
        tradingFee = tradingFeeAmount;
        poolFactory = poolFactoryAddress;
    }

    function listShares(
        address pool,
        uint256 amount,
        uint256 pricePerShare
    ) external nonReentrant {
        // Validate pool exists in PoolFactory
        require(IPoolFactory(poolFactory).isPoolExists(pool), "Invalid pool address");
        
        IInvestmentPool investmentPool = IInvestmentPool(pool);
        (, , uint256 share, ) = investmentPool.investors(msg.sender);

        require(share >= amount, "Insufficient shares to list");
        require(pricePerShare > 0, "Price per share must be greater than zero");
        require(amount > 0, "Amount must be greater than zero");

        Listing memory newListing = Listing({
            seller: msg.sender,
            amount: amount,
            pricePerShare: pricePerShare
        });

        listings[pool].push(newListing);

        emit SharesListed(pool, msg.sender, amount, pricePerShare);
    }

    function purchaseShares(
        address pool,
        uint256 listingIndex,
        uint256 amount
    ) external nonReentrant {
        // Validate pool exists in PoolFactory
        require(IPoolFactory(poolFactory).isPoolExists(pool), "Invalid pool address");
        
        require(listingIndex < listings[pool].length, "Listing does not exist");

        Listing storage listing = listings[pool][listingIndex];
        require(listing.amount >= amount, "Not enough shares available");
        require(amount > 0, "Amount must be greater than zero");

        // Calculate total price including fee, but delay division
        uint256 totalPriceWithoutFee = listing.pricePerShare * amount;
        uint256 totalPriceWithFee = totalPriceWithoutFee * (10000 + tradingFee);
        uint256 totalPrice = (totalPriceWithFee + 9999) / 10000; // rounding up

        require(
            IBlrToken(blrToken).balanceOf(msg.sender) >= totalPrice,
            "Insufficient BLR balance"
        );
        require(
            IBlrToken(blrToken).allowance(msg.sender, address(this)) >=
                totalPrice,
            "Allowance not set"
        );

        // Calculate the fee without intermediate divisions
        uint256 fee = (totalPriceWithFee -
            totalPriceWithoutFee *
            10000 +
            9999) / 10000; // rounding up
        uint256 sellerAmount = totalPrice - fee;

        // First transfer the total amount from buyer to contract
        require(
            IBlrToken(blrToken).transferFrom(msg.sender, address(this), totalPrice),
            "Transfer from buyer failed"
        );

        // Then transfer the seller's portion to the seller
        require(
            IBlrToken(blrToken).transfer(listing.seller, sellerAmount),
            "Transfer to seller failed"
        );

        // Accumulate the fee in the contract
        accumulatedFees += fee;

        // Update the listing
        listing.amount -= amount;

        if (listing.amount == 0) {
            removeListing(pool, listingIndex);
        }

        emit SharesPurchased(
            pool,
            msg.sender,
            listing.seller,
            amount,
            totalPrice
        );
    }

    function delistShares(
        address pool,
        uint256 listingIndex,
        uint256 amount
    ) external nonReentrant {
        // Validate pool exists in PoolFactory
        require(IPoolFactory(poolFactory).isPoolExists(pool), "Invalid pool address");
        
        require(listingIndex < listings[pool].length, "Listing does not exist");
        Listing storage listing = listings[pool][listingIndex];
        require(listing.seller == msg.sender, "Not the seller of this listing");
        require(listing.amount >= amount, "Not enough shares listed");

        // Update the listing amount
        listing.amount -= amount;

        if (listing.amount == 0) {
            removeListing(pool, listingIndex);
        }

        // Verify seller has sufficient shares in the pool
        IInvestmentPool investmentPool = IInvestmentPool(pool);
        (, , uint256 sellerShare, ) = investmentPool.investors(msg.sender);
        require(sellerShare >= amount, "Insufficient shares in pool");

        // Transfer payout to the seller directly
        withdrawSharesFromPool(pool, msg.sender);

        emit SharesDelisted(pool, msg.sender, amount);
    }

    // Internal function to withdraw shares from the pool
    function withdrawSharesFromPool(address pool, address seller)
        internal
        returns (uint256 payout)
    {
        IInvestmentPool investmentPool = IInvestmentPool(pool);

        // Retrieve seller's details
        (
            uint256 depositedAmount,
            ,
            ,
        ) = investmentPool.investors(seller);
        
        // Call withdrawAfterMaturity with the seller's address
        // This will handle all necessary checks internally
        investmentPool.withdrawAfterMaturityFor(seller);

        // Return payout amount
        return depositedAmount;
    }

    function removeListing(address pool, uint256 listingIndex) internal {
        listings[pool][listingIndex] = listings[pool][
            listings[pool].length - 1
        ];
        listings[pool].pop();
    }

    function withdrawFees() external onlyOwner nonReentrant {
        uint256 amount = accumulatedFees;
        require(amount > 0, "No fees to withdraw");

        accumulatedFees = 0;
        require(
            IBlrToken(blrToken).transfer(owner(), amount),
            "Fee transfer failed"
        );

        emit FeesWithdrawn(owner(), amount);
    }

    function setPoolFactory(address poolFactoryAddress) external onlyOwner {
        require(poolFactoryAddress != address(0), "Invalid pool factory address");
        poolFactory = poolFactoryAddress;
    }
}
