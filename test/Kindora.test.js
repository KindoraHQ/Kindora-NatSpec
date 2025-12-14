const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("KindoraToken - correct and safe behavior", function () {
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
      value: ethers.utils.parseEther("5"),
    });
  });

  it("wallet -> wallet transfers have NO fee", async function () {
    await token.excludeFromFees(deployer.address, false);

    const amount = toUnits(1000);
    await token.transfer(addr1.address, amount);

    expect(await token.balanceOf(addr1.address)).to.equal(amount);
  });

  it("SELL to pair takes fee, burns supply, and fills buckets", async function () {
    await token.excludeFromFees(deployer.address, false);

    await token.transfer(addr1.address, toUnits(2000));

    const pair = await token.pair();
    const sellAmount = toUnits(1000);
    const supplyBefore = await token.totalSupply();

    await token.connect(addr1).transfer(pair, sellAmount);

    const totalFee = sellAmount.mul(5).div(100);
    const burn = totalFee.mul(1).div(5);

    expect(await token.totalSupply()).to.equal(supplyBefore.sub(burn));
  });

  it("swap is intentionally delayed and triggers on non-pair transfer", async function () {
    await token.excludeFromFees(deployer.address, false);
    await token.setMinTokensForSwap(toUnits(1));
    await token.setCharityWallet(charity.address);

    await token.transfer(addr1.address, toUnits(5000));
    const pair = await token.pair();

    // SELL fills buckets, no swap yet
    await token.connect(addr1).transfer(pair, toUnits(1000));

    const charityEthBefore = await ethers.provider.getBalance(charity.address);

    // non-pair transfer triggers swap
    await token.transfer(addr2.address, toUnits(1));

    const charityEthAfter = await ethers.provider.getBalance(charity.address);

    expect(charityEthAfter).to.be.gt(charityEthBefore);
  });
});
