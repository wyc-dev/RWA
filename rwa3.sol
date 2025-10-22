// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
* @title Real World Asset - Real World Advertisement - Real World Attention
* @notice Decentralized platform for managing real-world ad positions as NFTs and dividend tokens
* @dev This contract implements ERC1155 for multi-token support, with NFTs for ad positions and FT for dividends. It handles rental, confirmation, freezing, and finishing of ad deals with fee distributions.
    * Service Flow / 服務流程
    * 1. Register Ad Position and Mint NFT / 登記廣告位置並鑄造 NFT
    *    Users submit ad details (e.g., price, dimensions, location), and the system mints a unique NFT representing the ad position, functioning as a digital identifier.
    *    用戶提交廣告詳情（如價格、尺寸、位置），系統鑄造一個獨特的 NFT 代表廣告位，充當數字標識符。
    * 2. Rent Ad / 出租廣告位
    *    The renter pays the agreed ETH price as a deposit, placing the ad position in a waiting confirmation state, awaiting the space owner's preparation for the renter's needs.
    *    租用人支付約定的 ETH 價格作為押金，將空間的狀態變成等待確認，等候空間擁有者準備好租用人的需求。
    * 3. Confirm Ad / 確認出租
    *    The owner or renter confirms within 24 hours, transitioning the ad position to active status and issuing 10% of the price in AD tokens as reward points, like a bonus for confirmation; if not confirmed within 24 hours, the owner can cancel the transaction.
    *    擁有者或租用人在 24 小時內確認，將廣告位轉為使用中狀態，並發放 10% 價格的 AD 代幣作為獎勵積分，類似給確認者的紅利；如果24小時內沒有確認則可以由擁有者取消交易。
    * 4. Freeze Ad / 凍結廣告
    *    The renter can pay 10% fee within 7 days to freeze the transaction, suspending the space operations, used in case of rental disputes where the platform acts as an arbitrator.
    *    租用人在 7 天內，可支付 10% 費用凍結交易，暫停空間操作，用於有租用糾紛的時候，平台將會出來作公證用。
    * 5. Unfreeze Ad / 解凍廣告
    *    Unfreezing can only be performed by the platform (contract holder), with the system distributing the remaining deposit (40% to owner, 40% to renter, 5% to platform), ending the transaction and clearing data, like canceling the space rental order and refunding partial amounts.
    *    只能夠由平台(此合約持有者)解凍，系統將會分配相應交易的剩餘押金（40% 給擁有者、40% 給租用人、5% 給平台），結束交易並清空資料，就是取消這個空間租用訂單並退回部分款項。
    * 6. Finish Ad / 結束廣告
    *    The owner or renter finishes the transaction within the time frame, distributing the deposit (90% to owner, 10% to platform), and clearing data, completing the lease settlement.
    *    擁有者或租用人在時間內結束交易，分配押金（90% 給擁有者、10% 給平台），清空資料，完成租約結算。
    * 7. Rate Ad / 評分廣告
    *    Other users rate the ad position (1-5 stars) to assist others in evaluating the space quality.
    *    其他用戶給廣告位打分（1-5 星），協助其他用戶評估空間的品質。
    * Overall Process / 整體過程:
    *    The entire process is about renting and selling space positions, with the system automatically handling funds and status, and reward ecosystem tokens encouraging participation.
    *    整個過程就是租售空間位置，系統自動處理資金和狀態，獎勵生態代幣鼓勵參與。
* @custom:security-contact hopeallgood.unadvised619@passinbox.com
*/

/**
* @dev Interface for the external AD ERC20 token
* @custom:security-contact hopeallgood.unadvised619@passinbox.com
*/
interface IAdDividend is IERC20 {
    /**
     * @dev Mints new AD tokens to the specified address
     * @param to The recipient address
     * @param amount The amount to mint
     */
    function mint(address to, uint256 amount) external;
}

