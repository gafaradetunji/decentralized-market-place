import { expect } from "chai";
import { ethers } from "hardhat";
import { Market, ERC20Mock } from "../typechain-types";
import { deployContracts } from "../scripts/deploy";

describe("Market", function () {
  let market: Market;
  let usdt: ERC20Mock;
  let owner: any, seller: any, buyer: any, other: any;

  beforeEach(async () => {
    const { deployer, usdt: deployedUsdt, market: deployedMarket } = await deployContracts();
    owner = deployer;
    [seller, buyer, other] = await ethers.getSigners();
    usdt = deployedUsdt;
    market = deployedMarket;
  });

  describe("Deployment", () => {
    it("Should deploy successfully", async () => {
      expect(await market.owner()).to.equal(owner.address);
    });

    it("Should revert on direct ETH transfers", async () => {
      await expect(
        seller.sendTransaction({ to: await market.getAddress(), value: ethers.parseEther("1") })
      ).to.be.revertedWithCustomError(market, "DIRECT_ETH_NOT_ACCEPTED");
    });
  });

  describe("Listings", () => {
    it("Should create listing with valid inputs", async () => {
      const tx = await market.connect(seller).createListing(
        ethers.parseEther("1"),
        ethers.parseUnits("100", 6),
        5,
        "Item metadata",
        true,
        true
      );

      await expect(tx).to.emit(market, "ListingCreated");
    });

    it("Should revert with ZERO_PRICE or ZERO_QUANTITY", async () => {
      await expect(
        market.connect(seller).createListing(0, 0, 0, "Bad", true, true)
      ).to.be.revertedWithCustomError(market, "ZERO_QUANTITY");

      await expect(
        market.connect(seller).createListing(0, ethers.parseUnits("1", 6), 1, "Bad", true, true)
      ).to.be.revertedWithCustomError(market, "ZERO_PRICE");
    });

    it("Should update listing", async () => {
      await market.connect(seller).createListing(
        ethers.parseEther("1"),
        ethers.parseUnits("100", 6),
        5,
        "Item metadata",
        true,
        true
      );

      const tx = await market.connect(seller).updateListing(
        1,
        ethers.parseEther("2"),
        ethers.parseUnits("200", 6),
        10,
        "Updated",
        true,
        true
      );
      await expect(tx).to.emit(market, "ListingUpdated");
    });

    it("Should revert if non-seller updates listing", async () => {
      await market.connect(seller).createListing(
        ethers.parseEther("1"),
        ethers.parseUnits("100", 6),
        5,
        "Item metadata",
        true,
        true
      );

      await expect(
        market.connect(buyer).updateListing(
          1,
          ethers.parseEther("2"),
          ethers.parseUnits("200", 6),
          10,
          "Updated",
          true,
          true
        )
      ).to.be.revertedWithCustomError(market, "UNAUTHORIZED");
    });

    it("Should delete listing", async () => {
      await market.connect(seller).createListing(
        ethers.parseEther("1"),
        ethers.parseUnits("100", 6),
        5,
        "Item metadata",
        true,
        true
      );

      const tx = await market.connect(seller).deleteListing(1);
      await expect(tx).to.emit(market, "ListingDeleted");
    });
  });

  // -----------------------------
  // Purchases
  // -----------------------------
  describe("Purchases", () => {
    beforeEach(async () => {
      await market.connect(seller).createListing(
        ethers.parseEther("1"),
        ethers.parseUnits("100", 6),
        5,
        "Item metadata",
        true,
        true
      );
    });

    it("Should purchase item with ETH", async () => {
      const tx = await market.connect(buyer).purchaseItemWithETH(1, 1, {
        value: ethers.parseEther("1"),
      });

      await expect(tx).to.emit(market, "ItemPurchased");
    });

    it("Should revert with incorrect ETH amount", async () => {
      await expect(
        market.connect(buyer).purchaseItemWithETH(1, 1, {
          value: ethers.parseEther("2"),
        })
      ).to.be.revertedWithCustomError(market, "EXACT_AMOUNT_REQUIRED");
    });

    it("Should purchase item with USDT", async () => {
      await usdt.connect(seller).transfer(buyer.address, ethers.parseUnits("200", 6));
      await usdt.connect(buyer).approve(await market.getAddress(), ethers.parseUnits("200", 6));

      const tx = await market.connect(buyer).purchaseItemWithUSDT(1, 1);
      await expect(tx).to.emit(market, "ItemPurchased");
    });

    it("Should confirm delivery", async () => {
      await market.connect(buyer).purchaseItemWithETH(1, 1, {
        value: ethers.parseEther("1"),
      });

      const tx = await market.connect(buyer).confirmDelivery(1);
      await expect(tx).to.emit(market, "DeliveryConfirmed");
    });

    it("Should revert confirmDelivery if not buyer", async () => {
      await market.connect(buyer).purchaseItemWithETH(1, 1, {
        value: ethers.parseEther("1"),
      });

      await expect(market.connect(other).confirmDelivery(1))
        .to.be.revertedWithCustomError(market, "NOT_BUYER");
    });

    it("Should allow claim after timeout", async () => {
      await market.connect(buyer).purchaseItemWithETH(1, 1, {
        value: ethers.parseEther("1"),
      });

      await ethers.provider.send("evm_increaseTime", [31 * 24 * 60 * 60]); // 31 days
      await ethers.provider.send("evm_mine", []);

      const tx = await market.connect(seller).claimAfterTimeout(1);
      await expect(tx).to.emit(market, "TimeoutClaim");
    });
  });

  // -----------------------------
  // Withdrawals
  // -----------------------------
  describe("Withdrawals", () => {
    beforeEach(async () => {
      await market.connect(seller).createListing(
        ethers.parseEther("1"),
        ethers.parseUnits("100", 6),
        1,
        "Item metadata",
        true,
        true
      );
      await market.connect(buyer).purchaseItemWithETH(1, 1, {
        value: ethers.parseEther("1"),
      });
      await market.connect(buyer).confirmDelivery(1);
    });

    it("Seller should withdraw earnings", async () => {
      const tx = await market.connect(seller).withdrawEarnings();
      await expect(tx).to.emit(market, "EarningsWithdrawn");
    });

    it("Owner should withdraw platform fees", async () => {
      const tx = await market.connect(owner).withdrawFees();
      await expect(tx).to.emit(market, "FeesWithdrawn");
    });
  });

  // -----------------------------
  // Modifiers & Edge cases
  // -----------------------------
  describe("Modifiers & Edge cases", () => {
    it("Should revert with ITEM_DOES_NOT_EXIST on invalid listingId", async () => {
      await expect(market.getListingById(999)).to.be.revertedWithCustomError(market, "ITEM_DOES_NOT_EXIST");
    });

    it("Should revert with INVALID_PURCHASE_ID", async () => {
      await expect(market.getPurchaseById(999)).to.be.revertedWithCustomError(market, "INVALID_PURCHASE_ID");
    });

    it("Should revert with UNSUPPORTED_TOKEN when no payment method enabled", async () => {
      await expect(
        market.connect(seller).createListing(0, 0, 1, "Bad", false, false)
      ).to.be.revertedWithCustomError(market, "INVALID_PAYMENT_METHOD");
    });
  });
});
