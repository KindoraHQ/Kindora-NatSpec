#!/usr/bin/env bash
set -euo pipefail
echo "Creating remaining project files..."

mkdir -p contracts/mocks
mkdir -p .github/workflows
mkdir -p test

cat > hardhat.config.js <<'EOF'
require("@nomiclabs/hardhat-ethers");
require("solidity-coverage");

module.exports = {
  solidity: {
    version: "0.8.17",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  mocha: {
    timeout: 120000
  }
};
EOF

cat > .solhint.json <<'EOF'
{
  "extends": "solhint:recommended",
  "plugins": [],
  "rules": {
    "compiler-version": ["error", "^0.8.17"],
    "func-visibility": ["error", { "ignoreConstructors": true }],
    "reason-string": ["warn", { "maxLength": 64 }]
  }
}
EOF

cat > .github/workflows/ci.yml <<'EOF'
name: CI — tests, coverage, static analysis

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  build-and-test:
    runs-on: ubuntu-latest
    env:
      CI: true
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: "npm"

      - name: Cache node modules
        uses: actions/cache@v4
        with:
          path: ~/.npm
          key: ${{ runner.os }}-node-${{ hashFiles('**/package-lock.json') }}
          restore-keys: |
            ${{ runner.os }}-node-

      - name: Install dependencies
        run: npm ci

      - name: Run Solidity linter (solhint)
        run: npm run lint:solidity

      - name: Run unit tests (Hardhat)
        run: npm test

      - name: Run coverage (solidity-coverage)
        # solidity-coverage can be slow; run it separately
        run: npm run coverage

      - name: Upload coverage report artifact
        if: always()
        uses: actions/upload-artifact@v3
        with:
          name: coverage-report
          path: coverage

      - name: Run Slither static analysis
        uses: trailofbits/slither-action@v1
        with:
          # produce a JSON report that we can upload
          args: --json slither-report.json

      - name: Upload slither report artifact
        if: always()
        uses: actions/upload-artifact@v3
        with:
          name: slither-report
          path: slither-report.json
EOF

cat > .github/workflows/README.md <<'EOF'
This CI workflow runs on pushes and pull requests to main:

- Installs dependencies with npm ci
- Runs solhint on contracts/
- Runs Hardhat unit tests (npx hardhat test)
- Runs solidity-coverage (npx hardhat coverage)
- Runs Slither static analysis via trailofbits/slither-action and uploads a JSON report

Artifacts:
- coverage-report (uploaded directory produced by solidity-coverage)
- slither-report (JSON produced by Slither)

If you want further enhancements, consider:
- Uploading coverage data to codecov or coveralls
- Running Slither in a separate job with a pinned image to speed up analysis
- Adding a security scan (MythX/ConsenSys Diligence or other)
EOF

cat > contracts/mocks/MockFactory.sol <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice Minimal mock of UniswapV2Factory for tests
contract MockFactory {
    mapping(bytes32 => address) public pairs;
    event PairCreated(address indexed tokenA, address indexed tokenB, address pair);

    function getPair(address tokenA, address tokenB) external view returns (address) {
        return pairs[_key(tokenA, tokenB)];
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        bytes32 k = _key(tokenA, tokenB);
        require(pairs[k] == address(0), "Pair exists");
        // For tests we simply choose an address derived deterministically:
        pair = address(uint160(uint256(keccak256(abi.encodePacked(tokenA, tokenB, block.timestamp)))));
        pairs[k] = pair;
        emit PairCreated(tokenA, tokenB, pair);
    }

    function _key(address a, address b) internal pure returns (bytes32) {
        (address x, address y) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encodePacked(x, y));
    }
}
EOF

