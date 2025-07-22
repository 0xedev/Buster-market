// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

interface IPolicastMarketV1 {
    enum MarketOutcome {
        UNRESOLVED,
        OPTION_A,
        OPTION_B
    }
    
    function getMarketInfo(uint256 _marketId) external view returns (
        string memory question,
        string memory optionA,
        string memory optionB,
        uint256 endTime,
        MarketOutcome outcome,
        uint256 totalOptionAShares,
        uint256 totalOptionBShares,
        bool resolved
    );
    
    function getShareBalance(uint256 _marketId, address _user) external view returns (uint256 optionAShares, uint256 optionBShares);
    function getMarketCount() external view returns (uint256);
    function totalWinnings(address user) external view returns (uint256);
    function getVoteHistoryCount(address user) external view returns (uint256);
    function getAllParticipantsCount() external view returns (uint256);
}

contract PolicastMarketV2 is Ownable, ReentrancyGuard, AccessControl {
    bytes32 public constant QUESTION_CREATOR_ROLE = keccak256("QUESTION_CREATOR_ROLE");
    bytes32 public constant QUESTION_RESOLVE_ROLE = keccak256("QUESTION_RESOLVE_ROLE");
    bytes32 public constant CANCEL_ROLE = keccak256("CANCEL_ROLE");

    enum MarketOutcome {
        UNRESOLVED,
        OPTION_1,
        OPTION_2,
        OPTION_3,
        OPTION_4,
        OPTION_5,
        CANCELLED
    }

    enum MarketStatus {
        ACTIVE,
        ENDED,
        RESOLVED,
        CANCELLED
    }

    struct Market {
        string question;
        uint256 endTime;
        MarketOutcome outcome;
        string[] options; // Dynamic options array
        uint256[] totalShares; // Shares for each option
        mapping(address => uint256[]) userShares; // User shares for each option
        mapping(address => bool) hasClaimed;
        address[] participants;
        uint256 payoutIndex;
        bool resolved;
        bool cancelled;
        uint256 createdAt;
        // Distribution tracking
        uint256 totalWinningsDistributed;
        uint256 winnersCount;
        uint256 totalWinnersCount;
        bool distributionCompleted;
    }

    struct Vote {
        uint256 marketId;
        uint256 optionIndex;
        uint256 amount;
        uint256 timestamp;
    }

    struct LeaderboardEntry {
        address user;
        uint256 totalWinnings;
        uint256 voteCount;
    }

    struct MarketVoter {
        address user;
        uint256 shares;
    }

    struct UserMarketActivity {
        uint256 marketId;
        uint256[] optionsInvested; // Which options user invested in
        uint256[] amountsInvested; // Amount invested in each option
        uint256 totalInvested; // Total amount invested in this market
        uint256 winnings; // Amount won from this market (0 if lost)
        bool hasWon; // Whether user won in this market
        bool hasClaimed; // Whether user has claimed rewards
        uint256 investmentDate; // When user first invested in this market
    }

    struct UserProfile {
        address user;
        uint256 totalInvested; // Total amount ever invested
        uint256 totalWinnings; // Total amount ever won
        uint256 totalLosses; // Total amount lost
        uint256 marketsParticipated; // Number of markets participated in
        uint256 marketsWon; // Number of markets won
        uint256 marketsLost; // Number of markets lost
        uint256 activeMarkets; // Number of active markets user is in
        uint256 firstActivityDate; // Date of first activity
        uint256 lastActivityDate; // Date of last activity
    }

    IERC20 public bettingToken;
    IERC20Permit public bettingTokenPermit;
    uint256 public marketCount;
    mapping(uint256 => Market) public markets;
    mapping(address => uint256) public totalSharesPurchased;
    mapping(address => uint256) public totalWinnings;
    mapping(address => Vote[]) public voteHistory;
    address[] public allParticipants;
    
    // User profile tracking
    mapping(address => UserProfile) public userProfiles;
    mapping(address => UserMarketActivity[]) public userMarketActivities;
    mapping(address => mapping(uint256 => uint256)) public userMarketActivityIndex; // user -> marketId -> index in userMarketActivities
    mapping(address => uint256[]) public userActiveMarkets; // Markets user is currently active in
    mapping(address => uint256) public userTotalLosses; // Track total losses per user
    
    // V1 contract for migration
    IPolicastMarketV1 public immutable v1Contract;
    uint256 public immutable v1MarketCount;
    bool public migrationCompleted = false;

    event MarketCreated(uint256 indexed marketId, string question, string[] options, uint256 endTime);
    event MarketCancelled(uint256 indexed marketId, string reason);
    event QuestionCreatorRoleGranted(address indexed account);
    event QuestionResolveRoleGranted(address indexed account);
    event CancelRoleGranted(address indexed account);
    event MarketResolved(uint256 indexed marketId, MarketOutcome outcome);
    event MarketResolvedDetailed(uint256 indexed marketId, MarketOutcome outcome, uint256[] totalShares, uint256 participantsLength);
    event SharesPurchased(uint256 indexed marketId, address indexed buyer, uint256 optionIndex, uint256 amount);
    event SharesPurchasedWithPermit(uint256 indexed marketId, address indexed buyer, uint256 optionIndex, uint256 amount);
    event Claimed(uint256 indexed marketId, address indexed user, uint256 amount);
    event Refunded(uint256 indexed marketId, address indexed user, uint256 amount);
    event MigrationCompleted(uint256 migratedMarkets, uint256 migratedUsers);

    modifier onlyAfterMigration() {
        require(migrationCompleted, "Migration not completed");
        _;
    }

    constructor(address _bettingToken, address _v1Contract) Ownable(msg.sender) {
        bettingToken = IERC20(_bettingToken);
        bettingTokenPermit = IERC20Permit(_bettingToken);
        v1Contract = IPolicastMarketV1(_v1Contract);
        v1MarketCount = _v1Contract != address(0) ? IPolicastMarketV1(_v1Contract).getMarketCount() : 0;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CANCEL_ROLE, msg.sender);
        
        // If no V1 contract, mark migration as completed
        if (_v1Contract == address(0)) {
            migrationCompleted = true;
            marketCount = 0;
        } else {
            marketCount = v1MarketCount;
        }
    }

    // Migration functions
    function migrateMarketsFromV1(uint256 startIndex, uint256 endIndex) external onlyOwner {
        require(!migrationCompleted, "Migration already completed");
        require(address(v1Contract) != address(0), "No V1 contract set");
        require(endIndex <= v1MarketCount, "End index out of bounds");
        
        for (uint256 i = startIndex; i < endIndex; i++) {
            (
                string memory question,
                string memory optionA,
                string memory optionB,
                uint256 endTime,
                IPolicastMarketV1.MarketOutcome v1Outcome,
                uint256 totalOptionAShares,
                uint256 totalOptionBShares,
                bool resolved
            ) = v1Contract.getMarketInfo(i);
            
            Market storage market = markets[i];
            market.question = question;
            market.endTime = endTime;
            market.resolved = resolved;
            market.createdAt = endTime > 86400 ? endTime - 86400 : block.timestamp; // Estimate creation time
            
            // Convert V1 options to V2 format
            market.options = new string[](2);
            market.options[0] = optionA;
            market.options[1] = optionB;
            
            // Initialize shares arrays
            market.totalShares = new uint256[](2);
            market.totalShares[0] = totalOptionAShares;
            market.totalShares[1] = totalOptionBShares;
            
            // Convert outcome
            if (v1Outcome == IPolicastMarketV1.MarketOutcome.OPTION_A) {
                market.outcome = MarketOutcome.OPTION_1;
            } else if (v1Outcome == IPolicastMarketV1.MarketOutcome.OPTION_B) {
                market.outcome = MarketOutcome.OPTION_2;
            } else {
                market.outcome = MarketOutcome.UNRESOLVED;
            }
        }
    }

    function completeMigration() external onlyOwner {
        require(!migrationCompleted, "Migration already completed");
        migrationCompleted = true;
        emit MigrationCompleted(marketCount, allParticipants.length);
    }

    // Role management
    function grantQuestionCreatorRole(address _account) external onlyOwner {
        grantRole(QUESTION_CREATOR_ROLE, _account);
        emit QuestionCreatorRoleGranted(_account);
    }

    function grantQuestionResolveRole(address _account) external onlyOwner {
        grantRole(QUESTION_RESOLVE_ROLE, _account);
        emit QuestionResolveRoleGranted(_account);
    }

    function grantCancelRole(address _account) external onlyOwner {
        grantRole(CANCEL_ROLE, _account);
        emit CancelRoleGranted(_account);
    }

    // Market creation with multiple options
    function createMarket(
        string memory _question, 
        string[] memory _options, 
        uint256 _duration
    ) external onlyAfterMigration returns (uint256) {
        require(msg.sender == owner() || hasRole(QUESTION_CREATOR_ROLE, msg.sender), "Not authorized to create markets");
        require(_duration > 0, "Duration must be greater than 0");
        require(bytes(_question).length > 0, "Question cannot be empty");
        require(_options.length >= 2 && _options.length <= 5, "Must have 2-5 options");
        
        for (uint256 i = 0; i < _options.length; i++) {
            require(bytes(_options[i]).length > 0, "Option cannot be empty");
        }

        uint256 marketId = marketCount++;
        Market storage market = markets[marketId];
        market.question = _question;
        market.endTime = block.timestamp + _duration;
        market.outcome = MarketOutcome.UNRESOLVED;
        market.createdAt = block.timestamp;
        
        // Initialize options and shares arrays
        market.options = _options;
        market.totalShares = new uint256[](_options.length);

        emit MarketCreated(marketId, _question, _options, market.endTime);
        return marketId;
    }

    // EIP-5792 compatible single-transaction buy with permit
    function buySharesWithPermit(
        uint256 _marketId, 
        uint256 _optionIndex, 
        uint256 _amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant onlyAfterMigration {
        // Use permit to approve the transfer in the same transaction
        bettingTokenPermit.permit(msg.sender, address(this), _amount, deadline, v, r, s);
        
        // Transfer tokens
        require(bettingToken.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        
        // Execute the buy
        _buySharesInternal(_marketId, _optionIndex, _amount);
        
        // Emit specific event for permit-based purchase
        emit SharesPurchasedWithPermit(_marketId, msg.sender, _optionIndex, _amount);
    }

    function buyShares(uint256 _marketId, uint256 _optionIndex, uint256 _amount) external nonReentrant onlyAfterMigration {
        require(bettingToken.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        _buySharesInternal(_marketId, _optionIndex, _amount);
    }

    function _buySharesInternal(uint256 _marketId, uint256 _optionIndex, uint256 _amount) internal {
        Market storage market = markets[_marketId];
        require(block.timestamp < market.endTime, "Market trading period has ended");
        require(!market.resolved && !market.cancelled, "Market not active");
        require(_amount > 0, "Amount must be positive");
        require(_optionIndex < market.options.length, "Invalid option index");

        // Initialize user shares array if first time participating
        if (market.userShares[msg.sender].length == 0) {
            market.userShares[msg.sender] = new uint256[](market.options.length);
            market.participants.push(msg.sender);
            
            if (totalSharesPurchased[msg.sender] == 0) {
                allParticipants.push(msg.sender);
                // Initialize user profile
                userProfiles[msg.sender].user = msg.sender;
                userProfiles[msg.sender].firstActivityDate = block.timestamp;
            }
            
            // Add to user's active markets
            userActiveMarkets[msg.sender].push(_marketId);
            userProfiles[msg.sender].activeMarkets++;
            userProfiles[msg.sender].marketsParticipated++;
            
            // Create user market activity record
            UserMarketActivity memory activity;
            activity.marketId = _marketId;
            activity.optionsInvested = new uint256[](market.options.length);
            activity.amountsInvested = new uint256[](market.options.length);
            activity.investmentDate = block.timestamp;
            
            userMarketActivities[msg.sender].push(activity);
            userMarketActivityIndex[msg.sender][_marketId] = userMarketActivities[msg.sender].length - 1;
        }

        market.userShares[msg.sender][_optionIndex] += _amount;
        market.totalShares[_optionIndex] += _amount;
        totalSharesPurchased[msg.sender] += _amount;
        
        // Update user profile
        userProfiles[msg.sender].totalInvested += _amount;
        userProfiles[msg.sender].lastActivityDate = block.timestamp;
        
        // Update user market activity
        uint256 activityIndex = userMarketActivityIndex[msg.sender][_marketId];
        userMarketActivities[msg.sender][activityIndex].amountsInvested[_optionIndex] += _amount;
        userMarketActivities[msg.sender][activityIndex].totalInvested += _amount;

        voteHistory[msg.sender].push(Vote({
            marketId: _marketId,
            optionIndex: _optionIndex,
            amount: _amount,
            timestamp: block.timestamp
        }));

        emit SharesPurchased(_marketId, msg.sender, _optionIndex, _amount);
    }

    function resolveMarket(uint256 _marketId, MarketOutcome _outcome) external onlyAfterMigration {
        require(msg.sender == owner() || hasRole(QUESTION_RESOLVE_ROLE, msg.sender), "Not authorized to resolve markets");
        Market storage market = markets[_marketId];
        require(block.timestamp >= market.endTime, "Market has not ended yet");
        require(!market.resolved && !market.cancelled, "Market not resolvable");
        require(_outcome != MarketOutcome.UNRESOLVED && _outcome != MarketOutcome.CANCELLED, "Invalid outcome");
        
        uint256 outcomeIndex = uint256(_outcome) - 1; // Convert to 0-based index
        require(outcomeIndex < market.options.length, "Outcome index out of range");

        market.outcome = _outcome;
        market.resolved = true;
        
        // Calculate total winners count for tracking
        uint256 totalWinners = 0;
        for (uint256 i = 0; i < market.participants.length; i++) {
            if (market.userShares[market.participants[i]][outcomeIndex] > 0) {
                totalWinners++;
            }
        }
        market.totalWinnersCount = totalWinners;
        
        emit MarketResolvedDetailed(_marketId, _outcome, market.totalShares, market.participants.length);
    }

    // New function: Cancel market and refund users
    function cancelMarket(uint256 _marketId, string memory _reason) external onlyAfterMigration {
        require(msg.sender == owner() || hasRole(CANCEL_ROLE, msg.sender), "Not authorized to cancel markets");
        Market storage market = markets[_marketId];
        require(block.timestamp >= market.endTime, "Market has not ended yet");
        require(!market.resolved && !market.cancelled, "Market already resolved or cancelled");

        market.cancelled = true;
        market.outcome = MarketOutcome.CANCELLED;
        
        emit MarketCancelled(_marketId, _reason);
    }

    function refundFromCancelledMarket(uint256 _marketId) external nonReentrant onlyAfterMigration {
        Market storage market = markets[_marketId];
        require(market.cancelled, "Market not cancelled");
        require(!market.hasClaimed[msg.sender], "Already refunded");
        
        uint256 totalUserShares = 0;
        for (uint256 i = 0; i < market.options.length; i++) {
            totalUserShares += market.userShares[msg.sender][i];
        }
        
        require(totalUserShares > 0, "No shares to refund");
        
        // Update user profile - remove from active markets
        _removeFromActiveMarkets(msg.sender, _marketId);
        userProfiles[msg.sender].activeMarkets--;
        
        // Update user market activity
        uint256 activityIndex = userMarketActivityIndex[msg.sender][_marketId];
        userMarketActivities[msg.sender][activityIndex].winnings = totalUserShares; // Refund amount
        userMarketActivities[msg.sender][activityIndex].hasWon = false; // Not a win, just refund
        userMarketActivities[msg.sender][activityIndex].hasClaimed = true;
        
        market.hasClaimed[msg.sender] = true;
        require(bettingToken.transfer(msg.sender, totalUserShares), "Refund failed");
        
        emit Refunded(_marketId, msg.sender, totalUserShares);
    }

    function distributeWinningsBatch(uint256 _marketId, uint256 batchSize) external nonReentrant onlyAfterMigration {
        Market storage market = markets[_marketId];
        require(msg.sender == owner() || hasRole(QUESTION_RESOLVE_ROLE, msg.sender), "Not authorized");
        require(market.resolved && !market.cancelled, "Market not properly resolved");
        require(!market.distributionCompleted, "Distribution already completed");

        uint256 totalParticipants = market.participants.length;
        uint256 payoutEnd = market.payoutIndex + batchSize;
        if (payoutEnd > totalParticipants) {
            payoutEnd = totalParticipants;
        }

        uint256 outcomeIndex = uint256(market.outcome) - 1;
        uint256 winningShares = market.totalShares[outcomeIndex];
        require(winningShares > 0, "No winning shares");

        // Calculate total losing shares
        uint256 totalLosingShares = 0;
        for (uint256 i = 0; i < market.totalShares.length; i++) {
            if (i != outcomeIndex) {
                totalLosingShares += market.totalShares[i];
            }
        }

        uint256 rewardRatio = totalLosingShares > 0 ? (totalLosingShares * 1e18) / winningShares : 0;
        uint256 batchWinningsDistributed = 0;
        uint256 batchWinnersProcessed = 0;

        for (uint256 i = market.payoutIndex; i < payoutEnd; i++) {
            address user = market.participants[i];
            uint256 userWinningShares = market.userShares[user][outcomeIndex];
            
            // Calculate user's total investment in this market
            uint256 userTotalInvestment = 0;
            for (uint256 j = 0; j < market.options.length; j++) {
                userTotalInvestment += market.userShares[user][j];
            }

            if (!market.hasClaimed[user]) {
                // Update user profile - remove from active markets
                _removeFromActiveMarkets(user, _marketId);
                userProfiles[user].activeMarkets--;
                
                // Update user market activity
                uint256 activityIndex = userMarketActivityIndex[user][_marketId];
                
                if (userWinningShares > 0) {
                    // User won
                    uint256 winnings = userWinningShares + (userWinningShares * rewardRatio) / 1e18;
                    
                    // Update user profile
                    userProfiles[user].marketsWon++;
                    userProfiles[user].totalWinnings += winnings;
                    totalWinnings[user] += winnings;
                    
                    // Update user market activity
                    userMarketActivities[user][activityIndex].winnings = winnings;
                    userMarketActivities[user][activityIndex].hasWon = true;
                    userMarketActivities[user][activityIndex].hasClaimed = true;
                    
                    // Track distribution progress
                    batchWinningsDistributed += winnings;
                    batchWinnersProcessed++;
                    
                    require(bettingToken.transfer(user, winnings), "Transfer failed");
                    emit Claimed(_marketId, user, winnings);
                } else {
                    // User lost
                    userProfiles[user].marketsLost++;
                    userProfiles[user].totalLosses += userTotalInvestment;
                    userTotalLosses[user] += userTotalInvestment;
                    
                    // Update user market activity
                    userMarketActivities[user][activityIndex].hasWon = false;
                    userMarketActivities[user][activityIndex].hasClaimed = true;
                }
                
                // Clear user shares
                for (uint256 j = 0; j < market.options.length; j++) {
                    market.userShares[user][j] = 0;
                }
                
                market.hasClaimed[user] = true;
            }
        }
        
        // Update market distribution tracking
        market.totalWinningsDistributed += batchWinningsDistributed;
        market.winnersCount += batchWinnersProcessed;
        market.payoutIndex = payoutEnd;
        
        // Check if distribution is completed
        if (payoutEnd >= totalParticipants) {
            market.distributionCompleted = true;
        }
    }

    // Helper function to remove market from user's active markets
    function _removeFromActiveMarkets(address user, uint256 marketId) internal {
        uint256[] storage activeMarkets = userActiveMarkets[user];
        for (uint256 i = 0; i < activeMarkets.length; i++) {
            if (activeMarkets[i] == marketId) {
                activeMarkets[i] = activeMarkets[activeMarkets.length - 1];
                activeMarkets.pop();
                break;
            }
        }
    }

    // New function: Get voters by option
    function getVotersByOption(uint256 _marketId, uint256 _optionIndex, uint256 _start, uint256 _limit) 
        external view returns (MarketVoter[] memory) {
        Market storage market = markets[_marketId];
        require(_optionIndex < market.options.length, "Invalid option index");
        
        // First pass: count voters with shares in this option
        uint256 voterCount = 0;
        for (uint256 i = 0; i < market.participants.length; i++) {
            if (market.userShares[market.participants[i]][_optionIndex] > 0) {
                voterCount++;
            }
        }
        
        // Apply pagination
        uint256 start = _start > voterCount ? voterCount : _start;
        uint256 end = start + _limit > voterCount ? voterCount : start + _limit;
        
        MarketVoter[] memory voters = new MarketVoter[](end - start);
        uint256 currentVoterIndex = 0;
        uint256 resultIndex = 0;
        
        // Second pass: collect voters with pagination
        for (uint256 i = 0; i < market.participants.length && resultIndex < voters.length; i++) {
            address participant = market.participants[i];
            uint256 shares = market.userShares[participant][_optionIndex];
            
            if (shares > 0) {
                if (currentVoterIndex >= start) {
                    voters[resultIndex] = MarketVoter({
                        user: participant,
                        shares: shares
                    });
                    resultIndex++;
                }
                currentVoterIndex++;
            }
        }
        
        return voters;
    }

    function getVotersByOptionCount(uint256 _marketId, uint256 _optionIndex) external view returns (uint256) {
        Market storage market = markets[_marketId];
        require(_optionIndex < market.options.length, "Invalid option index");
        
        uint256 count = 0;
        for (uint256 i = 0; i < market.participants.length; i++) {
            if (market.userShares[market.participants[i]][_optionIndex] > 0) {
                count++;
            }
        }
        return count;
    }

    // Updated view functions
    function getMarketInfo(uint256 _marketId)
        external
        view
        returns (
            string memory question,
            string[] memory options,
            uint256 endTime,
            MarketOutcome outcome,
            uint256[] memory totalShares,
            bool resolved,
            bool cancelled,
            MarketStatus status
        )
    {
        Market storage market = markets[_marketId];
        
        MarketStatus marketStatus;
        if (market.cancelled) {
            marketStatus = MarketStatus.CANCELLED;
        } else if (market.resolved) {
            marketStatus = MarketStatus.RESOLVED;
        } else if (block.timestamp >= market.endTime) {
            marketStatus = MarketStatus.ENDED;
        } else {
            marketStatus = MarketStatus.ACTIVE;
        }
        
        return (
            market.question,
            market.options,
            market.endTime,
            market.outcome,
            market.totalShares,
            market.resolved,
            market.cancelled,
            marketStatus
        );
    }

    function getUserShares(uint256 _marketId, address _user) external view returns (uint256[] memory) {
        return markets[_marketId].userShares[_user];
    }

    function getMarketStatus(uint256 _marketId) external view returns (MarketStatus) {
        Market storage market = markets[_marketId];
        
        if (market.cancelled) {
            return MarketStatus.CANCELLED;
        } else if (market.resolved) {
            return MarketStatus.RESOLVED;
        } else if (block.timestamp >= market.endTime) {
            return MarketStatus.ENDED;
        } else {
            return MarketStatus.ACTIVE;
        }
    }

    // Legacy compatibility functions for V1 data
    function getShareBalance(uint256 _marketId, address _user)
        external
        view
        returns (uint256 optionAShares, uint256 optionBShares)
    {
        if (_marketId < v1MarketCount && !migrationCompleted) {
            return v1Contract.getShareBalance(_marketId, _user);
        }
        
        Market storage market = markets[_marketId];
        if (market.options.length >= 2) {
            return (
                market.userShares[_user].length > 0 ? market.userShares[_user][0] : 0,
                market.userShares[_user].length > 1 ? market.userShares[_user][1] : 0
            );
        }
        return (0, 0);
    }

    // Standard view functions
    function getUserClaimedStatus(uint256 _marketId, address _user) external view returns (bool) {
        return markets[_marketId].hasClaimed[_user];
    }

    function getMarketCount() external view returns (uint256) {
        return marketCount;
    }

    function getBettingToken() external view returns (address) {
        return address(bettingToken);
    }

    function getLeaderboard(uint256 start, uint256 limit) external view returns (LeaderboardEntry[] memory) {
        require(start < allParticipants.length, "Start index out of bounds");
        uint256 end = start + limit > allParticipants.length ? allParticipants.length : start + limit;
        LeaderboardEntry[] memory entries = new LeaderboardEntry[](end - start);

        for (uint256 i = start; i < end; i++) {
            address user = allParticipants[i];
            entries[i - start] = LeaderboardEntry({
                user: user,
                totalWinnings: totalWinnings[user],
                voteCount: voteHistory[user].length
            });
        }
        return entries;
    }

    function getVoteHistory(address user, uint256 start, uint256 limit) external view returns (Vote[] memory) {
        Vote[] storage votes = voteHistory[user];
        require(start < votes.length, "Start index out of bounds");
        uint256 end = start + limit > votes.length ? votes.length : start + limit;
        Vote[] memory result = new Vote[](end - start);

        for (uint256 i = start; i < end; i++) {
            result[i - start] = votes[i];
        }
        return result;
    }

    function getVoteHistoryCount(address user) external view returns (uint256) {
        return voteHistory[user].length;
    }

    function getAllParticipantsCount() external view returns (uint256) {
        return allParticipants.length;
    }

    function getMarketInfoBatch(uint256[] calldata _marketIds)
        external
        view
        returns (
            string[] memory questions,
            string[][] memory optionsArray,
            uint256[] memory endTimes,
            MarketOutcome[] memory outcomes,
            uint256[][] memory totalSharesArray,
            bool[] memory resolvedArray,
            bool[] memory cancelledArray
        )
    {
        uint256 length = _marketIds.length;
        questions = new string[](length);
        optionsArray = new string[][](length);
        endTimes = new uint256[](length);
        outcomes = new MarketOutcome[](length);
        totalSharesArray = new uint256[][](length);
        resolvedArray = new bool[](length);
        cancelledArray = new bool[](length);

        for (uint256 i = 0; i < length; i++) {
            Market storage market = markets[_marketIds[i]];
            questions[i] = market.question;
            optionsArray[i] = market.options;
            endTimes[i] = market.endTime;
            outcomes[i] = market.outcome;
            totalSharesArray[i] = market.totalShares;
            resolvedArray[i] = market.resolved;
            cancelledArray[i] = market.cancelled;
        }
    }
    
    // User Profile Functions
    function getUserProfile(address user) external view returns (UserProfile memory) {
        return userProfiles[user];
    }
    
    function getUserMarketActivities(address user, uint256 start, uint256 limit) 
        external view returns (UserMarketActivity[] memory) {
        UserMarketActivity[] storage activities = userMarketActivities[user];
        require(start < activities.length, "Start index out of bounds");
        uint256 end = start + limit > activities.length ? activities.length : start + limit;
        UserMarketActivity[] memory result = new UserMarketActivity[](end - start);

        for (uint256 i = start; i < end; i++) {
            result[i - start] = activities[i];
        }
        return result;
    }
    
    function getUserActiveMarkets(address user) external view returns (uint256[] memory) {
        return userActiveMarkets[user];
    }
    
    function getUserMarketActivity(address user, uint256 marketId) 
        external view returns (UserMarketActivity memory) {
        uint256 index = userMarketActivityIndex[user][marketId];
        require(index < userMarketActivities[user].length, "Market activity not found");
        return userMarketActivities[user][index];
    }
    
    function getUserMarketFeed(address user, uint256 start, uint256 limit) 
        external view returns (
            uint256[] memory marketIds,
            string[] memory questions,
            uint256[] memory totalInvested,
            uint256[] memory winnings,
            bool[] memory hasWon,
            bool[] memory isActive
        ) {
        UserMarketActivity[] storage activities = userMarketActivities[user];
        require(start < activities.length, "Start index out of bounds");
        uint256 end = start + limit > activities.length ? activities.length : start + limit;
        uint256 length = end - start;
        
        marketIds = new uint256[](length);
        questions = new string[](length);
        totalInvested = new uint256[](length);
        winnings = new uint256[](length);
        hasWon = new bool[](length);
        isActive = new bool[](length);

        for (uint256 i = start; i < end; i++) {
            UserMarketActivity storage activity = activities[i];
            uint256 resultIndex = i - start;
            
            marketIds[resultIndex] = activity.marketId;
            questions[resultIndex] = markets[activity.marketId].question;
            totalInvested[resultIndex] = activity.totalInvested;
            winnings[resultIndex] = activity.winnings;
            hasWon[resultIndex] = activity.hasWon;
            
            // Check if market is still active for this user
            Market storage market = markets[activity.marketId];
            isActive[resultIndex] = !market.resolved && !market.cancelled && block.timestamp < market.endTime;
        }
        
        return (marketIds, questions, totalInvested, winnings, hasWon, isActive);
    }
    
    function getUserStats(address user) external view returns (
        uint256 totalInvested,
        uint256 totalWinnings,
        uint256 totalLosses,
        uint256 netProfit, // totalWinnings - totalInvested
        uint256 winRate, // (marketsWon * 100) / marketsParticipated
        uint256 avgInvestmentPerMarket,
        uint256 avgWinningsPerWin
    ) {
        UserProfile storage profile = userProfiles[user];
        
        totalInvested = profile.totalInvested;
        totalWinnings = profile.totalWinnings;
        totalLosses = profile.totalLosses;
        
        // Calculate net profit (can be negative)
        if (totalWinnings >= totalInvested) {
            netProfit = totalWinnings - totalInvested;
        } else {
            netProfit = 0; // We'll handle negative values in frontend
        }
        
        // Calculate win rate as percentage (multiply by 100)
        if (profile.marketsParticipated > 0) {
            winRate = (profile.marketsWon * 100) / profile.marketsParticipated;
            avgInvestmentPerMarket = totalInvested / profile.marketsParticipated;
        } else {
            winRate = 0;
            avgInvestmentPerMarket = 0;
        }
        
        // Calculate average winnings per winning market
        if (profile.marketsWon > 0) {
            avgWinningsPerWin = totalWinnings / profile.marketsWon;
        } else {
            avgWinningsPerWin = 0;
        }
        
        return (totalInvested, totalWinnings, totalLosses, netProfit, winRate, avgInvestmentPerMarket, avgWinningsPerWin);
    }
    
    function getUserMarketDetails(address user, uint256 marketId) 
        external view returns (
            string memory question,
            string[] memory options,
            uint256[] memory userInvestments, // Amount invested in each option
            uint256 totalUserInvestment,
            uint256 userWinnings,
            bool hasUserWon,
            bool isResolved,
            bool isCancelled,
            MarketOutcome outcome
        ) {
        Market storage market = markets[marketId];
        uint256 activityIndex = userMarketActivityIndex[user][marketId];
        require(activityIndex < userMarketActivities[user].length, "User not participated in this market");
        
        UserMarketActivity storage activity = userMarketActivities[user][activityIndex];
        
        return (
            market.question,
            market.options,
            activity.amountsInvested,
            activity.totalInvested,
            activity.winnings,
            activity.hasWon,
            market.resolved,
            market.cancelled,
            market.outcome
        );
    }
    
    // Distribution tracking functions
    function getMarketDistributionStatus(uint256 _marketId) 
        external view returns (
            uint256 totalWinningsDistributed,
            uint256 winnersProcessed,
            uint256 totalWinners,
            uint256 participantsProcessed,
            uint256 totalParticipants,
            bool distributionCompleted,
            uint256 estimatedRemainingWinnings
        ) {
        Market storage market = markets[_marketId];
        require(market.resolved, "Market not resolved yet");
        
        totalWinningsDistributed = market.totalWinningsDistributed;
        winnersProcessed = market.winnersCount;
        totalWinners = market.totalWinnersCount;
        participantsProcessed = market.payoutIndex;
        totalParticipants = market.participants.length;
        distributionCompleted = market.distributionCompleted;
        
        // Calculate estimated remaining winnings
        if (!distributionCompleted && totalWinners > winnersProcessed) {
            uint256 outcomeIndex = uint256(market.outcome) - 1;
            uint256 winningShares = market.totalShares[outcomeIndex];
            
            // Calculate total losing shares
            uint256 totalLosingShares = 0;
            for (uint256 i = 0; i < market.totalShares.length; i++) {
                if (i != outcomeIndex) {
                    totalLosingShares += market.totalShares[i];
                }
            }
            
            uint256 totalWinningPool = winningShares + totalLosingShares;
            estimatedRemainingWinnings = totalWinningPool - totalWinningsDistributed;
        } else {
            estimatedRemainingWinnings = 0;
        }
        
        return (
            totalWinningsDistributed,
            winnersProcessed,
            totalWinners,
            participantsProcessed,
            totalParticipants,
            distributionCompleted,
            estimatedRemainingWinnings
        );
    }
    
    function getMarketDistributionProgress(uint256 _marketId) 
        external view returns (
            uint256 distributionPercentage,
            uint256 winnersPercentage,
            uint256 remainingBatches
        ) {
        Market storage market = markets[_marketId];
        require(market.resolved, "Market not resolved yet");
        
        // Calculate distribution percentage based on participants processed
        if (market.participants.length > 0) {
            distributionPercentage = (market.payoutIndex * 100) / market.participants.length;
        } else {
            distributionPercentage = 100;
        }
        
        // Calculate winners percentage
        if (market.totalWinnersCount > 0) {
            winnersPercentage = (market.winnersCount * 100) / market.totalWinnersCount;
        } else {
            winnersPercentage = 100;
        }
        
        // Calculate remaining batches (assuming batch size of 50)
        uint256 remaining = market.participants.length - market.payoutIndex;
        remainingBatches = remaining > 0 ? (remaining + 49) / 50 : 0; // Ceiling division
        
        return (distributionPercentage, winnersPercentage, remainingBatches);
    }
    
    function getTotalWinningsPool(uint256 _marketId) external view returns (uint256) {
        Market storage market = markets[_marketId];
        require(market.resolved, "Market not resolved yet");
        
        uint256 totalPool = 0;
        for (uint256 i = 0; i < market.totalShares.length; i++) {
            totalPool += market.totalShares[i];
        }
        return totalPool;
    }
    
    function getWinningSharesInfo(uint256 _marketId) 
        external view returns (
            uint256 winningShares,
            uint256 losingShares,
            uint256 rewardMultiplier // in basis points (10000 = 1x)
        ) {
        Market storage market = markets[_marketId];
        require(market.resolved, "Market not resolved yet");
        
        uint256 outcomeIndex = uint256(market.outcome) - 1;
        winningShares = market.totalShares[outcomeIndex];
        
        // Calculate total losing shares
        losingShares = 0;
        for (uint256 i = 0; i < market.totalShares.length; i++) {
            if (i != outcomeIndex) {
                losingShares += market.totalShares[i];
            }
        }
        
        // Calculate reward multiplier (how much winners get per token invested)
        if (winningShares > 0) {
            rewardMultiplier = 10000 + (losingShares * 10000) / winningShares;
        } else {
            rewardMultiplier = 10000;
        }
        
        return (winningShares, losingShares, rewardMultiplier);
    }
    
    // Check if the betting token supports EIP-2612 permit
    function supportsPermit() external view returns (bool) {
        try bettingTokenPermit.DOMAIN_SEPARATOR() returns (bytes32) {
            return true;
        } catch {
            return false;
        }
    }

    // Get permit domain separator for frontend use
    function getPermitDomainSeparator() external view returns (bytes32) {
        return bettingTokenPermit.DOMAIN_SEPARATOR();
    }

    // Get permit nonce for a user
    function getPermitNonce(address user) external view returns (uint256) {
        return bettingTokenPermit.nonces(user);
    }
}
