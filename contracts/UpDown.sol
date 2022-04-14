//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "./IRandomGenerator.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract UpDown is ReentrancyGuard, Pausable{
    using SafeERC20 for IERC20;
    /// *** Constants section

    struct Round {
        uint256 id;
        uint256 epoch;
        uint256 startTime;
        uint256 totalBetAmount;
        uint256 totalRewardAmount;
        uint256 totalTreasuryCollections;
        address user;
        uint8 betMask;
        uint8 winningNumber;
    }

    struct RoundDetailsById{
        address user;
        uint256 epoch;
    }

    // user + epoch => Round
    mapping(address => mapping(uint256 => Round)) public rounds;

    // id => Epoch + User
    mapping(uint256 => RoundDetailsById) public roundDetailsById;
    mapping(address => uint256) public currentUserEpoch;
    uint256 public currentRoundId = 0;
    // Each bet is deducted 1.5% in favour of the house, but no less than some minimum.
    // The lower bound is dictated by gas costs of the settleBet transaction, providing
    // headroom for up to 10 Gwei prices.
    uint256 constant HOUSE_EDGE_THOUSANDTHS = 15;
    uint256 constant HOUSE_EDGE_MINIMUM_AMOUNT = 0.0003 ether;
    uint256 constant MAX_MODULO = 100;
    uint256 constant public MAX_BET_MASK = 80;
    IRandomGenerator randomGenerator;
    IERC20 token;
    uint256 public randomRoundId;
    // Standard contract ownership transfer.
    address payable public owner;
    uint256 public minBetAmount = 1 * 10 ** 17;
    uint256 public maxBetAmount = 1000 * 10 ** 18;
    uint256 public currentTreasuryCollection = 0;

    // Events that are issued to make statistic recovery easier.
    event FailedPayment(address indexed beneficiary, uint256 amount);
    event Payment(address indexed beneficiary, uint256 amount);
    event ReferralPayment(address indexed beneficiary, uint256 amount);
    event Number(uint8 number);
    event Rounds(
        uint256 id,
        uint256 epoch,
        uint256 prevRoundIdForUser,
        address user,
        uint256 betAmt,
        uint8 betMask,
        uint8 winningNumber
    );
    event RewardCalculated(
        uint256 rewardAmt,
        uint256 treasuryCollections
    );

    // Constructor. Deliberately does not take any parameters.
    constructor() {
        owner = payable(msg.sender);
        token = IERC20(0xce746F6E5E99d9EE3457d1dcE5F69F4E27c12BD4);
        randomGenerator = IRandomGenerator(0xe5e59A851406A2B61B4C3142c89F3E12623340E1);
    }

 

    // Standard modifier on methods invokable only by contract owner.
    modifier onlyOwner() {
        require(msg.sender == owner, "OnlyOwner methods called by non-owner.");
        _;
    }

    function changeOwner(address payable _owner) external onlyOwner() {
        owner = _owner;
    }

    function setRandomGenerator(address _randomGenerator) external onlyOwner{
        randomGenerator = IRandomGenerator(_randomGenerator);
    }


    function setTokenToBet(address _token) external onlyOwner{
        token = IERC20(_token);
    }

    function setMinBetAmount(uint256 _minBetAmt) external onlyOwner{
        minBetAmount = _minBetAmt;
    }

    function setMaxBetAmount(uint256 _maxBetAmt) external onlyOwner{
        maxBetAmount = _maxBetAmt;
    }

    function getTokenAdd() external view returns(address){
        return address(token);
    }

    function getRandomGeneratorAdd() external view returns(address){
        return address(randomGenerator);
    }

    function pause() external onlyOwner{
        _pause();
    }

    function unpause() external onlyOwner{
        _unpause();
    }


    receive() external payable {}

    
    // Funds withdrawal to cover costs of dice2.win operation.
    function withdrawFunds(
        address payable beneficiary, 
        uint256 withdrawAmount
        )
        external
        onlyOwner()
    {
        require(
            withdrawAmount <= token.balanceOf(address(this)),
            "amount larger than balance."
        );
        sendFunds(beneficiary, withdrawAmount);
    }

    function collectTreasury() external onlyOwner{
        uint256 treasuryCollections = currentTreasuryCollection;
        currentTreasuryCollection = 0;
        sendFunds(owner, treasuryCollections);
    }

    // Bet placing transaction - issued by the player.
    //  betMask         - bet outcomes bit mask for modulo <= MAX_MASK_MODULO,
    //                    [0, betMask) for larger modulos.
    //  modulo          - game modulo.
    function placeBet(
        uint8 betMask,
        uint256 amount
    ) external nonReentrant whenNotPaused{

        require(
            betMask > 0 && betMask < MAX_BET_MASK,
            "Mask should be within range."
        );

        require(msg.sender == tx.origin);

        require(
            amount >= minBetAmount,
            "amount smaller than minimum bet amount."
        );
        require(
            amount <= maxBetAmount,
            "amount greater than maximum bet amount."
        );

        require(
            amount <= token.balanceOf(msg.sender),
            "amount larger than balance."
        );
        
        // Validate input data ranges.
        token.safeTransferFrom(msg.sender, address(this), amount);

        (uint256 roundId, uint256 diceNum,) =
            randomGenerator.latestRoundData(101);
        
        require(
            roundId > randomRoundId, 
            "RoundId should be greater than randomRoundId"
            );

        randomRoundId = roundId;

        emit Number(uint8(diceNum));


        currentRoundId = currentRoundId + 1;
        currentUserEpoch[msg.sender] = currentUserEpoch[msg.sender] + 1;
        
        roundDetailsById[currentRoundId] = RoundDetailsById(
            msg.sender, 
            currentUserEpoch[msg.sender]
            );

        rounds[msg.sender][currentUserEpoch[msg.sender]] = Round(
            currentRoundId,
            currentUserEpoch[msg.sender],
            block.timestamp,
            amount,
            0,
            0,
            msg.sender,
            betMask,
            uint8(diceNum)
        );

        uint256 prevRoundIdForUser = 0;
        if(currentUserEpoch[msg.sender] > 1){
            prevRoundIdForUser = rounds[msg.sender][currentUserEpoch[msg.sender] - 1].id;
        }


        uint256 diceWinAmount = getDiceWinAmount(amount, betMask, uint8(diceNum));

        // Send the funds to gambler.
        if(diceWinAmount != 0){
            sendFunds(msg.sender, diceWinAmount);
        }

        emit Rounds(
            currentRoundId, 
            currentUserEpoch[msg.sender], 
            prevRoundIdForUser, 
            msg.sender, 
            amount, 
            betMask, 
            uint8(diceNum)
            );
    }

    // Get the expected win amount after house edge is subtracted.
    function getDiceWinAmount(
        uint256 amount,
        uint256 rollUnder,
        uint8 diceNum
    ) private returns (uint256) {
        require(
            rollUnder > 0 && rollUnder <= 100,
            "Win probability out of range."
        );

        if(diceNum < rollUnder){
            Round storage round = rounds[msg.sender][currentUserEpoch[msg.sender]];
            uint256 houseEdge = (amount * HOUSE_EDGE_THOUSANDTHS) / 1000;
            if (houseEdge < HOUSE_EDGE_MINIMUM_AMOUNT) {
                houseEdge = HOUSE_EDGE_MINIMUM_AMOUNT;
            }
            require(houseEdge <= amount, "Bet doesn't even cover house edge.");
            uint256 winAmount = (amount  * 100) / rollUnder - houseEdge;

            round.totalTreasuryCollections += houseEdge;
            round.totalRewardAmount += winAmount;
            currentTreasuryCollection += houseEdge;
            emit RewardCalculated(winAmount, houseEdge);
            return winAmount;    
        }
        else {
            Round storage round = rounds[msg.sender][currentUserEpoch[msg.sender]];
            round.totalTreasuryCollections += amount;
            round.totalRewardAmount += 0;
            currentTreasuryCollection += amount;
            emit RewardCalculated(0, amount);
            return 0;
        }
    }

    // Helper routine to process the payment.
    function sendFunds(
        address beneficiary,
        uint256 amount
    ) private {
        if (amount > 0) {
            token.safeTransfer(beneficiary, amount);
                emit Payment(beneficiary, amount);
        } else {
            emit Payment(beneficiary, 0);
        }
    }

    //If someone accidently sends tokens or native currency to this contract
    function withdrawAllTokens(address _token) external onlyOwner{
        uint256 bal = IERC20(_token).balanceOf(address(this));
        withdrawToken(_token, bal);
    }
    
    function withdrawToken(address _token, uint256 amount) public virtual onlyOwner{
        uint256 bal = IERC20(_token).balanceOf(address(this));
        require(bal >= amount, "balanace of token in contract too low");
        IERC20(_token).safeTransfer(owner, amount);
    }

    function withdrawAllNative() external onlyOwner{
        uint256 bal = address(this).balance;
        withdrawNative(bal);
    } 

    function withdrawNative(uint256 amount) public virtual onlyOwner{
        uint256 bal = address(this).balance;
        require(bal >= amount, "balanace of native token in contract too low");
        (bool sent, ) = owner.call{value: amount}("");
        require(sent, "Failure in native token transfer");
    }
    
}
                  
