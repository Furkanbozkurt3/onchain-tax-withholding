// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Plain token for tests and the local demo (stands in for a stablecoin).
///      Anyone can mint. NEVER deploy to a real network.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Stablecoin", "mUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
