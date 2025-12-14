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
    address private _factory;
    address private _weth;

    event Swapped(address indexed caller, uint256 amountIn, address to);
    event LiquidityAdded(address indexed token, uint256 tokenAmount, uint256 ethAmount, address to);

    constructor(address factory_, address weth_) {
        _factory = factory_;
        _weth = weth_;
    }

    function factory() external view returns (address) {
        return _factory;
    }

    function WETH() external view returns (address) {
        return _weth;
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
