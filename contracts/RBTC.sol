// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts@1.1.1/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts@1.1.1/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
// import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IERC20Extended is IERC20 {
    function burn(uint256 value) external;
}

contract Presale is ReentrancyGuard, VRFConsumerBaseV2Plus {

    struct Stage {
    uint8 stageNumber;
    uint256 stageSupply;
    uint256 supplySold;
    uint256 tokenPrice;
    uint256 minParticipationUSDT;
    uint256 winningPool;
    address winner;
}

struct RequestStatus {
    bool fulfilled; // whether the request has been successfully fulfilled
    bool exists; // whether a requestId exists
    uint256[] randomWords;
}

enum PaymentMethod {
    USDC,
    BNB,
    USDT
}

    uint8 private _currentStage;
    uint8 private _totalStages = 10;
    uint8 private _referralPercentage = 10; // 10%
    uint8 private _referrerPercentage = 5; // 5%
    uint256 private eligibleBuyersCounter;
    uint8 private constant PERCENTAGE_PRECISION = 100;
    uint64 private constant WEI_PRECISION = 1e18;
    uint40 private constant USD_PRECISION = 1e10;
    bool private _isTradingEnabled = false;
    bool private _isEmergencyPaused = false;
    
    // Aidrop
    uint256 private _airdropEndTime;

    // Your subscription ID.
    uint256 s_subscriptionId;
    // Depends on the number of requested values that you want sent to the
    // fulfillRandomWords() function. Storing each word costs about 20,000 gas,
    // so 100,000 is a safe default for this example contract. Test and adjust
    // this limit based on the network that you select, the size of the request,
    // and the processing of the callback request in the fulfillRandomWords()
    // function.
    uint32 callbackGasLimit = 1000000;

    // The default is 3, but you can set this higher.
    uint16 requestConfirmations = 3;

    // For this example, retrieve 2 random values in one request.
    // Cannot exceed VRFCoordinatorV2.MAX_NUM_WORDS.
    uint32 numWords = 1;

    // address private usdtAddress = 0x55d398326f99059fF775485246999027B3197955;
    address private usdtAddress = 0x3Bbf78eB227f243e9e308476fF7CA33eFcD015dc;
    address private usdcAddress = 0x130799d0F0DFA7206AA3B9c0D34daaEC51a9648E;
    // address private usdcAddress = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    // address private widCoinAddress = 0xb6CFc7b7aC28aad46773a9B1605e5992C61d8aDa;
    address private widCoinAddress = 0x8d2415C3736B775c33B23518025D89eAcB48eCEC;

    mapping(uint8 stage => mapping(uint256 index => address buyer)) private stageToIndexOfBuyerEligibleForPool;
    mapping(address buyer => bool hasMarkedEligible) private buyerToIsAlreadyEligible;
    mapping(uint8 stageNumber => Stage stage) private stageNumberToSpecs;
    mapping(address buyer  => uint256 purchasedTokens) private buyerToPurchasedTokens;
    mapping(address => uint256) private addressToRefferalTokens;
    mapping(uint256 => RequestStatus) private s_requests; /* requestId --> requestStatus */
    mapping(uint8 stage => mapping(address winner => bool hasClaimed)) private stageToHasWinnerClaimedPool;
    mapping(address => bool hasClaimedPresaleTokens) private addressToHasClaimedPresaleTokens;

    // AggregatorV3Interface private usdtPriceFeed = AggregatorV3Interface(0xB97Ad0E74fa7d920791E90258A6E2085088b4320);
    // AggregatorV3Interface private usdcPriceFeed = AggregatorV3Interface(0x51597f405303C4377E36123cBc172b13269EA163);
    // AggregatorV3Interface private bnbPriceFeed = AggregatorV3Interface(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE);
    AggregatorV3Interface private usdtPriceFeed =
        AggregatorV3Interface(0xEca2605f0BCF2BA5966372C99837b1F182d3D620); // testnet
    AggregatorV3Interface private usdcPriceFeed =
        AggregatorV3Interface(0x90c069C4538adAc136E051052E14c1cD799C41B7); // testnet
    AggregatorV3Interface private bnbPriceFeed = AggregatorV3Interface(0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526); // testnet

    // The gas lane to use, which specifies the maximum gas price to bump to.
    // For a list of available gas lanes on each network,
    // see https://docs.chain.link/docs/vrf/v2-5/supported-networks
    // bytes32 public keyHash = 0x8596b430971ac45bdf6088665b9ad8e8630c9d5049ab54b14dff711bee7c0e26; // 0x130dba50ad435d4ecc214aad0d5820474137bd68e7e77724144f27c3c377d3d4 BSC Mainnet
    bytes32 public keyHash = 0x130dba50ad435d4ecc214aad0d5820474137bd68e7e77724144f27c3c377d3d4;

    error Unauthorized();
    error InvalidWinner();
    error WinningPoolClaimedAlready();
    error PurchaseAmountShouldNotBeGreaterThanStageSupply();
    error PurchasePaymentUnsuccessfull();

    event BuyToken(
        address indexed buyer,
        uint256 amount,
        PaymentMethod paymentMethod
    );
    event NextStageLaunched(uint8 previousStage, uint8 newStage, address winner);
    event RequestSent(uint256 requestId, uint32 numWords);
    event RequestFulfilled(uint256 requestId, uint256[] randomWords);
    event TradingEnabled(uint256 startTime);
    event WinnerPoolClaimed(uint8 indexed stageNumber, address indexed winner, int256 winningPool);
    event AirdropOpened(uint256 indexed startTimestamp, uint256 endTimestamp);
    event BurnedWIDTokens(uint256 amount);

    /**
    COORDINATOR 0xd691f04bc0C9a24Edb78af9E005Cf85768F694C9 //BSC Mainnet
    COORDINATOR 0xDA3b641D438362C440Ac5458c57e00a712b66700 //BSC Testnet
    **/
    constructor(uint256 subscriptionId) VRFConsumerBaseV2Plus(0xDA3b641D438362C440Ac5458c57e00a712b66700)
    {
        uint96[10] memory stageAllocSupply = [
            50000000 ether,
            100000000 ether,
            200000000 ether,
            400000000 ether,
            800000000 ether,
            300000000 ether,
            400000000 ether,
            500000000 ether,
            600000000 ether,
            650000000 ether
        ];
        // uint64 [10] memory stageTokenPrice = [0.03 ether, 0.04 ether, 0.05 ether, 0.06 ether, 0.07  ether, 0.08 ether, 0.09 ether, 0.1 ether,  0.11 ether, 0.12 ether];
        uint24[10] memory stageTokenPrice = [
            // USD
            3000000,
            4000000,
            5000000,
            6000000,
            7000000,
            8000000,
            9000000,
            10000000,
            11000000,
            12000000
        ]; // ^8 dec
        uint40[10] memory minParticipation = [
            // USD
            15000000000,
            25000000000,
            40000000000,
            65000000000,
            100000000000,
            130000000000,
            160000000000,
            200000000000,
            300000000000,
            500000000000
        ];

        uint48[10] memory winningPool = [
            // USD
            2000000000000,
            4500000000000,
            6500000000000,
            8000000000000,
            10000000000000,
            11000000000000,
            13000000000000,
            15000000000000,
            30000000000000,
            50000000000000
        ];
        for (uint8 index = 0; index < _totalStages; index++) {
            stageNumberToSpecs[index + 1] = Stage(
                index + 1,
                stageAllocSupply[index],
                0,
                stageTokenPrice[index],
                minParticipation[index],
                winningPool[index],
                address(0)
            );
        }
        _currentStage = 1;
        s_subscriptionId = subscriptionId;
    }

    function buyToken(
        uint256 amount,
        PaymentMethod mode,
        address referral
    ) public payable nonReentrant notEmergencyPaused {
        uint256 initAmount = amount;
        address contract_address = address(this);
        if(block.timestamp < _airdropEndTime) {
            amount = amount*2; // x2
        }
        Stage storage stageSpecs = stageNumberToSpecs[_currentStage];
        uint256 remainingSupply = stageSpecs.stageSupply-stageSpecs.supplySold;
        if(amount > remainingSupply){
            amount = remainingSupply;
        }
        uint256 payableAmount = calculateTotalTokensCost(initAmount, mode);
        if(mode == PaymentMethod.BNB){
            require(msg.value >= payableAmount,"InvalidFundsSentFromBuyer");
        } else {
        address payableToken = mode == PaymentMethod.USDC?usdcAddress:usdtAddress;
            IERC20(payableToken).transferFrom(
                msg.sender,
                contract_address,
                payableAmount
            );
        }
        if (referral != address(0) && msg.sender!=referral) {
            uint256 refferalTokensAmount = (amount * _referralPercentage) /
                PERCENTAGE_PRECISION;
            uint256 referrerTokensAmount = (amount * _referrerPercentage) /
                PERCENTAGE_PRECISION;
            addressToRefferalTokens[referral] += refferalTokensAmount;
            addressToRefferalTokens[msg.sender] += referrerTokensAmount;
            stageSpecs.supplySold+=(refferalTokensAmount+_referrerPercentage);
        }
        buyerToPurchasedTokens[msg.sender] += amount;
        uint8 stageNumber = stageSpecs.stageNumber;
        uint256 userTotalTokens = buyerToPurchasedTokens[msg.sender] +
            addressToRefferalTokens[msg.sender];
        if(userTotalTokens>0){
        uint256 userTokensValueUSD = (userTotalTokens * stageSpecs.tokenPrice) /
            1e18; // 8 dec -> 1e8
        if (userTokensValueUSD >= stageSpecs.minParticipationUSDT && !buyerToIsAlreadyEligible[msg.sender]) {
            stageToIndexOfBuyerEligibleForPool[stageNumber][eligibleBuyersCounter++] = msg.sender;
            buyerToIsAlreadyEligible[msg.sender] = true;
        }
        }
        // Stage check
        stageSpecs.supplySold += amount;
        if (
            _currentStage < _totalStages &&
            stageSpecs.supplySold == stageSpecs.stageSupply
        ) {
            requestRandomWords(false);
        }
        emit BuyToken(msg.sender, amount, mode);
    }

    function claimTokens() external nonReentrant notEmergencyPaused {
        require(_isTradingEnabled, "Err: Trading not enabled.");
        uint256 userBalance = buyerToPurchasedTokens[msg.sender]+addressToRefferalTokens[msg.sender];
        IERC20Extended(widCoinAddress).transfer(msg.sender, userBalance);
    }

    function claimWinnerPool(uint8 stageNumber) external nonReentrant onlyStageWinner(stageNumber) notEmergencyPaused {
        address winner = payable(msg.sender);
        if(stageToHasWinnerClaimedPool[stageNumber][winner]) revert WinningPoolClaimedAlready();
        Stage memory stage = stageNumberToSpecs[stageNumber];
        int256 winningPool = int256(stage.winningPool); // $$$
        int256 winningPoolDec = winningPool * int40(USD_PRECISION);  // 18 dec
        // Send the winning pool to the winner in BNB, USDC, and USDT, available in the contract.
        int256 contractUSDTBalance = int256(IERC20(usdtAddress).balanceOf(address(this)));
        int256 USDT_USD = getLatestPrice(PaymentMethod.USDT);
        int256 contractTotalUSDTBalanceInUSD = (contractUSDTBalance * USDT_USD)/1e8;  // 18 dec
        // int256 remainingPoolToPayUSDC = winningPoolDec - contractTotalUSDTBalanceInUSD;
        int256 remainingPoolToPay = winningPoolDec - contractTotalUSDTBalanceInUSD;
        if(remainingPoolToPay <= 0 ){
            IERC20(usdtAddress).transfer(winner, uint256(winningPoolDec));  // distribute all in USDT
        } else { 
            IERC20(usdtAddress).transfer(winner, uint256(contractUSDTBalance));
            int256 contractBNBBalance = int256(address(this).balance);
            int256 BNB_USD = getLatestPrice(PaymentMethod.BNB);
            int256 contractTotalBNBBalanceInUSD = (contractBNBBalance * BNB_USD)/1e8;  // 18 dec
            remainingPoolToPay -= contractTotalBNBBalanceInUSD;
            if(remainingPoolToPay <= 0){
                (bool success, ) = winner.call{value:uint256(remainingPoolToPay * 1e8 / BNB_USD)}('');
                if(!success) revert PurchasePaymentUnsuccessfull();
            } else {
                (bool success, ) = winner.call{value:uint256(contractBNBBalance)}('');
                if(!success) revert PurchasePaymentUnsuccessfull();
                int256 contractUSDCBalance = int256(IERC20(usdcAddress).balanceOf(address(this)));
                int256 USDC_USD = getLatestPrice(PaymentMethod.USDC);
                int256 contractTotalUSDCBalanceInUSD = (contractUSDCBalance * USDC_USD)/1e8;  // 18 dec
                int256 remainingPoolToPayUSDC = remainingPoolToPay - contractTotalUSDCBalanceInUSD;
                // IERC20(usdcAddress).transfer(msg.sender, uint256(remainingPoolToPayUSDC));
                if (remainingPoolToPayUSDC <= 0) {
                    IERC20(usdcAddress).transfer(msg.sender, uint256(remainingPoolToPay * 1e8 / USDC_USD)); // Send remaining in USDC
                } else {
                    // Send all available USDC
                    IERC20(usdcAddress).transfer(msg.sender, uint256(contractUSDCBalance));
                }
            }
        }
        stageToHasWinnerClaimedPool[stageNumber][winner] = true;
        emit WinnerPoolClaimed(_currentStage, winner, winningPool);
    }

    // admin functions

    function enableTrading() external nonReentrant onlyOwner{
        _isTradingEnabled = true;
        emit TradingEnabled(block.timestamp);
    }

    // Temporary pause the presale
    function pausePresale() external nonReentrant onlyOwner{
        _isEmergencyPaused = true;
    }

    function enableAirdrop(uint256 endTime) external nonReentrant onlyOwner{
        require(endTime > block.timestamp, "Airdrop end time should be in future");
        _airdropEndTime = endTime;
        emit AirdropOpened(block.timestamp, endTime);
    }

    function withdrawAdminFunds(uint256 amount, PaymentMethod mode) external nonReentrant onlyOwner {
        address payable owner = payable(owner());
        if(mode == PaymentMethod.USDC){
            IERC20(usdcAddress).transfer(owner, amount);
        } else {
            IERC20(usdtAddress).transfer(owner, amount);
        }
    }

    // End/Finish the presale in case of no sale of tokens.
    function endPresale() external nonReentrant onlyOwner {
        uint256 totalSupplySold;
        for (uint8 i = 1; i<=_currentStage; i++) 
        {
            Stage memory stage = stageNumberToSpecs[i];
            totalSupplySold +=stage.supplySold;
        }
        uint256 contractWIDBalance = IERC20Extended(widCoinAddress).balanceOf(address(this));
        uint256 supplyToBurn = contractWIDBalance - totalSupplySold;
        IERC20Extended(widCoinAddress).burn(supplyToBurn);
        emit BurnedWIDTokens(supplyToBurn);
    }

    function setUSDTPriceFeed(address _priceFeed) external onlyOwner {
        usdtPriceFeed = AggregatorV3Interface(_priceFeed);
    }

    function setUSDCPriceFeed(address _priceFeed) external onlyOwner {
        usdcPriceFeed = AggregatorV3Interface(_priceFeed);
    }

    function setBNBPriceFeed(address _priceFeed) external onlyOwner {
        bnbPriceFeed = AggregatorV3Interface(_priceFeed);
    }

    // modifiers

    modifier notEmergencyPaused () {
        require(!_isEmergencyPaused, "Presale is temporarily paused!");
        _;
    }

    modifier onlyStageWinner(uint8 stageNumber) {
        Stage memory stage = stageNumberToSpecs[stageNumber];
        if(msg.sender!=stage.winner) revert InvalidWinner();
        _;
    }

    // internal - private functions

    function calculateTotalTokensCost(
        uint256 token_amount,
        PaymentMethod mode
    ) public view returns (uint256) {
        uint256 currencyLatestPrice = uint256(getLatestPrice(mode));
        Stage memory currentStageSpecs = getStageSpecs(_currentStage);
        uint256 token_price_usd = currentStageSpecs.tokenPrice; // ^18 dec
        uint256 totalCost = (token_price_usd * token_amount) /
            currencyLatestPrice; // token amount in 18 decimals
        return totalCost; // in 18 decimals
    }

    function getPriceFeed(
        PaymentMethod mode
    ) internal view returns (AggregatorV3Interface) {
        if (mode == PaymentMethod.USDC) {
            return usdcPriceFeed;
        } else if (mode == PaymentMethod.USDT) {
            return usdtPriceFeed;
        } else {
            return bnbPriceFeed;
        }
    }

    // Assumes the subscription is funded sufficiently.
    // @param enableNativePayment: Set to `true` to enable payment in native tokens, or
    // `false` to pay in LINK
    function requestRandomWords(
        bool enableNativePayment
    ) internal returns (uint256 requestId) {
        // Will revert if subscription is not set and funded.
        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: s_subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({
                        nativePayment: enableNativePayment
                    })
                )
            })
        );
        s_requests[requestId] = RequestStatus({
            randomWords: new uint256[](0),
            exists: true,
            fulfilled: false
        });
        emit RequestSent(requestId, numWords);
        return requestId;
    }

    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] calldata _randomWords
    ) internal override {
        require(s_requests[_requestId].exists, "request not found");
        s_requests[_requestId].fulfilled = true;
        s_requests[_requestId].randomWords = _randomWords;
        Stage storage stageSpecs = stageNumberToSpecs[_currentStage];
        uint256 index = _randomWords[0]%eligibleBuyersCounter;
        address winner = stageToIndexOfBuyerEligibleForPool[stageSpecs.stageNumber][index];
        stageSpecs.winner = winner;
        emit NextStageLaunched(_currentStage, ++_currentStage, winner);
        emit RequestFulfilled(_requestId, _randomWords);
    }

    // public view functions

    function getLatestPrice(PaymentMethod mode) public view returns (int) {
        AggregatorV3Interface priceFeed = getPriceFeed(mode);
        (
            /** uint80 roundID **/, 
            int price, 
            /** uint startedAt **/,
            /** uint timeStamp **/,
            /** uint80 answeredInRound **/
        ) = priceFeed.latestRoundData();
        return price;
    }

    function getRequestStatus(
        uint256 _requestId
    ) internal view returns (bool fulfilled, uint256[] memory randomWords) {
        require(s_requests[_requestId].exists, "request not found");
        RequestStatus memory request = s_requests[_requestId];
        return (request.fulfilled, request.randomWords);
    }

    function getStageSpecs(
        uint8 stageNumber
    ) public view returns (Stage memory) {
        return stageNumberToSpecs[stageNumber];
    }

    function currentStage() public view returns (uint8) {
        return _currentStage;
    }

    function totalStages() public view returns (uint8) {
        return _totalStages;
    }

    function usdtTokenAddress() public view returns (address) {
        return usdtAddress;
    }

    function purchasedTokens(address user) public view returns (uint256) {
        return buyerToPurchasedTokens[user];
    }

    function hasClaimedPresaleTokens(address user) public view returns (bool) {
        return addressToHasClaimedPresaleTokens[user];
    }

    /**
    Returns the number of total users eligible for the winning pool.
     */
    function totalEligibleUsersForWinningPool()
        public
        view
        returns (uint256)
    {
        return eligibleBuyersCounter;
    }

    function refferalTokens(address user) public view returns (uint256) {
        return addressToRefferalTokens[user];
    }

    function stageToPoolClaimedByWinner(uint8 stageNumber, address winner) public view returns (bool) {
        return stageToHasWinnerClaimedPool[stageNumber][winner];
    }

    function referralPercentage() public view returns (uint8) {
        return _referralPercentage;
    }

    function referrerPercentage() public view returns (uint8) {
        return _referrerPercentage;
    }

    function isTradingEnabled() public view returns (bool) {
        return _isTradingEnabled;
    }

    function airdropEndTime() public view returns (uint256) {
        return _airdropEndTime;
    }

    function isAirdropOpen() public view returns (bool) {
        return block.timestamp < _airdropEndTime ? true : false;
    }
}