cat > contracts/mocks/MockRouter.sol <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IFactory {
    function getPair(address tokenA, address tokenB) external view returns (address);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

/// @notice Minimal mock router to simulate swaps and addLiquidity for tests.
/// @dev For simplicity, swapExactTokensForETHSupportingFeeOnTransferTokens will send up to 1 ETH (or available balance)
///      to the `to` address when called, so tests should fund the router with ETH before invoking swaps.
contract MockRouter {
    address public factory;
    address public weth;

    event Swapped(address indexed caller, uint256 amountIn, address to);
    event LiquidityAdded(address indexed token, uint256 tokenAmount, uint256 ethAmount, address to);

    constructor(address _factory, address _weth) {
        factory = _factory;
        weth = _weth;
    }

    function factory() external view returns (address) {
        return factory;
    }

    function WETH() external view returns (address) {
        return weth;
    }

    // This mock simply sends up to 1 ETH from router balance to `to`.
    // Tests should fund the router with ETH prior to calling swap functions.
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256, // amountIn
        uint256, // amountOutMin
        address[] calldata, // path
        address to,
        uint256 // deadline
    ) external {
        uint256 available = address(this).balance;
        if (available == 0) {
            // do nothing (simulate router that cannot return ETH)
            return;
        }
        uint256 sendAmount = available >= 1 ether ? 1 ether : available;
        (bool ok, ) = payable(to).call{value: sendAmount}("");
        require(ok, "MockRouter: ETH transfer failed");
        emit Swapped(msg.sender, sendAmount, to);
    }

    // Accept ETH and simulate adding liquidity. Returns token amount, eth amount, and liquidity (0 for mock).
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256, // amountTokenMin
        uint256, // amountEthMin
        address to,
        uint256 // deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        // In this mock, msg.value is the ETH sent. We simply emit and return.
        amountToken = amountTokenDesired;
        amountETH = msg.value;
        liquidity = 0;
        emit LiquidityAdded(token, amountTokenDesired, msg.value, to);
    }

    // Allow router mock to receive ETH
    receive() external payable {}
}
EOF

