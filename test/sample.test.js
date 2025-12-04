const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Sample tests (minimal, stable)", function () {
  const EXPECTED_TOTAL_SUPPLY = 10_000_000;
  
  let deployer, addr1;
  let MockFactory, MockRouter, KindoraToken;
  let factory, router, token;
  const toUnits = (n) => ethers.utils.parseUnits(n.toString(), 18);

  beforeEach(async function () {
    [deployer, addr1] = await ethers.getSigners();

    MockFactory = await ethers.getContractFactory("MockFactory");
    MockRouter = await ethers.getContractFactory("MockRouter");
    KindoraToken = await ethers.getContractFactory("KindoraToken");

    // Deploy factory and router mocks
    factory = await MockFactory.deploy();
    await factory.deployed();
    // Use addr1 as WETH placeholder
    router = await MockRouter.deploy(factory.address, addr1.address);
    await router.deployed();

    // Deploy token with router mock address
    token = await KindoraToken.deploy(router.address);
    await token.deployed();
  });

  it("deploys with correct name and symbol", async function () {
    expect(await token.name()).to.equal("Kindora");
    expect(await token.symbol()).to.equal("KNR");
  });

  it("deploys with correct initial supply", async function () {
    const totalSupply = await token.totalSupply();
    const expectedSupply = toUnits(EXPECTED_TOTAL_SUPPLY);
    expect(totalSupply).to.equal(expectedSupply);
  });

  it("deployer has initial balance", async function () {
    const balance = await token.balanceOf(deployer.address);
    const totalSupply = await token.totalSupply();
    expect(balance).to.equal(totalSupply);
  });

  it("router and pair are set correctly", async function () {
    expect(await token.router()).to.equal(router.address);
    const pair = await token.pair();
    expect(pair).to.not.equal(ethers.constants.AddressZero);
  });
});
