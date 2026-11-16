// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TaxWithholdingPayments} from "../TaxWithholdingPayments.sol";

/// @dev Tests only. Malicious token: on every transferFrom it tries to call `pay` again with a fresh
///      invoice hash. Used to prove that the reentrancy guard blocks the nested call.
contract ReentrantToken is ERC20 {
    TaxWithholdingPayments public target;
    bytes32 public category;
    uint32 public version;
    address public taxAuthority;
    bool public attacking;

    constructor() ERC20("Evil", "EVIL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(TaxWithholdingPayments target_, bytes32 category_, uint32 version_, address taxAuthority_)
        external
    {
        target = target_;
        taxAuthority = taxAuthority_;
        category = category_;
        version = version_;
        attacking = true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (attacking) {
            attacking = false;
            target.pay(keccak256("nested-invoice"), category, address(this), to, 1 ether, version, taxAuthority);
        }
        return super.transferFrom(from, to, value);
    }
}