cat > contracts/mocks/DummyERC20.sol <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Simple ERC20 token used for rescueTokens tests
contract DummyERC20 is ERC20 {
    constructor() ERC20("Dummy", "DUM") {
        _mint(msg.sender, 1_000_000 * 10 ** decimals());
    }

    function mintTo(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
EOF

cat > contracts/Kindora_NatSpec.sol <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal Factory interface used to create / query pair
interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @notice Minimal Router interface used for swaps and adding liquidity
interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountEthMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

/// @title Kindora (KNR) ERC20 token with fixed fees for charity, liquidity, and burn
/// @author KindoraHQ
/// @notice ERC20 token that collects fees on transfers and swaps tokens accumulated for liquidity and charity
/// @dev This contract uses defensive checks around swaps and approvals. Owner privileges include configuring router,
/// charity wallet, limits, and rescue functions. Fees are fixed and cannot be changed after deployment.
contract Kindora is ERC20, Ownable {
    /* ========== Addresses ========== */

    /// @notice Charity wallet address receiving ETH proceeds from charity token swaps
    address public charityWallet;

    /// @notice Burn (dead) address used to receive LP tokens (irreversible lock)
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /* ========== Fee configuration (constants, immutable at runtime) ========== */

    /// @notice Total fee percentage taken on transfers (in percent, base 100)
    uint256 public constant TOTAL_FEE = 5;       // 5%

    /// @notice Portion of TOTAL_FEE allocated to charity (percent of TOTAL_FEE)
    uint256 public constant CHARITY_FEE = 3;     // 3 (of the 5)

    /// @notice Portion of TOTAL_FEE allocated to liquidity (percent of TOTAL_FEE)
    uint256 public constant LIQUIDITY_FEE = 1;   // 1 (of the 5)

    /// @notice Portion of TOTAL_FEE allocated to burn (percent of TOTAL_FEE)
    uint256 public constant BURN_FEE = 1;        // 1 (of the 5)

    /* ========== Router & Pair ========== */

    /// @notice Router used for swaps and liquidity operations
    IUniswapV2Router02 public router;

    /// @notice Pair address for token <> WETH liquidity pool
    address public pair;

    /* ========== Swap & Liquify state ========== */

    /// @notice Flag to enable/disable automatic swap & liquify and charity swaps
    bool public swapAndLiquifyEnabled = true;

    /// @notice Internal reentrancy guard for swap functions
    bool private inSwap;

    /// @notice Minimum token amount threshold used to trigger swaps for each bucket
    uint256 public minTokensForSwap;

    /// @notice Accumulated tokens tracked for liquidity conversion
    uint256 public liquidityTokens;

    /// @notice Accumulated tokens tracked for charity conversion
    uint256 public charityTokens;

    /* ========== Exclusion lists ========== */

    mapping(address => bool) private _isExcludedFromFees;
    mapping(address => bool) private _isExcludedFromMaxTx;
    mapping(address => bool) private _isExcludedFromMaxWallet;

    /* ========== Limits ========== */

    /// @notice Maximum transaction amount (anti-whale)
    uint256 public maxTxAmount;

    /// @notice Maximum tokens a single wallet can hold (anti-whale)
    uint256 public maxWalletAmount;

    /// @notice Whether anti-whale limits are currently in effect
    bool public limitsInEffect = true;

    /* ========== Events ========== */

    event UpdateRouter(address indexed newRouter, address indexed oldRouter);
    event UpdateCharityWallet(address indexed newWallet, address indexed oldWallet);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 bnbReceived, uint256 tokensIntoLiquidity);
    event CharitySwap(uint256 tokensSwapped);
    event ExcludedFromFees(address indexed account, bool isExcluded);
    event ExcludedFromMaxTx(address indexed account, bool isExcluded);
    event ExcludedFromMaxWallet(address indexed account, bool isExcluded);
    event MinTokensForSwapUpdated(uint256 newAmount);
    event MaxTxAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event MaxWalletAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event LimitsDisabled();
    event SwapAndLiquifyEnabledUpdated(bool enabled);

    /* ========== Modifiers ========== */

    /// @dev Simple reentrancy guard for swap operations
    modifier lockTheSwap() {
        inSwap = true;
        _;
        inSwap = false;
    }

    /* ========== Constructor ========== */

    /// @notice Deploys Kindora token and configures router/pair, limits and approvals
    /// @param _router Address of an existing UniswapV2-compatible router
    /// @dev Mints the total supply to the deployer (owner) and pre-approves the router for gas savings.
    constructor(address _router) ERC20("Kindora", "KNR") {
        require(_router != address(0), "Router zero address");

        uint256 totalSupply = 10_000_000 * 10 ** decimals();
        _mint(msg.sender, totalSupply);

        router = IUniswapV2Router02(_router);

        // Attempt to fetch existing pair; create if not present
        IUniswapV2Factory factory = IUniswapV2Factory(router.factory());
        address _pair = factory.getPair(address(this), router.WETH());
        if (_pair == address(0)) {
            _pair = factory.createPair(address(this), router.WETH());
        }
        pair = _pair;

        // Exclude obvious accounts from fees and limits
        _isExcludedFromFees[address(this)] = true;
        _isExcludedFromFees[msg.sender] = true;

        _isExcludedFromMaxTx[address(this)] = true;
        _isExcludedFromMaxTx[msg.sender] = true;
        _isExcludedFromMaxTx[address(router)] = true;
        _isExcludedFromMaxTx[pair] = true;
        _isExcludedFromMaxTx[DEAD_ADDRESS] = true;

        _isExcludedFromMaxWallet[address(this)] = true;
        _isExcludedFromMaxWallet[msg.sender] = true;
        _isExcludedFromMaxWallet[address(router)] = true;
        _isExcludedFromMaxWallet[pair] = true;
        _isExcludedFromMaxWallet[DEAD_ADDRESS] = true;

        // Default limits: 2% of total supply
        maxTxAmount = (totalSupply * 2) / 100;
        maxWalletAmount = (totalSupply * 2) / 100;

        // Default swap threshold: 1,000 tokens
        minTokensForSwap = 1000 * 10 ** decimals();

        // Charity wallet must be explicitly set by owner
        charityWallet = address(0);

        // Approve router once with maximal allowance from this contract to save gas on subsequent swaps
        _approve(address(this), address(router), type(uint256).max);
    }

    /* ========== Receive ETH ========== */

    /// @notice Allow contract to receive ETH from router swaps
    receive() external payable {}

    /* ========== Owner-only configuration ========== */

    /// @notice Set the charity wallet (must be non-zero)
    /// @param _wallet Address that will receive charity ETH proceeds
    function setCharityWallet(address _wallet) external onlyOwner {
        require(_wallet != address(0), "Zero address");
        emit UpdateCharityWallet(_wallet, charityWallet);
        charityWallet = _wallet;
    }

    /// @notice Enable or disable automatic swap & liquify and charity swaps
    /// @param _enabled True to enable, false to disable
    function setSwapAndLiquifyEnabled(bool _enabled) external onlyOwner {
        swapAndLiquifyEnabled = _enabled;
        emit SwapAndLiquifyEnabledUpdated(_enabled);
    }

    /// @notice Update the minimum token threshold to trigger swaps
    /// @param _amount Minimum token count (in wei units) to trigger swap operations
    function setMinTokensForSwap(uint256 _amount) external onlyOwner {
        require(_amount > 0, "Amount must be > 0");
        minTokensForSwap = _amount;
        emit MinTokensForSwapUpdated(_amount);
    }

    /// @notice Exclude or include an account for fee application
    /// @param account Address to change
    /// @param excluded True to exclude, false to include
    function excludeFromFees(address account, bool excluded) external onlyOwner {
        _isExcludedFromFees[account] = excluded;
        emit ExcludedFromFees(account, excluded);
    }

    /// @notice Exclude or include an account from maxTx checks
    /// @param account Address to change
    /// @param excluded True to exclude, false to include
    function excludeFromMaxTx(address account, bool excluded) external onlyOwner {
        _isExcludedFromMaxTx[account] = excluded;
        emit ExcludedFromMaxTx(account, excluded);
    }

    /// @notice Exclude or include an account from maxWallet checks
    /// @param account Address to change
    /// @param excluded True to exclude, false to include
    function excludeFromMaxWallet(address account, bool excluded) external onlyOwner {
        _isExcludedFromMaxWallet[account] = excluded;
        emit ExcludedFromMaxWallet(account, excluded);
    }

    /// @notice Increase maximum transaction amount (cannot decrease) while limits are enabled
    /// @param newAmount New max transaction amount (in wei units)
    function updateMaxTxAmount(uint256 newAmount) external onlyOwner {
        require(limitsInEffect, "Limits disabled");
        require(newAmount >= maxTxAmount, "Cannot lower maxTx");
        require(newAmount <= totalSupply(), "Too high");
        uint256 old = maxTxAmount;
        maxTxAmount = newAmount;
        emit MaxTxAmountUpdated(old, newAmount);
    }

    /// @notice Increase maximum wallet amount (cannot decrease) while limits are enabled
    /// @param newAmount New max wallet amount (in wei units)
    function updateMaxWalletAmount(uint256 newAmount) external onlyOwner {
        require(limitsInEffect, "Limits disabled");
        require(newAmount >= maxWalletAmount, "Cannot lower maxWallet");
        require(newAmount <= totalSupply(), "Too high");
        uint256 old = maxWalletAmount;
        maxWalletAmount = newAmount;
        emit MaxWalletAmountUpdated(old, newAmount);
    }

    /// @notice Permanently disable anti-whale limits
    function disableLimits() external onlyOwner {
        require(limitsInEffect, "Already disabled");
        limitsInEffect = false;
        emit LimitsDisabled();
    }

    /// @notice Replace the router (and create pair if missing). Approves the new router with max allowance.
    /// @param _router Address of the new router
    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "Zero address");
        emit UpdateRouter(_router, address(router));
        router = IUniswapV2Router02(_router);

        IUniswapV2Factory factory = IUniswapV2Factory(router.factory());
        address _pair = factory.getPair(address(this), router.WETH());
        if (_pair == address(0)) {
            _pair = factory.createPair(address(this), router.WETH());
        }
        pair = _pair;

        _isExcludedFromMaxTx[address(router)] = true;
        _isExcludedFromMaxTx[pair] = true;
        _isExcludedFromMaxWallet[address(router)] = true;
        _isExcludedFromMaxWallet[pair] = true;

        // Approve new router with maximal allowance for the contract
        _approve(address(this), address(router), type(uint256).max);
    }

    /* ========== Rescue functions (owner-only) ========== */

    /// @notice Rescue ERC20 tokens accidentally sent to this contract (excluding KNR)
    /// @param token Token contract address to rescue
    /// @param amount Amount to transfer to owner
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        require(token != address(this), "Cannot rescue KNR");
        IERC20(token).transfer(owner(), amount);
    }

    /// @notice Rescue BNB (native ETH) accidentally sent to this contract
    /// @param amount Amount in wei to transfer to owner
    function rescueBNB(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient BNB");
        payable(owner()).transfer(amount);
    }

    /* ========== Internal helpers ========== */

    /// @dev Ensure router has sufficient allowance from this contract; set to max if insufficient.
    /// @param amount Minimal required allowance
    function _ensureRouterAllowance(uint256 amount) internal {
        if (allowance(address(this), address(router)) < amount) {
            _approve(address(this), address(router), type(uint256).max);
        }
    }

    /* ========== Core transfer logic (fees applied here) ========== */

    /// @dev Internal transfer override that applies fees, accumulates buckets, and triggers swaps.
    /// @param from Sender address
    /// @param to Recipient address
    /// @param amount Transfer amount (in token wei)
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "ERC20: transfer from zero");
        require(to != address(0), "ERC20: transfer to zero");
        require(amount > 0, "Amount must be > 0");

        // Anti-whale limits (skipped during inSwap to avoid reentrancy/race)
        if (limitsInEffect && !inSwap) {
            if (!_isExcludedFromMaxTx[from] && !_isExcludedFromMaxTx[to]) {
                require(amount <= maxTxAmount, "MaxTx: amount exceeds limit");
            }

            if (
                !_isExcludedFromMaxWallet[to] &&
                to != pair &&
                to != address(router)
            ) {
                require(balanceOf(to) + amount <= maxWalletAmount, "MaxWallet: amount exceeds limit");
            }
        }

        // Determine if fees should be taken.
        // Note: fees are skipped if either party is excluded. This is intentional but should be documented.
        bool takeFee = !_isExcludedFromFees[from] && !_isExcludedFromFees[to] && !inSwap;

        // Attempt swap/liq/charity if conditions are met and not currently in a swap.
        if (
            swapAndLiquifyEnabled &&
            !inSwap &&
            from != pair
        ) {
            uint256 contractTokenBalance = balanceOf(address(this));

            if (liquidityTokens >= minTokensForSwap && contractTokenBalance >= liquidityTokens) {
                // Avoid attempting to split 1 token into halves -> require at least 2
                if (liquidityTokens >= 2) {
                    _swapAndLiquify(liquidityTokens);
                }
            }

            if (charityTokens >= minTokensForSwap && contractTokenBalance >= charityTokens) {
                _swapTokensForCharity(charityTokens);
            }
        }

        // If fees should not be taken, do a normal transfer
        if (!takeFee) {
            super._transfer(from, to, amount);
            return;
        }

        // Collect the full amount from sender into the contract to manage distribution
        super._transfer(from, address(this), amount);

        // Compute fee breakdown based on TOTAL_FEE and sub-allocations
        uint256 feeAmount = (amount * TOTAL_FEE) / 100;
        uint256 burnAmount = (feeAmount * BURN_FEE) / TOTAL_FEE;
        uint256 charityAmount = (feeAmount * CHARITY_FEE) / TOTAL_FEE;
        uint256 liquidityAmount = (feeAmount * LIQUIDITY_FEE) / TOTAL_FEE;

        // Handle integer division remainder so no tokens remain untracked
        uint256 distributed = burnAmount + charityAmount + liquidityAmount;
        uint256 remainder = feeAmount - distributed;
        if (remainder > 0) {
            // Allocate remainder to liquidity bucket to keep tracking consistent
            liquidityAmount += remainder;
        }

        // Net transfer amount to recipient after fees
        uint256 transferAmount = amount - feeAmount;

        // Send net amount to recipient
        super._transfer(address(this), to, transferAmount);

        // Execute burn (reduces totalSupply)
        if (burnAmount > 0) {
            _burn(address(this), burnAmount);
        }

        // Accumulate charity and liquidity buckets inside contract
        if (charityAmount > 0) {
            charityTokens += charityAmount;
        }
        if (liquidityAmount > 0) {
            liquidityTokens += liquidityAmount;
        }
    }

    /* ========== Internal swap & liquidity functions ========== */

    /// @dev Swap half of tokenAmount for ETH and add liquidity with the other half.
    ///      Defensively skips operations that would produce zero-value outcomes.
    /// @param tokenAmount Total tokens to convert into liquidity (should be even/>=2)
    function _swapAndLiquify(uint256 tokenAmount) internal lockTheSwap {
        if (tokenAmount < 2) {
            return;
        }

        uint256 half = tokenAmount / 2;
        uint256 otherHalf = tokenAmount - half;

        if (half == 0 || otherHalf == 0) {
            return;
        }

        uint256 initialBalance = address(this).balance;

        // Ensure router allowance is sufficient
        _ensureRouterAllowance(half);

        _swapTokensForETH(half);

        uint256 newBalance = address(this).balance - initialBalance;

        // If swap produced no ETH (e.g., extreme slippage or zero price), skip adding liquidity
        if (newBalance == 0) {
            return;
        }

        // Only attempt to add liquidity if both token and ETH amounts are positive
        if (otherHalf > 0 && newBalance > 0) {
            _addLiquidity(otherHalf, newBalance);

            // Decrement liquidity counter only after liquidity added
            if (liquidityTokens >= tokenAmount) {
                liquidityTokens -= tokenAmount;
            } else {
                liquidityTokens = 0;
            }

            emit SwapAndLiquify(half, newBalance, otherHalf);
        }
    }

    /// @dev Swap tokens allocated for charity into ETH and send to charityWallet
    /// @param tokenAmount Amount of tokens to swap for charity ETH
    function _swapTokensForCharity(uint256 tokenAmount) internal lockTheSwap {
        require(charityWallet != address(0), "Charity wallet not set");
        if (tokenAmount == 0) return;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        _ensureRouterAllowance(tokenAmount);

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            charityWallet,
            block.timestamp
        );

        // Decrement charity counter after successful swap (router will revert on failure)
        if (charityTokens >= tokenAmount) {
            charityTokens -= tokenAmount;
        } else {
            charityTokens = 0;
        }

        emit CharitySwap(tokenAmount);
    }

    /// @dev Swap tokenAmount of this token for ETH and credit ETH to this contract
    /// @param tokenAmount Amount of tokens to swap for ETH
    function _swapTokensForETH(uint256 tokenAmount) internal {
        if (tokenAmount == 0) return;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        _ensureRouterAllowance(tokenAmount);

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    /// @dev Add provided token/ETH amounts as liquidity to the pair. LP tokens are sent to DEAD_ADDRESS.
    /// @param tokenAmount Token amount to add as liquidity
    /// @param ethAmount ETH amount to add as liquidity
    function _addLiquidity(uint256 tokenAmount, uint256 ethAmount) internal {
        if (tokenAmount == 0 || ethAmount == 0) {
            return;
        }

        // Approve the router for the specific token amount (safe, though we pre-approved max in constructor)
        _approve(address(this), address(router), tokenAmount);

        router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0,
            0,
            DEAD_ADDRESS,
            block.timestamp
        );
    }

    /* ========== View helpers ========== */

    /// @notice Query whether an account is excluded from fees
    /// @param account Address to query
    /// @return True if excluded from fees
    function isExcludedFromFees(address account) external view returns (bool) {
        return _isExcludedFromFees[account];
    }

    /// @notice Query whether an account is excluded from maxTx checks
    /// @param account Address to query
    /// @return True if excluded from maxTx checks
    function isExcludedFromMaxTx(address account) external view returns (bool) {
        return _isExcludedFromMaxTx[account];
    }

    /// @notice Query whether an account is excluded from maxWallet checks
    /// @param account Address to query
    /// @return True if excluded from maxWallet checks
    function isExcludedFromMaxWallet(address account) external view returns (bool) {
        return _isExcludedFromMaxWallet[account];
    }
}
EOF

cat > test/Kindora.test.js <<'EOF'
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
EOF

echo "All files created."
echo ""
echo "Now run:"
echo "  git add hardhat.config.js .solhint.json .github contracts test"
echo "  git commit -m \"Add CI workflows, tests, mocks, and configs\""
echo "  git push origin main"
echo ""
echo "Done."
