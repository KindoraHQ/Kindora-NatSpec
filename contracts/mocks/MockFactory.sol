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
