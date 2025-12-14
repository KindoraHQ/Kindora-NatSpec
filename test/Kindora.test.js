const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Kindora (KNR) - core flows", function () {
  let deployer, addr1, addr2, addr3, charity;
  let MockFactory, MockRouter, DummyERC20, Kindora;
  let factory, router, factory2, router2;
  let token;

  const toUnits = (n) => ethers.utils.parseUnits(n.toString(), 18);

  beforeEach(async function () {
    [deployer, addr1, addr2, addr3, charity] = await ethers.getSigners();

    MockFactory = await ethers.getContractFactory("MockFactory");
    MockRouter = await ethers.getContractFactory("MockRouter");
    DummyERC20 = await ethers.getContractFactory("DummyERC20");
    Kindora = await ethers.getContractFactory("KindoraToken");

    factory = await MockFactory.deploy();
    await factory.deployed();

    router = await MockRouter.deploy(factory.address, addr3.address);
    await router.deployed();

    token = await Kindora.deploy(router.address);
    await token.deployed();

    // fund router with ETH
    await deployer.sendTransaction({
      to: router.address,
      value: ethers.utils.parseEther("5"),
    });
  });

  it("sell fee triggers: fees, buckets and burn work on SELL", async function () {
    await token.excludeFromFees(deployer.address, false);

    // give addr1 tokens first (wallet → wallet, NO fee)
    await token.transfer(addr1.address, toUnits(1000));

    const pair = await token.pair();
    const amount = toUnits(1000);

    // SELL (addr1 → pair) → fee applies
    await token.connect(addr1).transfer(pair, amount);

    const totalFee = amount.mul(5).div(100);
    const burn = totalFee.mul(1).div(5);
    const charityFee = totalFee.mul(3).div(5);
    const liquidityFee = totalFee.mul(1).div(5);

    expect(await token.charityTokens()).to.equal(charityFee);
    expect(await token.liquidityTokens()).to.equal(liquidityFee);

    const initialSupply = toUnits(10_000_000);
    expect(await token.totalSupply()).to.equal(initialSupply.sub(burn));
  });

  it("sell triggers swaps: liquidity and charity swaps execute", async function () {
    await token.excludeFromFees(deployer.address, false);
    await token.setMinTokensForSwap(toUnits(1));
    await token.setCharityWallet(charity.address);

    // prepare balances
    await token.transfer(addr1.address, toUnits(5000));
    await token.transfer(addr2.address, toUnits(5000));

    const pair = await token.pair();

    // SELLs to fill buckets
    await token.connect(addr1).transfer(pair, toUnits(1000));
    await token.connect(addr2).transfer(pair, toUnits(1000));

    const charityBefore = await ethers.provider.getBalance(charity.address);
    const contractTokenBefore = await token.balanceOf(token.address);

    // another SELL triggers swaps (in your contract, swap attempts happen before fee collection,
    // so whether this SELL triggers depends on bucket values already being >= minTokensForSwap)
    await token.connect(addr1).transfer(pair, toUnits(500));

    const charityAfter = await ethers.provider.getBalance(charity.address);
    const contractTokenAfter = await token.balanceOf(token.address);

    // charity swap sends ETH directly to charityWallet (not to the token contract)
    expect(charityAfter).to.be.gt(charityBefore);

    // swap should consume some of the contract's accumulated tokens (charity and/or liquidity)
    expect(contractTokenAfter).to.be.lt(contractTokenBefore);
  });

  it("burn reduces totalSupply only on SELL", async function () {
    await token.excludeFromFees(deployer.address, false);

    await token.transfer(addr1.address, toUnits(2000));

    const pair = await token.pair();
    const supplyBefore = await token.totalSupply();

    await token.connect(addr1).transfer(pair, toUnits(1000));

    const totalFee = toUnits(1000).mul(5).div(100);
    const burn = totalFee.mul(1).div(5);

    expect(await token.totalSupply()).to.equal(supplyBefore.sub(burn));
  });

  it("maxTx and maxWallet limits enforced", async function () {
    const maxTx = await token.maxTxAmount();
    const maxWallet = await token.maxWalletAmount();

    await token.excludeFromFees(deployer.address, false);
    await token.transfer(addr1.address, toUnits(1000));

    await expect(
      token.connect(addr1).transfer(addr2.address, maxTx.add(1))
    ).to.be.revertedWith("MaxTx: amount exceeds limit");

    await expect(
      token.transfer(addr3.address, maxWallet.add(1))
    ).to.be.revertedWith("MaxWallet: amount exceeds limit");
  });

  it("router change updates router and pair and allowance", async function () {
    factory2 = await MockFactory.deploy();
    await factory2.deployed();

    router2 = await MockRouter.deploy(factory2.address, addr3.address);
    await router2.deployed();

    await token.setRouter(router2.address);

    expect(await token.router()).to.equal(router2.address);
    expect(await token.pair()).to.not.equal(ethers.constants.AddressZero);

    const allowance = await token.allowance(token.address, router2.address);
    expect(allowance).to.equal(ethers.constants.MaxUint256);
  });

  it("rescue functions work", async function () {
    const dummy = await DummyERC20.deploy();
    await dummy.deployed();

    await dummy.transfer(token.address, toUnits(1000));
    await token.rescueTokens(dummy.address, toUnits(1000));

    expect(await dummy.balanceOf(deployer.address)).to.be.gte(toUnits(1000));

    await deployer.sendTransaction({
      to: token.address,
      value: ethers.utils.parseEther("1"),
    });

    const ethBefore = await ethers.provider.getBalance(deployer.address);
    await token.rescueBNB(ethers.utils.parseEther("1"));
    const ethAfter = await ethers.provider.getBalance(deployer.address);

    expect(ethAfter).to.be.gt(ethBefore.sub(ethers.utils.parseEther("0.01")));
  });

  it("wallet to wallet transfer has NO fee", async function () {
    await token.excludeFromFees(deployer.address, false);

    await token.transfer(addr1.address, toUnits(1000));
    expect(await token.balanceOf(addr1.address)).to.equal(toUnits(1000));
  });
});
