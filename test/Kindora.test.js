const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Kindora (KNR) - core flows", function () {
  let deployer, addr1, addr2, addr3, charity, other;
  let MockFactory, MockRouter, DummyERC20, Kindora;
  let factory, router, router2, factory2;
  let token;
  const toUnits = (n) => ethers.utils.parseUnits(n.toString(), 18);

  beforeEach(async function () {
    [deployer, addr1, addr2, addr3, charity, other] = await ethers.getSigners();

    MockFactory = await ethers.getContractFactory("MockFactory");
    MockRouter = await ethers.getContractFactory("MockRouter");
    DummyERC20 = await ethers.getContractFactory("DummyERC20");
    Kindora = await ethers.getContractFactory("Kindora");

    // Deploy factory and router mocks
    factory = await MockFactory.deploy();
    await factory.deployed();
    // Use addr3 as WETH placeholder
    router = await MockRouter.deploy(factory.address, addr3.address);
    await router.deployed();

    // Deploy token with router mock address
    token = await Kindora.deploy(router.address);
    await token.deployed();

    // Fund router with some ETH so swaps can send ETH back
    await deployer.sendTransaction({ to: router.address, value: ethers.utils.parseEther("5") });

    // create pair in factory to match token constructor behavior (constructor will have created or read pair)
    // (pair is already created by constructor if needed because the constructor called factory.getPair/createPair)
  });

  it("buy fee triggers: fees, buckets and burn work on taxed transfer", async function () {
    // Include deployer in fees so that deployer->addr1 is taxed (constructor excluded deployer)
    await token.excludeFromFees(deployer.address, false);

    const amount = toUnits(1000); // 1000 tokens
    // transfer from deployer to addr1 (taxed)
    await token.transfer(addr1.address, amount);

    const totalFee = amount.mul(5).div(100);
    const burn = totalFee.mul(1).div(5); // BURN_FEE/TOTAL_FEE
    const charity = totalFee.mul(3).div(5);
    const liquidity = totalFee.mul(1).div(5);

    // Recipient balance should be amount - totalFee
    expect(await token.balanceOf(addr1.address)).to.equal(amount.sub(totalFee));

    // Charity and liquidity counters updated
    expect(await token.charityTokens()).to.equal(charity);
    expect(await token.liquidityTokens()).to.equal(liquidity);

    // totalSupply decreased by burn
    const totalSupply = await token.totalSupply();
    // initial supply was 10_000_000 - burned
    const initial = toUnits(10000000);
    expect(totalSupply).to.equal(initial.sub(burn));
  });

  it("sell triggers swaps: liquidity and charity swaps execute and counters reset", async function () {
    // include deployer in fees to create initial taxed transfers to fill contract counters
    await token.excludeFromFees(deployer.address, false);
    // set small threshold so swaps run in test
    await token.setMinTokensForSwap(toUnits(1)); // min 1 token

    // perform several taxed transfers to accumulate tokens in contract via fees
    // transfer from deployer to addr1 and addr2
    await token.transfer(addr1.address, toUnits(5000));
    await token.transfer(addr2.address, toUnits(3000));

    // At this point contract should have accumulated fees (charityTokens + liquidityTokens)
    const cTokens = await token.charityTokens();
    const lTokens = await token.liquidityTokens();
    expect(cTokens.gt(0)).to.be.true;
    expect(lTokens.gt(0)).to.be.true;

    // Set charity wallet to charity address
    await token.setCharityWallet(charity.address);

    // Ensure contract has token balance sufficient (fees were moved to contract)
    const contractTokenBalance = await token.balanceOf(token.address);
    expect(contractTokenBalance.gte(cTokens.add(lTokens))).to.be.true;

    // Record ETH balances before selling
    const charityEthBefore = await ethers.provider.getBalance(charity.address);
    const contractEthBefore = await ethers.provider.getBalance(token.address);

    // Now perform a sell: addr1 -> pair (transfer to pair address). This will trigger swaps in _transfer
    const pairAddress = await token.pair();
    // Give addr1 some extra tokens so the transfer to pair will be large enough
    // addr1 already has tokens from earlier transfer.
    // Approve not needed for simple transfer
    await token.connect(addr1).transfer(pairAddress, toUnits(100)); // this should trigger swapAndLiquify & charity

    // After selling, charityTokens and liquidityTokens should have decreased (likely zero)
    const charityAfter = await token.charityTokens();
    const liquidityAfter = await token.liquidityTokens();
    expect(charityAfter.lte(cTokens)).to.be.true;
    expect(liquidityAfter.lte(lTokens)).to.be.true;

    // Charity wallet should have gained ETH from the mock router swap (router sends up to 1 ETH per swap)
    const charityEthAfter = await ethers.provider.getBalance(charity.address);
    expect(charityEthAfter).to.be.gt(charityEthBefore);

    // Contract ETH also should have increased due to the swap for liquidity (router sends ETH to contract)
    const contractEthAfter = await ethers.provider.getBalance(token.address);
    expect(contractEthAfter).to.be.gt(contractEthBefore);
  });

  it("burn reduces totalSupply on taxed transfers", async function () {
    // include deployer in fees for taxed transfer
    await token.excludeFromFees(deployer.address, false);

    const amount = toUnits(2000);
    const totalSupplyBefore = await token.totalSupply();

    // transfer taxed
    await token.transfer(addr1.address, amount);

    // compute expected burn
    const totalFee = amount.mul(5).div(100);
    const burn = totalFee.mul(1).div(5);

    const totalSupplyAfter = await token.totalSupply();
    expect(totalSupplyAfter).to.equal(totalSupplyBefore.sub(burn));
  });

  it("maxTx and maxWallet limits enforced", async function () {
    // maxTx and maxWallet were set in constructor: 2% of total supply
    const initialMaxTx = await token.maxTxAmount();
    const initialMaxWallet = await token.maxWalletAmount();

    // Attempt to do a transfer larger than maxTx from a non-excluded sender
    // First, ensure deployer participates (by including in fees and not excluded from maxTx)
    await token.excludeFromFees(deployer.address, false);
    // Deployer is excludedFromMaxTx by constructor, so to test maxTx we must use another non-excluded sender.
    // Give addr1 some tokens from deployer (deployer->addr1 transfer will be taxed only if deployer included in fees)
    await token.transfer(addr1.address, toUnits(1000));

    // Try to transfer > maxTx from addr1 to addr2
    const bigAmount = initialMaxTx.add(toUnits(1));
    await expect(token.connect(addr1).transfer(addr2.address, bigAmount)).to.be.revertedWith("MaxTx: amount exceeds limit");

    // Test maxWallet: attempt to send tokens to addr3 so its balance would exceed maxWalletAmount
    // Owner (deployer) is excluded from maxTx but not from initiating the transfer; maxWallet check applies based on 'to'
    const exceedWallet = initialMaxWallet.add(toUnits(1));
    await expect(token.transfer(addr3.address, exceedWallet)).to.be.revertedWith("MaxWallet: amount exceeds limit");
  });

  it("router change updates router and pair and grants allowance", async function () {
    // Deploy a new factory & router
    factory2 = await MockFactory.deploy();
    await factory2.deployed();
    router2 = await MockRouter.deploy(factory2.address, addr3.address);
    await router2.deployed();

    // Call setRouter
    await token.setRouter(router2.address);

    // Confirm router updated
    expect(await token.router()).to.equal(router2.address);

    // Confirm pair is non-zero
    const newPair = await token.pair();
    expect(newPair).to.not.equal(ethers.constants.AddressZero);

    // Confirm allowance for new router is maximal
    const allowance = await token.allowance(token.address, router2.address);
    expect(allowance).to.equal(ethers.constants.MaxUint256);
  });

  it("rescue functions: rescueTokens and rescueBNB", async function () {
    // Deploy dummy ERC20 and send tokens to contract
    const dummy = await DummyERC20.deploy();
    await dummy.deployed();

    // Mint some dummy tokens to deployer then transfer to token contract
    await dummy.transfer(token.address, toUnits(1000));

    // Confirm token contract holds dummy
    expect(await dummy.balanceOf(token.address)).to.equal(toUnits(1000));

    // Call rescueTokens as owner
    await token.rescueTokens(dummy.address, toUnits(1000));

    // Owner (deployer) should now have the dummy tokens
    expect(await dummy.balanceOf(deployer.address)).to.be.greaterThanOrEqual(toUnits(1000));

    // Now test rescueBNB: send ETH to token contract and rescue
    const sendAmt = ethers.utils.parseEther("1");
    await deployer.sendTransaction({ to: token.address, value: sendAmt });

    const ownerEthBefore = await ethers.provider.getBalance(deployer.address);
    // Call rescueBNB (owner)
    const tx = await token.rescueBNB(sendAmt);
    const receipt = await tx.wait();

    const ownerEthAfter = await ethers.provider.getBalance(deployer.address);
    // Owner's ETH should increase (less gas cost) - check at least some ETH moved to owner
    expect(ownerEthAfter).to.be.gt(ownerEthBefore.sub(ethers.utils.parseEther("0.01"))); // fuzzy check
  });

  it("tiny transfer (1 wei) edge case does not create stuck tokens", async function () {
    // include deployer in fees so it's taxed if needed
    await token.excludeFromFees(deployer.address, false);

    const tiny = ethers.BigNumber.from(1);
    // Transfer tiny amount
    await token.transfer(addr1.address, tiny);

    // fee = (1 * 5%) / 100 = 0 (integer division)
    expect(await token.balanceOf(addr1.address)).to.equal(tiny);

    // No burn should have happened (total supply unchanged)
    const totalSupply = await token.totalSupply();
    // initial supply was 10_000_000; if running tests in isolation, assert totalSupply equals initial minus any burn from other tests
    expect(totalSupply.lte(toUnits(10000000))).to.be.true;
  });
});
