# KindoraToken Test Suite

This directory contains comprehensive test coverage for the KindoraToken (KNR) smart contract.

## Test Files

### 1. `sample.test.js`
Basic smoke tests for initial deployment and core functionality:
- Initial supply verification
- Name and symbol checks
- Basic transfers
- MaxTx limit enforcement

### 2. `Kindora.test.js`
Core flow tests covering:
- Fee collection on taxed transfers
- Swap triggering (liquidity and charity)
- Burn mechanism
- Anti-whale limits (maxTx and maxWallet)
- Router management
- Rescue functions
- Edge cases (tiny transfers, etc.)

### 3. `KindoraToken.comprehensive.test.js` (NEW)
**Comprehensive test suite providing full coverage for all KindoraToken functionality:**

#### Deployment and Initial Configuration
- Correct initial supply, name, and symbol
- Router and pair setup
- Default exclusions from fees and limits
- Initial limits configuration
- Charity wallet initialization
- Swap threshold defaults

#### Buy Flow (from pair to user)
- 5% total fee application on buys
- Correct fee splitting: 3% charity, 1% liquidity, 1% burn
- No fees on wallet-to-wallet transfers

#### Sell Flow (from user to pair)
- Fee application on sells
- SwapAndLiquify trigger on sell
- Charity swap trigger on sell
- Counter decrements after swaps

#### Fee Distribution
- Exact 1% burn verification
- Exact 3% charity allocation
- Exact 1% liquidity allocation
- Rounding remainder handling

#### Swap Thresholds
- No swap when below `minTokensForSwap`
- Swap trigger when threshold met
- Owner can update threshold
- Revert on zero threshold

#### Charity ETH Forwarding
- ETH forwarded to charity wallet during swaps
- Skip charity swap if wallet not set
- Owner can change charity wallet
- Revert on zero address charity wallet
- CharitySwap event emission

#### Anti-Whale Limits - MaxTx
- Enforce maxTx for non-excluded addresses
- Allow maxTx for excluded addresses
- Owner can increase maxTx
- Cannot decrease maxTx
- Cannot set maxTx above totalSupply
- Skip maxTx when limits disabled
- Exclude addresses from maxTx checks

#### Anti-Whale Limits - MaxWallet
- Enforce maxWallet for non-excluded addresses
- Allow maxWallet for excluded addresses
- Owner can increase maxWallet
- Cannot decrease maxWallet
- Skip maxWallet for pair address
- Skip maxWallet when limits disabled

#### Disable Limits
- Owner can disable limits
- LimitsDisabled event emission
- Cannot disable twice
- Cannot update limits when disabled

#### SwapAndLiquify Mechanism
- Swap half of liquidity tokens for ETH
- Add liquidity with swapped ETH and remaining tokens
- SwapAndLiquify event emission
- Owner can disable swapAndLiquify
- No trigger during buy (only on sell)

#### Exclusion Lists
- Owner can exclude from fees
- Owner can include after exclusion
- No fees for excluded addresses
- Fees charged when included
- Event emissions for exclusions

#### Owner Functions
- Only owner can set charity wallet
- Only owner can set router
- Only owner can disable limits
- Only owner can update maxTx/maxWallet
- Only owner can manage exclusions
- Owner can transfer ownership
- OwnershipTransferred event emission
- Cannot transfer to zero address

#### Router Management
- Owner can update router
- New pair creation with new router
- UpdateRouter event emission
- Cannot set router to zero address
- Max allowance granted to new router

#### Rescue Functions
- Owner can rescue ERC20 tokens
- Cannot rescue KNR tokens
- Owner can rescue ETH
- Cannot rescue more ETH than balance
- Only owner can rescue

#### Edge Cases
- Zero amount transfer (reverts)
- 1 wei transfer handling
- Very large transfers within limits
- Multiple consecutive swaps
- Odd token amounts in swapAndLiquify
- Reentrancy protection (inSwap flag)
- transferFrom with fees
- Allowance decrease after transferFrom
- transferFrom with insufficient allowance
- Contract receiving ETH
- Skip swap when contract balance insufficient

#### Constants Verification
- TOTAL_FEE = 5
- CHARITY_FEE = 3
- LIQUIDITY_FEE = 1
- BURN_FEE = 1
- DEAD_ADDRESS verification

## Running Tests

```bash
# Install dependencies
npm install --legacy-peer-deps

# Run all tests
npm test

# Run specific test file
npx hardhat test test/KindoraToken.comprehensive.test.js

# Run with gas reporting
REPORT_GAS=true npx hardhat test
```

## Test Coverage Summary

The comprehensive test suite includes:
- **94 test cases** covering all contract functionality
- **Full path coverage** for buy/sell flows
- **Edge case handling** including zero amounts, overflows, and reentrancy
- **Access control verification** for all owner-only functions
- **Event emission checks** for critical operations
- **Integration tests** with UniswapV2-style mocks

## Mock Contracts

The test suite uses mock contracts located in `contracts/mocks/`:

- **MockFactory.sol**: Simulates UniswapV2Factory for pair creation
- **MockRouter.sol**: Simulates UniswapV2Router02 for swaps and liquidity
- **DummyERC20.sol**: Simple ERC20 token for rescue function tests

## Coverage Gaps

The tests cover all specified requirements:
- ✅ Buy/sell flows with fees
- ✅ Fee distribution (charity, liquidity, burn)
- ✅ Swap thresholds and triggers
- ✅ Charity ETH forwarding
- ✅ Anti-whale limits (maxTx, maxWallet)
- ✅ Edge case handling
- ✅ UniswapV2-style integration

## Notes

- Tests use ethers.js v5 compatible with Hardhat toolbox v2
- Mock router sends up to 1 ETH per swap (funded in beforeEach)
- Pair addresses are deterministically generated by MockFactory
- All tests are isolated and can run independently
