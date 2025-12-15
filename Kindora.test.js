const { expect } = require("chai"); const { ethers } = require("hardhat");

describe("KindoraToken", function () {
  let deployer, addr1, addr2, wethLike, charity;
  let MockFactory, MockRouter, Kindora;
  let factory, router, token;

  const toUnits = (n) => ethers.utils.parseUnits(n.toString(), 18);

  beforeEach(async function () {
    [deployer, addr1, addr2, wethLike, charity] = await ethers.getSigners();

    MockFactory = await ethers.getContractFactory("MockFactory");
    MockRouter = await ethers.getContractFactory("MockRouter");
    Kindora = await ethers.getContractFactory("KindoraToken");

    factory = await MockFactory.deploy();
    await factory.deployed();

    router = await MockRouter.deploy(factory.address, wethLike.address);
    await router.deployed();

    token = await Kindora.deploy(router.address);
    await token.deployed();

    // fund router so swaps can send ETH
    await deployer.sendTransaction({
      to: router.address,
      value: ethers.utils.parseEther("50"),
    });
  });

  describe("Wallet-to-Wallet Transfers", function () {
    it("Should not take fees", async function () {
      const amount = toUnits(1000);
      await token.transfer(addr1.address, amount);
      await token.connect(addr1).transfer(addr2.address, amount);

      expect(await token.balanceOf(addr2.address)).to.equal(amount);
    });
  });

  describe("SELL Behavior: Wallet to Pair", function () {
    it("Should deduct fee, burn, and fill buckets but not swap", async function () {
      await token.transfer(addr1.address, toUnits(10000));

      // Simulate a SELL (wallet -> Pair)
      const pair = await token.pair();
      const totalSupplyBefore = await token.totalSupply();
      const sellAmount = toUnits(1000);
      await token.connect(addr1).transfer(pair, sellAmount);

      const fee = sellAmount.mul(5).div(100); // 5% total fee
      const burnAmount = fee.mul(1).div(5); // 1% burn
      const burnedSupply = totalSupplyBefore.sub(burnAmount);

      expect(await token.totalSupply()).to.equal(burnedSupply);

      // Check buckets were filled
      const charityTokens = await token.charityTokens();
      const liquidityTokens = await token.liquidityTokens();

      const expectedCharity = fee.mul(3).div(5); // 3% to charity
      const expectedLiquidity = fee.mul(1).div(5); // 1% to LIQ
      expect(charityTokens).to.equal(expectedCharity);
      expect(liquidityTokens).to.equal(expectedLiquidity);
    });
  });

  describe("Trigger Swap: Non Pair Transfer", function () {
    it("Should execute swaps and transfer results", async function () {
      await token.setMinTokensForSwap(toUnits(1)); // Ensure swaps can trigger
      await token.setCharityWallet(charity.address);

      // Sell to fill values first (populates buckets)
      const pair = await token.pair();
      await token.transfer(addr1.address, toUnits(20000));

      await token.connect(addr1).transfer(pair, toUnits(1000)); // A sell fills buckets

      const charityBalanceBefore = await ethers.provider.getBalance(charity.address);

      // Transfer triggering swap
      await token.transfer(addr2.address, toUnits(1));

      const charityBalanceAfter = await ethers.provider.getBalance(charity.address);
      expect(charityBalanceAfter).to.be.gt(charityBalanceBefore, `ETH Balance wasn't forwarded`);

      expect(await token.charityTokens()).to.equal(0, `Expected empty`);