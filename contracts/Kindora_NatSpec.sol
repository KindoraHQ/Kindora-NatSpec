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
/// @notice ERC20 token that collects fees on buys/sells and swaps tokens accumulated for liquidity and charity
/// @dev Fees are applied only on trades with the DEX pair (buy/sell), not on wallet-to-wallet transfers.
contract Kindora is ERC20, Ownable {
    /* ========== Addresses ========== */

    /// @notice Charity wallet address receiving ETH proceeds from charity token swaps
    address public charityWallet;

    /// @notice Burn (dead) address used to receive LP tokens (irreversible lock)
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /* ========== Fee configuration (constants, immutable at runtime) ========== */

    /// @notice Total fee percentage taken on buys/sells (in percent, base 100)
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

    /// @dev Internal transfer override that applies fees on buys/sells, accumulates buckets, and triggers swaps.
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

        // Detect trade type
        bool isBuy = from == pair;
        bool isSell = to == pair;

        // Only take fees on buys/sells with the pair, not on wallet-to-wallet transfers
        bool takeFee = (isBuy || isSell) &&
            !_isExcludedFromFees[from] &&
            !_isExcludedFromFees[to] &&
            !inSwap;

        // Attempt swap/liq/charity if conditions are met and not currently in a swap.
        if (
            swapAndLiquifyEnabled &&
            !inSwap &&
            from != pair
        ) {
            uint256 contractTokenBalance = balanceOf(address(this));

            if (liquidityTokens >= minTokensForSwap && contractTokenBalance >= liquidityTokens) {
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
        // If charity wallet not set or tokenAmount is zero, skip to avoid blocking trading
        if (charityWallet == address(0) || tokenAmount == 0) {
            return;
        }

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
