// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TaxWithholdingPayments} from "../contracts/TaxWithholdingPayments.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";

/// @dev Random sequences of payments, rule changes, tax authority changes and time jumps.
contract Handler is Test {
    TaxWithholdingPayments internal payments;
    MockERC20 internal token;
    address internal owner;
    address internal payee;
    address[3] internal taxOffices;

    bytes32[3] internal categories = [bytes32("RENT"), bytes32("CLEANING"), bytes32("FREELANCE")];
    address[3] internal payers;

    uint256 public totalPaidByPayers;
    uint256 public totalNet;
    uint256 public totalTax;
    uint256 public payments_;

    constructor(TaxWithholdingPayments p, MockERC20 t, address o, address pe, address tax) {
        payments = p;
        token = t;
        owner = o;
        payee = pe;
        taxOffices = [tax, makeAddr("taxOffice2"), makeAddr("taxOffice3")];
        for (uint256 i; i < 3; i++) {
            payers[i] = makeAddr(string(abi.encodePacked("payer", i)));
            vm.prank(payers[i]);
            token.approve(address(payments), type(uint256).max);
        }
    }

    function pay(uint256 payerSeed, uint256 categorySeed, uint256 base) external {
        address payer = payers[payerSeed % 3];
        bytes32 cat = categories[categorySeed % 3];
        base = bound(base, 1, 1e27);

        TaxWithholdingPayments.TaxRule memory rule = payments.currentRule(cat);
        if (!rule.active) return;
        (TaxWithholdingPayments.Breakdown memory q, uint32 v, address authority) = payments.quote(cat, base);
        token.mint(payer, q.grossAmount);

        uint256 before = token.balanceOf(payer);
        vm.prank(payer);
        payments.pay(keccak256(abi.encode(payments_, payer, base)), cat, address(token), payee, base, v, authority);

        totalPaidByPayers += before - token.balanceOf(payer);
        totalNet += q.netAmount;
        totalTax += q.taxAmount;
        payments_++;
    }

    function changeRule(
        uint256 categorySeed,
        uint16 vatBps,
        uint8 den,
        uint8 num,
        uint16 incomeTaxBps,
        bool active,
        bool withholdVat
    ) external {
        bytes32 cat = categories[categorySeed % 3];
        vatBps = uint16(bound(vatBps, 0, 10_000));
        incomeTaxBps = uint16(bound(incomeTaxBps, 0, 10_000));
        if (withholdVat && vatBps != 0) {
            den = uint8(bound(den, 1, 10));
            num = uint8(bound(num, 1, den));
        } else {
            (num, den) = (0, 0);
        }
        vm.prank(owner);
        payments.scheduleRuleChange(cat, vatBps, num, den, incomeTaxBps, active, uint64(block.timestamp + 1 days));
    }

    /// Taxes may go to a new office over time; the invariant sums all of them.
    function changeTaxAuthority(uint256 seed) external {
        vm.prank(owner);
        payments.scheduleTaxAuthorityChange(taxOffices[seed % 3], uint64(block.timestamp + 1 days));
    }

    function totalTaxReceived() external view returns (uint256 sum) {
        for (uint256 i; i < 3; i++) sum += token.balanceOf(taxOffices[i]);
    }

    function passTime(uint256 secondsToPass) external {
        vm.warp(block.timestamp + bound(secondsToPass, 1, 3 days));
    }
}

contract TaxWithholdingPaymentsInvariantTest is Test {
    TaxWithholdingPayments internal payments;
    MockERC20 internal token;
    Handler internal handler;
    address internal owner = makeAddr("owner");
    address internal payee = makeAddr("payee");
    address internal taxOffice = makeAddr("taxOffice");

    function setUp() public {
        payments = new TaxWithholdingPayments(owner, taxOffice);
        token = new MockERC20();
        vm.startPrank(owner);
        payments.setTokenAllowed(address(token), true);
        payments.addCategory(bytes32("RENT"), 0, 0, 0, 2000);
        payments.addCategory(bytes32("CLEANING"), 2000, 9, 10, 0);
        payments.addCategory(bytes32("FREELANCE"), 2000, 0, 0, 2000);
        vm.stopPrank();

        handler = new Handler(payments, token, owner, payee, taxOffice);
        targetContract(address(handler));
    }

    /// The contract never keeps any money.
    function invariant_ContractHoldsNothing() public view {
        assertEq(token.balanceOf(address(payments)), 0);
    }

    /// Everything payers sent reached the payee or the tax office, nothing more, nothing less.
    function invariant_ValueIsConserved() public view {
        assertEq(handler.totalPaidByPayers(), token.balanceOf(payee) + handler.totalTaxReceived());
        assertEq(token.balanceOf(payee), handler.totalNet());
        assertEq(handler.totalTaxReceived(), handler.totalTax());
    }

    /// One receipt per payment.
    function invariant_ReceiptCountMatchesPayments() public view {
        assertEq(payments.receiptCount(), handler.payments_());
    }
}
