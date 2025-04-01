// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./InvestmentPool.sol";

contract PoolFactory is Ownable, ReentrancyGuard {
    InvestmentPool[] public pools;
    mapping(address => bool) public existingPools;

    event PoolCreated(
        address indexed poolAddress,
        uint256 maxCapacity,
        uint256 lifespan
    );

    constructor() Ownable(msg.sender) {}

    function createPool(
        uint256 _maxCapacity,
        uint256 _poolLifespan,
        uint256 _earlyWithdrawalPenaltyPercent,
        address[] memory _approvedStablecoins
    ) external onlyOwner nonReentrant {
        InvestmentPool newPool = new InvestmentPool(
            _maxCapacity,
            _poolLifespan,
            _earlyWithdrawalPenaltyPercent
        );
        pools.push(newPool);
        existingPools[address(newPool)] = true;

        // Initialize approved stablecoins
        for (uint256 i = 0; i < _approvedStablecoins.length; i++) {
            newPool.modifyApprovedStablecoin(_approvedStablecoins[i], true);
        }

        emit PoolCreated(address(newPool), _maxCapacity, _poolLifespan);
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
        address _poolAddress,
        address _stablecoin,
        bool _status
    ) external onlyOwner nonReentrant {
        require(existingPools[_poolAddress], "Pool does not exist");
        InvestmentPool(_poolAddress).modifyApprovedStablecoin(
            _stablecoin,
            _status
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
