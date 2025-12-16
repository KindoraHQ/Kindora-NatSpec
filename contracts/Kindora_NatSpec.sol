// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts@4.9.3/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts@4.9.3/security/ReentrancyGuard.sol";

/// @notice Minimal Factory interface used to create / query pair
interface IUniswapV2FactoryKindora {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @notice Minimal Router interface used for swaps and adding liquidity
interface IUniswapV2Router02Kindora {
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

/// @dev Minimal Ownable implementation
abstract contract KindoraOwnable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), _owner);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(msg.sender == _owner, "Ownable: caller is not the owner");
        _;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    function renounceOwnership() public onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }
}

/// @title Kindora (KNR) ERC20 token with fixed fees for charity, liquidity, and burn
contract KindoraToken is ERC20, KindoraOwnable, ReentrancyGuard {
    /* ========== Addresses ========== */

    address public charityWallet;
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /* ========== Fee configuration ========== */

    uint256 public constant TOTAL_FEE = 5;       // 5%
    uint256 public constant CHARITY_FEE = 3;     // 3
    uint256 public constant LIQUIDITY_FEE = 1;   // 1
    uint256 public constant BURN_FEE = 1;        // 1

    /* ========== Router & Pair ========== */

    IUniswapV2Router02Kindora public router;
    address public pair;

    /* ========== Swap & Liquify state ========== */

    bool public swapAndLiquifyEnabled = true;
    bool private inSwap;
    uint256 public minTokensForSwap;
    uint256 public liquidityTokens;
    uint256 public charityTokens;

    /* ========== Exclusion lists ========== */

    mapping(address => bool) private _isExcludedFromFees;
    mapping(address => bool) private _isExcludedFromMaxTx;
    mapping(address => bool) private _isExcludedFromMaxWallet;

    /* ========== Limits ========== */

    uint256 public maxTxAmount;
    uint256 public maxWalletAmount;
    bool public limitsInEffect = true;

    /* ========== Events ========== */

    event UpdateRouter(address indexed newRouter, address indexed oldRouter);
    event UpdateCharityWallet(address indexed newWallet, address indexed oldWallet);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 tokensIntoLiquidity);
    event CharitySwap(uint256 tokensSwapped, uint256 ethReceived);
    event ExcludedFromFees(address indexed account, bool isExcluded);
    event ExcludedFromMaxTx(address indexed account, bool isExcluded);
    event ExcludedFromMaxWallet(address indexed account, bool isExcluded);
    event MinTokensForSwapUpdated(uint256 newAmount);
    event MaxTxAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event MaxWalletAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event LimitsDisabled();
    event SwapAndLiquifyEnabledUpdated(bool enabled);

    /* ========== Modifiers ========== */

    modifier lockTheSwap() {
        inSwap = true;
        _;
        inSwap = false;
    }

    /* ========== Constructor ========== */

    constructor(address _router, address _charityWallet) ERC20("Kindora", "KNR") {
        require(_router != address(0), "Router zero address");
        require(_charityWallet != address(0), "Charity wallet zero address");

        uint256 totalSupply_ = 10_000_000 * 10 ** decimals();
        _mint(msg.sender, totalSupply_);

        router = IUniswapV2Router02Kindora(_router);
        charityWallet = _charityWallet;

        IUniswapV2FactoryKindora factory = IUniswapV2FactoryKindora(router.factory());
        address _pair = factory.getPair(address(this), router.WETH());
        if (_pair == address(0)) {
            _pair = factory.createPair(address(this), router.WETH());
        }
        pair = _pair;

        _isExcludedFromFees[address(this)] = true;
        _isExcludedFromFees[msg.sender] = true;
        _isExcludedFromFees[DEAD_ADDRESS] = true;

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

        maxTxAmount = (totalSupply_ * 2) / 100;
        maxWalletAmount = (totalSupply_ * 2) / 100;
        minTokensForSwap = 1000 * 10 ** decimals();

        _approve(address(this), address(router), type(uint256).max);
    }

    /* ========== Receive ETH ========== */

    receive() external payable {}

    /* ========== Owner-only configuration ========== */

    function setCharityWallet(address _wallet) external onlyOwner {
        require(_wallet != address(0), "Zero address");
        emit UpdateCharityWallet(_wallet, charityWallet);
        charityWallet = _wallet;
    }

    function setSwapAndLiquifyEnabled(bool _enabled) external onlyOwner {
        swapAndLiquifyEnabled = _enabled;
        emit SwapAndLiquifyEnabledUpdated(_enabled);
    }

    function setMinTokensForSwap(uint256 _amount) external onlyOwner {
        require(_amount > 0, "Amount must be > 0");
        minTokensForSwap = _amount;
        emit MinTokensForSwapUpdated(_amount);
    }

    function excludeFromFees(address account, bool excluded) external onlyOwner {
        _isExcludedFromFees[account] = excluded;
        emit ExcludedFromFees(account, excluded);
    }

    function excludeFromMaxTx(address account, bool excluded) external onlyOwner {
        _isExcludedFromMaxTx[account] = excluded;
        emit ExcludedFromMaxTx(account, excluded);
    }

    function excludeFromMaxWallet(address account, bool excluded) external onlyOwner {
        _isExcludedFromMaxWallet[account] = excluded;
        emit ExcludedFromMaxWallet(account, excluded);
    }

    function updateMaxTxAmount(uint256 newAmount) external onlyOwner {
        require(limitsInEffect, "Limits disabled");
        require(newAmount >= maxTxAmount, "Cannot lower maxTx");
        require(newAmount <= totalSupply(), "Too high");
        uint256 old = maxTxAmount;
        maxTxAmount = newAmount;
        emit MaxTxAmountUpdated(old, newAmount);
    }

    function updateMaxWalletAmount(uint256 newAmount) external onlyOwner {
        require(limitsInEffect, "Limits disabled");
        require(newAmount >= maxWalletAmount, "Cannot lower maxWallet");
        require(newAmount <= totalSupply(), "Too high");
        uint256 old = maxWalletAmount;
        maxWalletAmount = newAmount;
        emit MaxWalletAmountUpdated(old, newAmount);
    }

    function disableLimits() external onlyOwner {
        require(limitsInEffect, "Already disabled");
        limitsInEffect = false;
        emit LimitsDisabled();
    }

    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "Zero address");
        emit UpdateRouter(_router, address(router));
        router = IUniswapV2Router02Kindora(_router);

        IUniswapV2FactoryKindora factory = IUniswapV2FactoryKindora(router.factory());
        address _pair = factory.getPair(address(this), router.WETH());
        if (_pair == address(0)) {
            _pair = factory.createPair(address(this), router.WETH());
        }
        pair = _pair;

        _isExcludedFromMaxTx[address(router)] = true;
        _isExcludedFromMaxTx[pair] = true;
        _isExcludedFromMaxWallet[address(router)] = true;
        _isExcludedFromMaxWallet[pair] = true;

        _approve(address(this), address(router), type(uint256).max);
    }

    /* ========== Rescue functions ========== */

    function rescueTokens(address token, uint256 amount) external onlyOwner {
        require(token != address(this), "Cannot rescue KNR");
        IERC20(token).transfer(owner(), amount);
    }

    function rescueETH(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient ETH");
        payable(owner()).transfer(amount);
    }

    /* ========== Internal helpers ========== */

    function _ensureRouterAllowance(uint256 amount) internal {
        if (allowance(address(this), address(router)) < amount) {
            _approve(address(this), address(router), type(uint256).max);
        }
    }

    /* ========== Core transfer logic ========== */

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        require(from != address(0), "ERC20: transfer from zero address");
        require(to != address(0), "ERC20: transfer to zero address");
        require(amount > 0, "Amount must be > 0");

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

        bool isBuy = from == pair;
        bool isSell = to == pair;

        bool takeFee = (isBuy || isSell) &&
            !_isExcludedFromFees[from] &&
            !_isExcludedFromFees[to] &&
            !inSwap;

        if (
            swapAndLiquifyEnabled &&
            !inSwap &&
            isSell &&
            from != pair
        ) {
            _processAccumulatedTokens();
        }

        if (!takeFee) {
            super._transfer(from, to, amount);
            return;
        }

        uint256 feeAmount = (amount * TOTAL_FEE) / 100;
        uint256 burnAmount = (feeAmount * BURN_FEE) / TOTAL_FEE;
        uint256 charityAmount = (feeAmount * CHARITY_FEE) / TOTAL_FEE;
        uint256 liquidityAmount = (feeAmount * LIQUIDITY_FEE) / TOTAL_FEE;

        uint256 distributed = burnAmount + charityAmount + liquidityAmount;
        uint256 remainder = feeAmount - distributed;
        if (remainder > 0) {
            liquidityAmount += remainder;
        }

        uint256 transferAmount = amount - feeAmount;

        if (burnAmount > 0) {
            super._transfer(from, address(this), burnAmount);
            _burn(address(this), burnAmount);
        }

        uint256 contractFee = charityAmount + liquidityAmount;
        if (contractFee > 0) {
            super._transfer(from, address(this), contractFee);
            
            charityTokens += charityAmount;
            liquidityTokens += liquidityAmount;
        }

        super._transfer(from, to, transferAmount);
    }

    function _processAccumulatedTokens() internal {
        uint256 contractTokenBalance = balanceOf(address(this));

        if (liquidityTokens >= minTokensForSwap && contractTokenBalance >= liquidityTokens) {
            uint256 tokensToProcess = liquidityTokens;
            if (tokensToProcess >= 2) {
                _swapAndLiquify(tokensToProcess);
            }
        }

        if (charityTokens >= minTokensForSwap && contractTokenBalance >= charityTokens) {
            uint256 tokensToProcess = charityTokens;
            _swapTokensForCharity(tokensToProcess);
        }
    }

    /* ========== Internal swap & liquidity functions ========== */

    function _swapAndLiquify(uint256 tokenAmount) internal lockTheSwap nonReentrant {
        if (tokenAmount < 2) {
            return;
        }

        if (liquidityTokens >= tokenAmount) {
            liquidityTokens -= tokenAmount;
        } else {
            liquidityTokens = 0;
        }

        uint256 half = tokenAmount / 2;
        uint256 otherHalf = tokenAmount - half;

        if (half == 0 || otherHalf == 0) {
            return;
        }

        uint256 initialBalance = address(this).balance;

        _ensureRouterAllowance(half);
        _swapTokensForETH(half);

        uint256 newBalance = address(this).balance - initialBalance;

        if (newBalance > 0 && otherHalf > 0) {
            _addLiquidity(otherHalf, newBalance);
            emit SwapAndLiquify(half, newBalance, otherHalf);
        }
    }

    function _swapTokensForCharity(uint256 tokenAmount) internal lockTheSwap nonReentrant {
        if (charityWallet == address(0) || tokenAmount == 0) {
            return;
        }

        if (charityTokens >= tokenAmount) {
            charityTokens -= tokenAmount;
        } else {
            charityTokens = 0;
        }

        uint256 initialBalance = address(this).balance;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        _ensureRouterAllowance(tokenAmount);

        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        ) {
            uint256 ethReceived = address(this).balance - initialBalance;
            
            if (ethReceived > 0) {
                (bool success, ) = payable(charityWallet).call{value: ethReceived}("");
                require(success, "Charity transfer failed");
                emit CharitySwap(tokenAmount, ethReceived);
            }
        } catch {
            charityTokens += tokenAmount;
        }
    }

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

    function _addLiquidity(uint256 tokenAmount, uint256 ethAmount) internal {
        if (tokenAmount == 0 || ethAmount == 0) {
            return;
        }

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

    /* ========== Manual swap function ========== */

    function manualSwapAndLiquify() external onlyOwner {
        uint256 contractTokenBalance = balanceOf(address(this));
        require(contractTokenBalance > 0, "No tokens to swap");
        
        if (liquidityTokens > 0) {
            uint256 tokensToSwap = liquidityTokens > contractTokenBalance ? contractTokenBalance : liquidityTokens;
            if (tokensToSwap >= 2) {
                _swapAndLiquify(tokensToSwap);
            }
        }
        
        if (charityTokens > 0) {
            uint256 tokensToSwap = charityTokens > contractTokenBalance ? contractTokenBalance : charityTokens;
            _swapTokensForCharity(tokensToSwap);
        }
    }

    /* ========== View helpers ========== */

    function isExcludedFromFees(address account) external view returns (bool) {
        return _isExcludedFromFees[account];
    }

    function isExcludedFromMaxTx(address account) external view returns (bool) {
        return _isExcludedFromMaxTx[account];
    }

    function isExcludedFromMaxWallet(address account) external view returns (bool) {
        return _isExcludedFromMaxWallet[account];
    }

    function getAccumulatedTokens() external view returns (uint256 charity, uint256 liquidity) {
        return (charityTokens, liquidityTokens);
    }
}
