// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Interface for BLR Token
interface IBLRToken {
    function balanceOf(address account) external view returns (uint256);

    function allowance(address owner, address spender)
        external
        view
        returns (uint256);

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    function transfer(address recipient, uint256 amount)
        external
        returns (bool);
}

// Interface for Investment Pool
interface IInvestmentPool {
    function deposit(address _stablecoin, uint256 _amount) external;

    function earlyWithdraw() external;

    function withdrawAfterMaturity() external;

    function modifyApprovedStablecoin(address _stablecoin, bool _status)
        external;

    function isPoolFullySubscribed() external view returns (bool);

    function totalDeposits() external view returns (uint256);

    function poolActive() external view returns (bool);

    function poolEndTime() external view returns (uint256);

    // Function to retrieve an investor's details
    function investors(address account)
        external
        view
        returns (
            uint256 depositedAmount,
            address stablecoin,
            uint256 share,
            bool hasWithdrawn
        );
}

contract Marketplace is Ownable, ReentrancyGuard {
    address public immutable blrToken;
    uint256 public immutable tradingFee;
    uint256 public accumulatedFees;

    struct Listing {
        address seller;
        uint256 amount;
        uint256 pricePerShare;
    }

    mapping(address => Listing[]) public listings;

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

    constructor(address _blrToken, uint256 _tradingFee) Ownable(msg.sender) {
        blrToken = _blrToken;
        tradingFee = _tradingFee;
    }

    function listShares(
        address pool,
        uint256 amount,
        uint256 pricePerShare
    ) external nonReentrant {
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
        require(listingIndex < listings[pool].length, "Listing does not exist");

        Listing storage listing = listings[pool][listingIndex];
        require(listing.amount >= amount, "Not enough shares available");
        require(amount > 0, "Amount must be greater than zero");

        // Calculate total price including fee, but delay division
        uint256 totalPriceWithoutFee = listing.pricePerShare * amount;
        uint256 totalPriceWithFee = totalPriceWithoutFee * (10000 + tradingFee);
        uint256 totalPrice = (totalPriceWithFee + 9999) / 10000; // rounding up

        require(
            IBLRToken(blrToken).balanceOf(msg.sender) >= totalPrice,
            "Insufficient BLR balance"
        );
        require(
            IBLRToken(blrToken).allowance(msg.sender, address(this)) >=
                totalPrice,
            "Allowance not set"
        );

        // Calculate the fee without intermediate divisions
        uint256 fee = (totalPriceWithFee -
            totalPriceWithoutFee *
            10000 +
            9999) / 10000; // rounding up
        uint256 sellerAmount = totalPrice - fee;

        // Transfer the total price from buyer to seller
        IBLRToken(blrToken).transferFrom(
            msg.sender,
            listing.seller,
            sellerAmount
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
        require(listingIndex < listings[pool].length, "Listing does not exist");
        Listing storage listing = listings[pool][listingIndex];
        require(listing.seller == msg.sender, "Not the seller of this listing");
        require(listing.amount >= amount, "Not enough shares listed");

        // Update the listing amount
        listing.amount -= amount;

        if (listing.amount == 0) {
            removeListing(pool, listingIndex);
        }

        // Call withdrawAfterMaturity as the seller, not the Marketplace contract
        IInvestmentPool investmentPool = IInvestmentPool(pool);
        (, , uint256 sellerShare, ) = investmentPool.investors(msg.sender);
        require(sellerShare >= amount, "Insufficient shares in pool");

        // Ensure pool has matured before withdrawing
        require(
            block.timestamp >= poolEndTime(pool),
            "Pool has not matured yet"
        );

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
            uint256 share,
            bool hasWithdrawn
        ) = investmentPool.investors(seller);
        require(share > 0, "No shares to withdraw");
        require(!hasWithdrawn, "Already withdrawn");

        // Call withdrawAfterMaturity
        investmentPool.withdrawAfterMaturity();

        // Calculate payout (assuming 1:1 payout for simplicity)
        payout = depositedAmount;

        // Return payout amount
        return payout;
    }

    // Add an internal helper to retrieve pool end time
    function poolEndTime(address pool) internal view returns (uint256) {
        // Add a function in IInvestmentPool interface for poolEndTime
        return IInvestmentPool(pool).poolEndTime();
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
        IBLRToken(blrToken).transfer(owner(), amount);

        emit FeesWithdrawn(owner(), amount);
    }
}