contract RWA3 is ERC1155, Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;
    using Strings for uint256;

    /**
     * @dev Enum representing the status of an ad position
     */
    enum AdStatus { Waiting, Hosting, Freeze, Closed }

    /**
     * @dev Struct to store ad position details
     */
    struct Ad {
        uint256 adId;
        address spaceUser;
        address spaceOwner;
        AdStatus status;
        uint256 dealPrice; // In wei (ETH)
        uint256 dealTime; // Timestamp
        uint256 adLength;
        uint256 adWidth;
        uint256 adHeight; // Optional
        uint8 adRating; // Average 1-5
        uint8 adRateCount;
        string geography;
        string memo;
    }

    /**
     * @dev Counter for generating unique ad IDs
     */
    Counters.Counter private _adCounter;

    /**
     * @dev Mapping from ad ID to ad details
     */
    mapping(uint256 adId => Ad adDetails) public ads;

    /**
     * @dev Address to receive platform fees
     */
    address public adListFeeTo;

    /**
     * @dev The AD token contract address
     */
    IAdDividend public adToken;

    // Events
    /**
     * @dev Emitted when a new ad is created
     * @param adId The unique ID of the ad
     * @param spaceOwner The owner of the ad space
     * @param geography The geographic location of the ad
     */
    event AdCreated(uint256 indexed adId, address indexed spaceOwner, string geography);

    /**
     * @dev Emitted when an ad is edited
     * @param adId The ID of the ad
     * @param spaceOwner The owner editing the ad
     */
    event AdEdited(uint256 indexed adId, address indexed spaceOwner);

    /**
     * @dev Emitted when an ad is rented
     * @param adId The ID of the ad
     * @param renter The renter's address
     * @param dealPrice The price of the deal in wei
     */
    event AdRented(uint256 indexed adId, address indexed renter, uint256 dealPrice);

    /**
     * @dev Emitted when an ad rental is confirmed
     * @param adId The ID of the ad
     * @param confirmer The address confirming the deal
     * @param adAmount The amount of dividend tokens minted
     */
    event AdConfirmed(uint256 indexed adId, address indexed confirmer, uint256 adAmount);

    /**
     * @dev Emitted when an ad is frozen
     * @param adId The ID of the ad
     * @param freezer The address freezing the ad
     */
    event AdFrozen(uint256 indexed adId, address indexed freezer);

    /**
     * @dev Emitted when an ad is unfrozen
     * @param adId The ID of the ad
     * @param unfreezer The address unfreezing the ad
     */
    event AdUnfrozen(uint256 indexed adId, address indexed unfreezer);

    /**
     * @dev Emitted when an ad deal is finished
     * @param adId The ID of the ad
     * @param finisher The address finishing the deal
     */
    event AdFinished(uint256 indexed adId, address indexed finisher);

    /**
     * @dev Emitted when an ad is rated
     * @param adId The ID of the ad
     * @param rater The address rating the ad
     * @param rating The rating given (1-5)
     */
    event AdRated(uint256 indexed adId, address indexed rater, uint8 rating);

    /**
     * @dev Emitted when an ad's rental data is cleaned
     * @param adId The ID of the ad
     */
    event AdCleaned(uint256 indexed adId);

    /**
     * @dev Emitted when the fee address is updated
     * @param newFeeTo The new fee address
     */
    event FeeToUpdated(address indexed newFeeTo);

    /**
     * @dev Emitted when an ad ownership is transferred
     * @param adId The ID of the ad
     * @param from The previous owner
     * @param to The new owner
     */
    event AdOwnershipTransferred(uint256 indexed adId, address indexed from, address indexed to);

    /**
     * @dev Constant for the confirmation time window
     */
    uint256 public constant CONFIRM_WINDOW = 24 hours;

    /**
     * @dev Constant for the freeze time window
     */
    uint256 public constant FREEZE_WINDOW = 7 days;

    /**
     * @dev Constant for the platform fee percentage
     */
    uint256 public constant FEE_PERCENT = 10; // 10%

    /**
     * @dev Constant for the freeze fee percentage
     */
    uint256 public constant FREEZE_FEE_PERCENT = 10; // For freeze

    /**
     * @dev Constant for the unfreeze owner share percentage
     */
    uint256 public constant UNFREEZE_OWNER_SHARE = 40; // 40%

    /**
     * @dev Constant for the unfreeze renter share percentage
     */
    uint256 public constant UNFREEZE_RENTER_SHARE = 40; // 40%

    /**
     * @dev Constant for the unfreeze fee share percentage
     */
    uint256 public constant UNFREEZE_FEE_SHARE = 5; // 5%

    // Custom errors for gas efficiency
    error InvalidGeography();
    error InvalidInitialStatus();
    error IncorrectDeposit();
    error NotAuthorized();
    error TimeWindowExpired();
    error AlreadyRented();
    error InsufficientBalance();
    error InvalidRating();
    error CannotEditImmutable();
    error NotHosting();
    error FreezeWindowExpired();
    error NotAdOwner(); // For ERC1155 balance check
    error NotSpaceOwner();
    error NotAdRenter();
    error InvalidStatus();
    error TimeWindowNotExpired();
    error TransferFailed();

    /**
     * @dev Modifier to restrict access to the space owner of the ad
     * @param adId The ID of the ad
     */
    modifier onlySpaceOwner(uint256 adId) {
        if (balanceOf(_msgSender(), adId) != 1) revert NotAdOwner();
        if (ads[adId].spaceOwner != _msgSender()) revert NotSpaceOwner();
        _;
    }

    /**
     * @dev Modifier to restrict access to the ad renter
     * @param adId The ID of the ad
     */
    modifier onlySpaceUser(uint256 adId) {
        if (ads[adId].spaceUser != _msgSender()) revert NotAdRenter();
        _;
    }

    /**
     * @dev Modifier to check if the ad is in a specific status
     * @param adId The ID of the ad
     * @param requiredStatus The required status
     */
    modifier validStatus(uint256 adId, AdStatus requiredStatus) {
        if (uint8(ads[adId].status) != uint8(requiredStatus)) revert InvalidStatus();
        _;
    }

    /**
     * @dev Constructor to initialize the contract
     * @param _adTokenAddress The address of the pre-deployed AD ERC20 token
     */
    constructor(address _adTokenAddress) ERC1155("ipfs://Qm.../{id}.json") Ownable(_msgSender()) {
        adToken = IAdDividend(_adTokenAddress);
        adListFeeTo = _msgSender();
        emit FeeToUpdated(_msgSender());
    }

    /**
     * @dev Creates a new ad position NFT
     * @param _dealPrice The deal price in wei
     * @param _adLength The length of the ad position
     * @param _adWidth The width of the ad position
     * @param _adHeight The height of the ad position (optional)
     * @param _geography The geographic location
     * @param _memo Optional memo
     * @param _status Initial status (Waiting or Closed)
     */
    function createAd(
        uint256 _dealPrice,
        uint256 _adLength,
        uint256 _adWidth,
        uint256 _adHeight, // Optional, can be 0
        string memory _geography,
        string memory _memo, // Optional
        AdStatus _status // Only Waiting or Closed
    ) external {
        if (bytes(_geography).length == 0) revert InvalidGeography();
        if (_status != AdStatus.Waiting && _status != AdStatus.Closed) revert InvalidInitialStatus();
        if (_dealPrice == 0) revert IncorrectDeposit(); // Repurpose for zero price
        if (_adLength == 0 || _adWidth == 0) revert InvalidGeography(); // Repurpose for invalid dims

        uint256 adId = _adCounter.current();
        _adCounter.increment();

        ads[adId].adId = adId;
        ads[adId].spaceUser = address(0);
        ads[adId].spaceOwner = _msgSender();
        ads[adId].status = _status;
        ads[adId].dealPrice = _dealPrice;
        ads[adId].dealTime = 0;
        ads[adId].adLength = _adLength;
        ads[adId].adWidth = _adWidth;
        ads[adId].adHeight = _adHeight;
        ads[adId].adRating = 0;
        ads[adId].adRateCount = 0;
        ads[adId].geography = _geography;
        ads[adId].memo = _memo;

        _mint(_msgSender(), adId, 1, ""); // Mint NFT with supply 1
        emit AdCreated(adId, _msgSender(), _geography);
    }

    /**
     * @dev Edits an existing ad position
     * @param _adId The ID of the ad to edit
     * @param _dealPrice New deal price
     * @param _adLength New length
     * @param _adWidth New width
     * @param _adHeight New height (optional)
     * @param _geography New geography
     * @param _memo New memo
     * @param _status New status
     */
    function editAd(
        uint256 _adId,
        uint256 _dealPrice,
        uint256 _adLength,
        uint256 _adWidth,
        uint256 _adHeight,
        string memory _geography,
        string memory _memo,
        AdStatus _status
    ) external onlySpaceOwner(_adId) {
        Ad storage ad = ads[_adId];
        if (ad.status == AdStatus.Hosting || ad.status == AdStatus.Closed) revert CannotEditImmutable();

        ad.dealPrice = _dealPrice;
        ad.adLength = _adLength;
        ad.adWidth = _adWidth;
        ad.adHeight = _adHeight;
        ad.geography = _geography;
        ad.memo = _memo;
        ad.status = _status;

        emit AdEdited(_adId, _msgSender());
    }

    /**
     * @dev Returns the details of an ad
     * @param _adId The ID of the ad
     * @return Ad memory The ad details
     */
    function findAd(uint256 _adId) external view returns (Ad memory) {
        return ads[_adId];
    }

    /**
     * @dev Rents an ad position
     * @param _adId The ID of the ad to rent
     */
    function rentAd(uint256 _adId) external payable validStatus(_adId, AdStatus.Waiting) nonReentrant {
        Ad storage ad = ads[_adId];
        if (ad.spaceUser != address(0)) revert AlreadyRented();
        if (msg.value != ad.dealPrice) revert IncorrectDeposit();

        ad.spaceUser = _msgSender();
        ad.dealTime = block.timestamp;
        // Status remains Waiting

        emit AdRented(_adId, _msgSender(), ad.dealPrice);
    }

    /**
     * @dev Confirms an ad rental and mints dividend tokens
     * @param _adId The ID of the ad to confirm
     */
    function confirmAd(uint256 _adId) external nonReentrant {
        Ad storage ad = ads[_adId];
        if (ad.status != AdStatus.Waiting) revert NotHosting();
        if (ad.spaceOwner != _msgSender() && !(ad.spaceUser == _msgSender() && block.timestamp > ad.dealTime + CONFIRM_WINDOW)) {
            revert NotAuthorized();
        }

        // Simplified: 10% of dealPrice in AD units (assuming 1:1 wei to AD wei equivalence)
        uint256 adAmount = ad.dealPrice * FEE_PERCENT / 100;
        adToken.mint(ad.spaceUser, adAmount / 2); // Mint to renter
        adToken.mint(ad.spaceOwner, adAmount / 2); // Mint to owner

        ad.status = AdStatus.Hosting;
        ad.dealTime = block.timestamp;

        emit AdConfirmed(_adId, _msgSender(), adAmount);
    }

    /**
     * @dev Freezes an active ad rental
     * @param _adId The ID of the ad to freeze
     */
    function freezeAd(uint256 _adId) external payable onlySpaceUser(_adId) validStatus(_adId, AdStatus.Hosting) nonReentrant {
        Ad storage ad = ads[_adId];
        // withinTimeWindow uses revert, so call manually
        if (block.timestamp > ad.dealTime + FREEZE_WINDOW) revert FreezeWindowExpired();

        uint256 freezeFee = ad.dealPrice * FREEZE_FEE_PERCENT / 100;
        if (msg.value != freezeFee) revert IncorrectDeposit();

        (bool success, ) = payable(adListFeeTo).call{value: freezeFee}("");
        if (!success) revert TransferFailed();
        ad.status = AdStatus.Freeze;

        emit AdFrozen(_adId, _msgSender());
    }

    /**
     * @dev Unfreezes a frozen ad and distributes funds
     * @param _adId The ID of the ad to unfreeze
     */
    function unfreezeAd(uint256 _adId) external onlyOwner validStatus(_adId, AdStatus.Freeze) nonReentrant {
        Ad storage ad = ads[_adId];
        _unfreezeInternal(ad);
    }

    /**
     * @dev Internal function to handle unfreeze logic
     * @param ad The ad storage reference
     */
    function _unfreezeInternal(Ad storage ad) private {
        uint256 total = ad.dealPrice;
        if (address(this).balance < total) revert InsufficientBalance();

        uint256 ownerShare = total * UNFREEZE_OWNER_SHARE / 100;
        uint256 renterShare = total * UNFREEZE_RENTER_SHARE / 100;
        uint256 feeShare = total * UNFREEZE_FEE_SHARE / 100;
        // Remaining 15% stays in contract as per spec implication (penalty/platform reserve)

        (bool success1, ) = payable(ad.spaceOwner).call{value: ownerShare}("");
        if (!success1) revert TransferFailed();
        (bool success2, ) = payable(ad.spaceUser).call{value: renterShare}("");
        if (!success2) revert TransferFailed();
        (bool success3, ) = payable(adListFeeTo).call{value: feeShare}("");
        if (!success3) revert TransferFailed();

        ad.status = AdStatus.Closed;
        _cleanAd(ad);
        emit AdUnfrozen(ad.adId, _msgSender());
    }

    /**
     * @dev Finishes an active ad deal and distributes funds
     * @param _adId The ID of the ad to finish
     */
    function finishAd(uint256 _adId) external nonReentrant {
        Ad storage ad = ads[_adId];
        if (ad.status != AdStatus.Hosting) revert NotHosting(); // Only for Hosting; use unfreeze for Freeze

        bool isRenter = ad.spaceUser == _msgSender();
        bool withinWindow = block.timestamp <= ad.dealTime + CONFIRM_WINDOW;
        if (
            !(isRenter && withinWindow) &&
            !(ad.spaceOwner == _msgSender() && !withinWindow)
        ) {
            revert NotAuthorized();
        }

        uint256 total = ad.dealPrice;
        if (address(this).balance < total) revert InsufficientBalance();

        uint256 ownerShare = total * 90 / 100;
        uint256 feeShare = total * FEE_PERCENT / 100;

        (bool success1, ) = payable(ad.spaceOwner).call{value: ownerShare}("");
        if (!success1) revert TransferFailed();
        (bool success2, ) = payable(adListFeeTo).call{value: feeShare}("");
        if (!success2) revert TransferFailed();

        ad.status = AdStatus.Closed;
        _cleanAd(ad);

        emit AdFinished(ad.adId, _msgSender());
    }

    /**
     * @dev Internal function to clean ad rental data
     * @param ad The ad storage reference
     */
    function _cleanAd(Ad storage ad) private {
        ad.spaceUser = address(0);
        ad.dealTime = 0;
        ad.status = AdStatus.Waiting;
        emit AdCleaned(ad.adId);
    }

    /**
     * @dev Rates an ad position
     * @param _adId The ID of the ad to rate
     * @param _rating The rating (1-5)
     */
    function rateAd(uint256 _adId, uint8 _rating) external {
        if (_msgSender() == ads[_adId].spaceOwner) revert NotAuthorized(); // Owner cannot rate
        if (_rating < 1 || _rating > 5) revert InvalidRating();

        Ad storage ad = ads[_adId];
        if (ad.adRateCount == 0) {
            ad.adRating = _rating;
        } else {
            ad.adRating = uint8((uint16(ad.adRating * ad.adRateCount) + _rating) / (ad.adRateCount + 1));
        }
        ad.adRateCount++;

        emit AdRated(_adId, _msgSender(), _rating);
    }

    /**
     * @dev Transfers ownership of an ad NFT
     * @param _adId The ID of the ad
     * @param _newOwner The new owner address
     */
    function transferOwnership(uint256 _adId, address _newOwner) external onlySpaceOwner(_adId) {
        safeTransferFrom(_msgSender(), _newOwner, _adId, 1, "");
        ads[_adId].spaceOwner = _newOwner;
        emit AdOwnershipTransferred(_adId, _msgSender(), _newOwner);
    }

    /**
     * @dev Withdraws stuck funds (only contract owner)
     */
    function withdraw() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        (bool success, ) = payable(owner()).call{value: balance}("");
        if (!success) revert TransferFailed();
    }

    /**
     * @dev Updates the fee address (only contract owner)
     * @param _newFeeTo The new fee address
     */
    function updateFeeTo(address _newFeeTo) external onlyOwner {
        adListFeeTo = _newFeeTo;
        emit FeeToUpdated(_newFeeTo);
    }

    /**
     * @dev Checks if the contract supports an interface
     * @param interfaceId The interface ID
     * @return bool True if supported
     */
    function supportsInterface(bytes4 interfaceId) external view override(ERC1155) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
