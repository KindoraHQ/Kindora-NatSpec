const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Sample Tests (CI stable)", function () {
  // Constants matching the contract
  const INITIAL_SUPPLY = 10_000_000;
  
  let deployer, addr1, charity;
  let MockFactory, MockRouter, Kindora;
  let factory, router;
  let token;
  const toUnits = (n) => ethers.utils.parseUnits(n.toString(), 18);

  beforeEach(async function () {
    [deployer, addr1, charity] = await ethers.getSigners();

    MockFactory = await ethers.getContractFactory("MockFactory");
    MockRouter = await ethers.getContractFactory("MockRouter");
    Kindora = await ethers.getContractFactory("Kindora");

    // Deploy factory and router mocks
    factory = await MockFactory.deploy();
    await factory.deployed();
    // Use charity as WETH placeholder
    router = await MockRouter.deploy(factory.address, charity.address);
    await router.deployed();

    // Deploy token with router mock address
    token = await Kindora.deploy(router.address);
    await token.deployed();

    // Fund router with some ETH so swaps can send ETH back
    await deployer.sendTransaction({ to: router.address, value: ethers.utils.parseEther("5") });
  });

  it("should deploy with correct initial supply", async function () {
    const totalSupply = await token.totalSupply();
    expect(totalSupply).to.equal(toUnits(INITIAL_SUPPLY));
  });

  it("should have correct name and symbol", async function () {
    expect(await token.name()).to.equal("Kindora");
    expect(await token.symbol()).to.equal("KNR");
  });

  it("deployer should have all initial tokens", async function () {
    const deployerBalance = await token.balanceOf(deployer.address);
    const totalSupply = await token.totalSupply();
    expect(deployerBalance).to.equal(totalSupply);
  });

  it("should transfer tokens (excluded from fees)", async function () {
    const amount = toUnits(1000);
    await token.transfer(addr1.address, amount);
    // Deployer is excluded from fees by default, so full amount should transfer
    expect(await token.balanceOf(addr1.address)).to.equal(amount);
  });

  it("should enforce maxTx limit", async function () {
    const maxTx = await token.maxTxAmount();
    const exceedAmount = maxTx.add(toUnits(1));
    
    // Give addr1 some tokens
    await token.transfer(addr1.address, exceedAmount);
    
    // Addr1 is not excluded from maxTx, so transfer should fail
    await expect(
      token.connect(addr1).transfer(deployer.address, exceedAmount)
    ).to.be.revertedWith("MaxTx: amount exceeds limit");
  });
});
