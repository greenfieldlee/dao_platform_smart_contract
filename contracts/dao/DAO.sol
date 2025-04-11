// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DAOGovernance
 * @dev A contract for managing DAO proposals and voting with token-based governance.
 */
contract DAOGovernance is Ownable, ReentrancyGuard {
    uint256 public constant MINIMUM_VOTES_REQUIRED = 100; // Base minimum votes required
    uint256 public constant MAX_VOTING_POWER_PER_USER = 1000; // Maximum voting power per user
    uint256 public constant PROPOSAL_COOLDOWN = 1 days; // Cooldown between proposals
    uint256 public constant EXECUTION_DELAY = 2 days; // Delay before execution
    uint256 public constant VOTING_POWER_LOCK_PERIOD = 7 days; // Time tokens must be locked for voting power

    IERC20 public governanceToken;

    struct Proposal {
        uint256 id;
        string description;
        uint256 voteCount;
        bool executed;
        address recipient;
        uint256 amount;
        uint256 creationTime;
        uint256 endTime;
    }

    struct VotingPower {
        uint256 amount;
        uint256 lockEndTime;
    }

    uint256 public proposalCount;
    uint256 public totalVotingPower;

    mapping(uint256 => Proposal) private proposals;
    mapping(address => VotingPower) public votingPower;
    mapping(uint256 => mapping(address => bool)) private proposalVotes;

    event ProposalCreated(uint256 indexed proposalId, string description);
    event Voted(uint256 indexed proposalId, address indexed voter, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId);
    event VotingPowerLocked(address indexed voter, uint256 amount, uint256 lockEndTime);
    event VotingPowerUnlocked(address indexed voter, uint256 amount);

    modifier onlyVoters() {
        require(votingPower[msg.sender].amount > 0, "No voting power");
        require(block.timestamp <= votingPower[msg.sender].lockEndTime, "Voting power expired");
        _;
    }

    constructor(address _governanceToken) Ownable(msg.sender) {
        require(_governanceToken != address(0), "Invalid governance token");
        governanceToken = IERC20(_governanceToken);
    }

    function lockTokensForVoting(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(amount <= MAX_VOTING_POWER_PER_USER, "Amount exceeds maximum voting power");
        
        uint256 currentPower = votingPower[msg.sender].amount;
        require(currentPower + amount <= MAX_VOTING_POWER_PER_USER, "Total power would exceed maximum");
        
        require(governanceToken.transferFrom(msg.sender, address(this), amount), "Token transfer failed");
        
        uint256 lockEndTime = block.timestamp + VOTING_POWER_LOCK_PERIOD;
        votingPower[msg.sender] = VotingPower({
            amount: currentPower + amount,
            lockEndTime: lockEndTime
        });
        
        totalVotingPower += amount;
        emit VotingPowerLocked(msg.sender, amount, lockEndTime);
    }

    function unlockTokens() external nonReentrant {
        VotingPower storage power = votingPower[msg.sender];
        require(power.amount > 0, "No tokens locked");
        require(block.timestamp > power.lockEndTime, "Lock period not ended");
        
        uint256 amount = power.amount;
        power.amount = 0;
        power.lockEndTime = 0;
        totalVotingPower -= amount;
        
        require(governanceToken.transfer(msg.sender, amount), "Token transfer failed");
        emit VotingPowerUnlocked(msg.sender, amount);
    }

    function createProposal(
        string memory description,
        address recipient,
        uint256 amount
    ) external onlyVoters {
        require(bytes(description).length > 0, "Proposal description cannot be empty");
        require(votingPower[msg.sender].amount >= MINIMUM_VOTES_REQUIRED, "Insufficient voting power");
        require(recipient != address(0) || amount == 0, "Invalid recipient for fund transfer");
        require(amount == 0 || address(this).balance >= amount, "Insufficient contract balance");
        
        if(proposalCount > 0) {
            Proposal storage lastProposal = proposals[proposalCount];
            require(
                block.timestamp >= lastProposal.creationTime + PROPOSAL_COOLDOWN,
                "Proposal cooldown period not met"
            );
        }

        proposalCount++;
        proposals[proposalCount] = Proposal({
            id: proposalCount,
            description: description,
            voteCount: 0,
            executed: false,
            recipient: recipient,
            amount: amount,
            creationTime: block.timestamp,
            endTime: block.timestamp + EXECUTION_DELAY
        });

        emit ProposalCreated(proposalCount, description);
    }

    function vote(uint256 proposalId) external onlyVoters {
        require(proposalId <= proposalCount, "Invalid proposalId");
        Proposal storage proposal = proposals[proposalId];
        require(!proposalVotes[proposalId][msg.sender], "Already voted");
        require(!proposal.executed, "Proposal already executed");
        require(block.timestamp <= proposal.endTime, "Voting period ended");

        proposal.voteCount += votingPower[msg.sender].amount;
        proposalVotes[proposalId][msg.sender] = true;

        emit Voted(proposalId, msg.sender, votingPower[msg.sender].amount);
    }

    function executeProposal(uint256 proposalId) external nonReentrant {
        require(proposalId <= proposalCount, "Invalid proposalId");
        Proposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "Proposal already executed");
        require(proposal.voteCount >= MINIMUM_VOTES_REQUIRED, "Not enough votes");
        require(block.timestamp >= proposal.endTime, "Voting period not ended");

        if (proposal.amount > 0 && proposal.recipient != address(0)) {
            require(address(this).balance >= proposal.amount, "Insufficient balance");
            (bool success, ) = proposal.recipient.call{value: proposal.amount}("");
            require(success, "Transfer failed");
        }

        proposal.executed = true;
        emit ProposalExecuted(proposalId);
    }

    receive() external payable {}
}
