// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./InvestmentPool.sol";

contract PoolFactory is Ownable, ReentrancyGuard {
    InvestmentPool[] public pools;
    mapping(address => bool) public existingPools;
    address public marketplace;

    event PoolCreated(
        address indexed poolAddress,
        uint256 maxCapacity,
        uint256 lifespan
    );

    constructor(address marketplaceAddress) Ownable(msg.sender) {
        marketplace = marketplaceAddress;
    }

    function createPool(
        uint256 maxCapacity,
        uint256 poolLifespan,
        uint256 earlyWithdrawalPenaltyPercent,
        address[] memory approvedStablecoins
    ) external onlyOwner nonReentrant {
        InvestmentPool newPool = new InvestmentPool(
            maxCapacity,
            poolLifespan,
            earlyWithdrawalPenaltyPercent,
            marketplace
        );
        pools.push(newPool);
        existingPools[address(newPool)] = true;

        // Initialize approved stablecoins
        for (uint256 i = 0; i < approvedStablecoins.length; i++) {
            newPool.modifyApprovedStablecoin(approvedStablecoins[i], true);
        }

        emit PoolCreated(address(newPool), maxCapacity, poolLifespan);
    }

    function getPoolsCount() external view returns (uint256) {
        return pools.length;
    }

    function getPoolDetails(uint256 index)
        external
        view
        returns (
            address,
            uint256,
            uint256,
            uint256
        )
    {
        require(index < pools.length, "Pool does not exist");
        InvestmentPool pool = pools[index];
        return (
            address(pool),
            pool.maxCapacity(),
            pool.poolLifespan(),
            pool.totalDeposits()
        );
    }

    function modifyApprovedStablecoinForPool(
        address poolAddress,
        address stablecoin,
        bool status
    ) external onlyOwner nonReentrant {
        require(existingPools[poolAddress], "Pool does not exist");
        InvestmentPool(poolAddress).modifyApprovedStablecoin(
            stablecoin,
            status
        );
    }

    function isPoolExists(address poolAddress) external view returns (bool) {
        return existingPools[poolAddress];
    }

    function closePool(address poolAddress) external onlyOwner nonReentrant {
        require(existingPools[poolAddress], "Pool does not exist");
        InvestmentPool(poolAddress).closePool();
    }
}
