// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

error ITEM_DOES_NOT_EXIST();
error LISTING_NOT_ACTIVE();
error INSUFFICIENT_FUND();
error NOT_BUYER();
error UNAUTHORIZED();
error EXACT_AMOUNT_REQUIRED();
error ZERO_QUANTITY();
error ZERO_PRICE();
error PENDING_PURCHASES_EXIST();
error TRANSFER_FAILED();
error INVALID_PURCHASE_ID();
error ALREADY_CONFIRMED();
error TIMEOUT_NOT_REACHED();
error INVALID_PAYMENT_METHOD();
error UNSUPPORTED_TOKEN();
error DIRECT_ETH_NOT_ACCEPTED();

contract Market is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;
    
    uint256 public constant FEE_BPS = 100; // 1% platform fee
    uint256 public constant TIMEOUT_DURATION = 30 days;
    
    // address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // Mainnet USDT
    address public immutable USDT;
    address public constant ETH_ADDRESS = address(0);
    
    uint256 private listingCount = 1;
    uint256 private purchaseCount = 1;

    enum Status {
        ACTIVE,
        INACTIVE
    }

    enum PaymentMethod {
        ETH,
        USDT
    }

    struct Listing {
        address seller;
        uint256 priceETH;
        uint256 priceUSDT;
        uint256 quantity;
        string metadata;
        Status status;
        uint256 createdAt;
        bool acceptsETH;
        bool acceptsUSDT;
    }

    struct Purchase {
        uint256 listingId;
        address buyer;
        address seller;
        uint256 quantity;
        uint256 paidAmount;
        PaymentMethod paymentMethod;
        bool confirmed;
        uint256 createdAt;
    }

    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Purchase) public purchases;
    mapping(address => uint256[]) public sellerListings;
    mapping(address => uint256[]) public buyerPurchases;
    mapping(uint256 => uint256[]) public listingPurchases;
    mapping(uint256 => uint256) public pendingPurchaseCount;
    mapping(address => uint256) public sellerETHBalances;
    mapping(address => uint256) public sellerUSDTBalances;
    
    uint256 public platformETHFees;
    uint256 public platformUSDTFees;

    event ListingCreated(
        uint256 indexed listingId, 
        address indexed seller, 
        uint256 priceETH, 
        uint256 priceUSDT,
        uint256 quantity,
        bool acceptsETH,
        bool acceptsUSDT
    );
    event ListingUpdated(uint256 indexed listingId, address indexed seller, string updateType);
    event ListingDeleted(uint256 indexed listingId, address indexed seller);
    event ItemPurchased(
        uint256 indexed listingId, 
        address indexed buyer, 
        uint256 purchaseId, 
        uint256 quantity,
        uint256 amount,
        PaymentMethod paymentMethod
    );
    event DeliveryConfirmed(
        uint256 indexed listingId, 
        address indexed buyer, 
        address indexed seller, 
        uint256 purchaseId,
        PaymentMethod paymentMethod
    );
    event TimeoutClaim(
        uint256 indexed purchaseId, 
        address indexed seller, 
        uint256 amount,
        PaymentMethod paymentMethod
    );
    event EarningsWithdrawn(address indexed seller, uint256 ethAmount, uint256 usdtAmount);
    event FeesWithdrawn(address indexed owner, uint256 ethAmount, uint256 usdtAmount);

    modifier validListingId(uint256 _listingId) {
        if (_listingId >= listingCount || _listingId == 0 || listings[_listingId].seller == address(0)) {
            revert ITEM_DOES_NOT_EXIST();
        }
        _;
    }

    modifier onlySeller(uint256 _listingId) {
        if (listings[_listingId].seller != msg.sender) revert UNAUTHORIZED();
        _;
    }

    modifier validPurchaseId(uint256 _purchaseId) {
        if (_purchaseId >= purchaseCount || _purchaseId == 0) revert INVALID_PURCHASE_ID();
        _;
    }

    constructor(address _usdt) Ownable(msg.sender) {
      USDT = _usdt;
    }

    receive() external payable {
        revert DIRECT_ETH_NOT_ACCEPTED();
    }

    /**
     * @dev Create a new listing with ETH and/or USDT pricing
     * @param _priceETH Price in ETH (wei, 18 decimals)
     * @param _priceUSDT Price in USDT (6 decimals)
     * @param _quantity Available quantity
     * @param _metadata Listing metadata
     * @param _acceptsETH Whether listing accepts ETH payments
     * @param _acceptsUSDT Whether listing accepts USDT payments
     */
    function createListing(
        uint256 _priceETH,
        uint256 _priceUSDT,
        uint256 _quantity,
        string memory _metadata,
        bool _acceptsETH,
        bool _acceptsUSDT
    ) external whenNotPaused {
        if (_quantity == 0) revert ZERO_QUANTITY();
        if (!_acceptsETH && !_acceptsUSDT) revert INVALID_PAYMENT_METHOD();
        if (_acceptsETH && _priceETH == 0) revert ZERO_PRICE();
        if (_acceptsUSDT && _priceUSDT == 0) revert ZERO_PRICE();
        
        uint256 newId = listingCount;
        listings[newId] = Listing({
            seller: msg.sender,
            priceETH: _priceETH,
            priceUSDT: _priceUSDT,
            quantity: _quantity,
            metadata: _metadata,
            status: Status.ACTIVE,
            createdAt: block.timestamp,
            acceptsETH: _acceptsETH,
            acceptsUSDT: _acceptsUSDT
        });
        
        sellerListings[msg.sender].push(newId);
        emit ListingCreated(newId, msg.sender, _priceETH, _priceUSDT, _quantity, _acceptsETH, _acceptsUSDT);
        listingCount++;
    }

    /**
     * @dev Update listing details
     */
    function updateListing(
      uint256 _listingId,
      uint256 _priceETH,
      uint256 _priceUSDT,
      uint256 _quantity,
      string memory _metadata,
      bool _acceptsETH,
      bool _acceptsUSDT
    ) external onlySeller(_listingId) validListingId(_listingId) whenNotPaused {
      if (!_acceptsETH && !_acceptsUSDT) revert INVALID_PAYMENT_METHOD();
      if (_acceptsETH && _priceETH == 0) revert ZERO_PRICE();
      if (_acceptsUSDT && _priceUSDT == 0) revert ZERO_PRICE();
      
      Listing storage listing = listings[_listingId];
      listing.priceETH = _priceETH;
      listing.priceUSDT = _priceUSDT;
      listing.quantity = _quantity;
      listing.metadata = _metadata;
      listing.acceptsETH = _acceptsETH;
      listing.acceptsUSDT = _acceptsUSDT;
      
      if (_quantity == 0) {
        listing.status = Status.INACTIVE;
      }
      
      emit ListingUpdated(_listingId, msg.sender, "details");
    }

    /**
     * @dev Update listing status
     */
    function updateListingStatus(
      uint256 _listingId,
      Status _status
    ) external onlySeller(_listingId) validListingId(_listingId) whenNotPaused {
      Listing storage listing = listings[_listingId];
      
      if (_status == Status.ACTIVE && listing.quantity == 0) {
          revert ZERO_QUANTITY();
      }
      
      listing.status = _status;
      emit ListingUpdated(_listingId, msg.sender, "status");
    }

    /**
     * @dev Delete a listing (only if no pending purchases)
     */
    function deleteListing(uint256 _listingId)
      external
      onlySeller(_listingId)
      validListingId(_listingId)
      whenNotPaused
    {
      if (pendingPurchaseCount[_listingId] > 0) revert PENDING_PURCHASES_EXIST();
      
      delete listings[_listingId];
      _removeListingId(msg.sender, _listingId);
      emit ListingDeleted(_listingId, msg.sender);
    }

    /**
     * @dev Purchase item with ETH
     */
    function purchaseItemWithETH(uint256 _listingId, uint256 _quantity)
      external
      payable
      validListingId(_listingId)
      whenNotPaused
      nonReentrant
    {
      Listing storage listing = listings[_listingId];
      if (listing.status != Status.ACTIVE) revert LISTING_NOT_ACTIVE();
      if (!listing.acceptsETH) revert INVALID_PAYMENT_METHOD();
      if (_quantity == 0 || _quantity > listing.quantity) revert ZERO_QUANTITY();
      
      uint256 totalCost = listing.priceETH * _quantity;
      if (msg.value != totalCost) revert EXACT_AMOUNT_REQUIRED();

      _processPurchase(_listingId, _quantity, totalCost, PaymentMethod.ETH);
    }

    /**
     * @dev Purchase item with USDT
     */
    function purchaseItemWithUSDT(uint256 _listingId, uint256 _quantity)
      external
      validListingId(_listingId)
      whenNotPaused
      nonReentrant
    {
      Listing storage listing = listings[_listingId];
      if (listing.status != Status.ACTIVE) revert LISTING_NOT_ACTIVE();
      if (!listing.acceptsUSDT) revert INVALID_PAYMENT_METHOD();
      if (_quantity == 0 || _quantity > listing.quantity) revert ZERO_QUANTITY();
      
      uint256 totalCost = listing.priceUSDT * _quantity;
      
      // Transfer USDT from buyer to contract
      IERC20(USDT).safeTransferFrom(msg.sender, address(this), totalCost);
      
      _processPurchase(_listingId, _quantity, totalCost, PaymentMethod.USDT);
    }

    /**
     * @dev Internal function to process purchase
     */
    function _processPurchase(
      uint256 _listingId,
      uint256 _quantity,
      uint256 _totalCost,
      PaymentMethod _paymentMethod
    ) internal {
      Listing storage listing = listings[_listingId];
      
      listing.quantity -= _quantity;
      if (listing.quantity == 0) {
          listing.status = Status.INACTIVE;
      }

      uint256 newPurchaseId = purchaseCount;
      purchases[newPurchaseId] = Purchase({
          listingId: _listingId,
          buyer: msg.sender,
          seller: listing.seller,
          quantity: _quantity,
          paidAmount: _totalCost,
          paymentMethod: _paymentMethod,
          confirmed: false,
          createdAt: block.timestamp
      });
      
      buyerPurchases[msg.sender].push(newPurchaseId);
      listingPurchases[_listingId].push(newPurchaseId);
      pendingPurchaseCount[_listingId]++;
      
      emit ItemPurchased(_listingId, msg.sender, newPurchaseId, _quantity, _totalCost, _paymentMethod);
      purchaseCount++;
    }

    /**
     * @dev Confirm delivery and release payment to seller
     */
    function confirmDelivery(uint256 _purchaseId)
      external
      nonReentrant
      validPurchaseId(_purchaseId)
      whenNotPaused
    {
      Purchase storage purchase = purchases[_purchaseId];
      if (purchase.buyer != msg.sender) revert NOT_BUYER();
      if (purchase.confirmed) revert ALREADY_CONFIRMED();

      purchase.confirmed = true;
      pendingPurchaseCount[purchase.listingId]--;

      _releaseFunds(purchase);
      
      emit DeliveryConfirmed(
          purchase.listingId,
          msg.sender,
          purchase.seller,
          _purchaseId,
          purchase.paymentMethod
      );
    }

    /**
     * @dev Allow seller to claim funds after timeout
     */
    function claimAfterTimeout(uint256 _purchaseId)
      external
      nonReentrant
      validPurchaseId(_purchaseId)
      whenNotPaused
    {
      Purchase storage purchase = purchases[_purchaseId];
      
      if (purchase.seller != msg.sender) revert UNAUTHORIZED();
      if (purchase.confirmed) revert ALREADY_CONFIRMED();
      if (block.timestamp < purchase.createdAt + TIMEOUT_DURATION) revert TIMEOUT_NOT_REACHED();

      purchase.confirmed = true;
      pendingPurchaseCount[purchase.listingId]--;

      _releaseFunds(purchase);
      
      emit TimeoutClaim(_purchaseId, msg.sender, purchase.paidAmount, purchase.paymentMethod);
    }

    /**
     * @dev Internal function to release funds to seller and collect fees
     */
    function _releaseFunds(Purchase storage purchase) internal {
      uint256 fee = (purchase.paidAmount * FEE_BPS) / 10000;
      uint256 sellerAmount = purchase.paidAmount - fee;
      
      if (purchase.paymentMethod == PaymentMethod.ETH) {
          sellerETHBalances[purchase.seller] += sellerAmount;
          platformETHFees += fee;
      } else {
          sellerUSDTBalances[purchase.seller] += sellerAmount;
          platformUSDTFees += fee;
      }
    }

    /**
     * @dev Withdraw seller earnings (both ETH and USDT)
     */
    function withdrawEarnings() external nonReentrant {
      uint256 ethAmount = sellerETHBalances[msg.sender];
      uint256 usdtAmount = sellerUSDTBalances[msg.sender];
      
      if (ethAmount == 0 && usdtAmount == 0) revert INSUFFICIENT_FUND();
      
      if (ethAmount > 0) {
          sellerETHBalances[msg.sender] = 0;
      }
      if (usdtAmount > 0) {
          sellerUSDTBalances[msg.sender] = 0;
      }
      
      if (ethAmount > 0) {
          (bool success, ) = payable(msg.sender).call{value: ethAmount}("");
          if (!success) revert TRANSFER_FAILED();
      }
      
      if (usdtAmount > 0) {
          IERC20(USDT).safeTransfer(msg.sender, usdtAmount);
      }
      
      emit EarningsWithdrawn(msg.sender, ethAmount, usdtAmount);
    }

    /**
     * @dev Owner function to withdraw platform fees
     */
    function withdrawFees() external onlyOwner nonReentrant {
      uint256 ethAmount = platformETHFees;
      uint256 usdtAmount = platformUSDTFees;
      
      if (ethAmount == 0 && usdtAmount == 0) revert INSUFFICIENT_FUND();
      
      if (ethAmount > 0) {
          platformETHFees = 0;
      }
      if (usdtAmount > 0) {
          platformUSDTFees = 0;
      }
      
      if (ethAmount > 0) {
          (bool success, ) = payable(owner()).call{value: ethAmount}("");
          if (!success) revert TRANSFER_FAILED();
      }
      
      if (usdtAmount > 0) {
          IERC20(USDT).safeTransfer(owner(), usdtAmount);
      }
      
      emit FeesWithdrawn(owner(), ethAmount, usdtAmount);
    }

    /**
     * @dev Pause contract (owner only)
     */
    function pause() external onlyOwner {
      _pause();
    }

    /**
     * @dev Unpause contract (owner only)
     */
    function unpause() external onlyOwner {
      _unpause();
    }

    /**
     * @dev Emergency function to allow withdrawals even when paused
     */
    function emergencyWithdrawEarnings() external nonReentrant {
      uint256 ethAmount = sellerETHBalances[msg.sender];
      uint256 usdtAmount = sellerUSDTBalances[msg.sender];
      
      if (ethAmount == 0 && usdtAmount == 0) revert INSUFFICIENT_FUND();
      
      if (ethAmount > 0) {
          sellerETHBalances[msg.sender] = 0;
      }
      if (usdtAmount > 0) {
          sellerUSDTBalances[msg.sender] = 0;
      }
      
      if (ethAmount > 0) {
          (bool success, ) = payable(msg.sender).call{value: ethAmount}("");
          if (!success) revert TRANSFER_FAILED();
      }
      
      if (usdtAmount > 0) {
          IERC20(USDT).safeTransfer(msg.sender, usdtAmount);
      }
      
      emit EarningsWithdrawn(msg.sender, ethAmount, usdtAmount);
    }

    function _removeListingId(address _seller, uint256 _id) internal {
      uint256[] storage ids = sellerListings[_seller];
      for (uint256 i = 0; i < ids.length; i++) {
        if (ids[i] == _id) {
            ids[i] = ids[ids.length - 1];
            ids.pop();
            break;
        }
      }
    }

    function getListingById(uint256 _listingId)
      external
      view
      validListingId(_listingId)
      returns (Listing memory)
    {
      return listings[_listingId];
    }

    function getPurchaseById(uint256 _purchaseId)
      external
      view
      validPurchaseId(_purchaseId)
      returns (Purchase memory)
    {
      return purchases[_purchaseId];
    }

    function getMyListingIds() external view returns (uint256[] memory) {
      return sellerListings[msg.sender];
    }

    function getMyPurchaseIds() external view returns (uint256[] memory) {
      return buyerPurchases[msg.sender];
    }

    function getListingPurchases(uint256 _listingId) external view returns (uint256[] memory) {
      return listingPurchases[_listingId];
    }

    function getMyBalances() external view returns (uint256 ethBalance, uint256 usdtBalance) {
      return (sellerETHBalances[msg.sender], sellerUSDTBalances[msg.sender]);
    }

    function canClaimTimeout(uint256 _purchaseId) external view returns (bool) {
      if (_purchaseId >= purchaseCount || _purchaseId == 0) return false;
      
      Purchase storage purchase = purchases[_purchaseId];
      if (purchase.confirmed) return false;
      
      return block.timestamp >= purchase.createdAt + TIMEOUT_DURATION;
    }

    function getPlatformFees() external view returns (uint256 ethFees, uint256 usdtFees) {
      return (platformETHFees, platformUSDTFees);
    }

    /**
     * @dev Get contract's token balance
     */
    function getContractBalance() external view returns (uint256 ethBalance, uint256 usdtBalance) {
      return (address(this).balance, IERC20(USDT).balanceOf(address(this)));
    }
}
