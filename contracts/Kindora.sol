// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Kindora_NatSpec.sol";

/// @notice Alias contract to expose KindoraToken with a simpler name for testing
contract Kindora is KindoraToken {
    constructor(address _router) KindoraToken(_router) {}
}
