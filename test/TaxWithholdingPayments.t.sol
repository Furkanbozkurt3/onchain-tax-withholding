// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TaxWithholdingPayments} from "../contracts/TaxWithholdingPayments.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {ReentrantToken} from "../contracts/mocks/ReentrantToken.sol";

/// Example categories (illustrative rates, see README):
/// RENT      : workplace rent from an individual - no VAT, 20% income tax withholding (stopaj)
/// CLEANING  : cleaning service - 20% VAT, 9/10 VAT withholding (KDV tevkifati)
/// FREELANCE : self-employed professional fee - 20% VAT, 20% income tax withholding
contract TaxWithholdingPaymentsTest is Test {
    TaxWithholdingPayments internal payments;
    MockERC20 internal token;

    address internal owner = makeAddr("owner");
    address internal taxOffice = makeAddr("taxOffice");
    address internal payer = makeAddr("payer");
    address internal payee = makeAddr("payee");
    address internal attacker = makeAddr("attacker");

    bytes32 internal constant RENT = bytes32("RENT");
    bytes32 internal constant CLEANING = bytes32("CLEANING");
    bytes32 internal constant FREELANCE = bytes32("FREELANCE");

    function setUp() public {
        payments = new TaxWithholdingPayments(owner, taxOffice);
        token = new MockERC20();

        vm.startPrank(owner);
        payments.setTokenAllowed(address(token), true);
        payments.addCategory(RENT, 0, 0, 0, 2000);
        payments.addCategory(CLEANING, 2000, 9, 10, 0);
        payments.addCategory(FREELANCE, 2000, 0, 0, 2000);
        vm.stopPrank();

        token.mint(payer, 1_000_000 ether);
        vm.prank(payer);
        token.approve(address(payments), type(uint256).max);
    }

    function _pay(bytes32 invoice, bytes32 category, uint256 base) internal returns (uint256) {
        vm.prank(payer);
        return payments.pay(invoice, category, address(token), payee, base, 1, taxOffice);
    }

    // ------------------------------------------------------------------
    // Correct splits
    // ------------------------------------------------------------------

    function test_Rent_WithholdsIncomeTax() public {
        _pay(keccak256("INV-RENT-1"), RENT, 10_000 ether);

        assertEq(token.balanceOf(payee), 8_000 ether, "net rent");
        assertEq(token.balanceOf(taxOffice), 2_000 ether, "stopaj");
        assertEq(token.balanceOf(payer), 1_000_000 ether - 10_000 ether, "payer paid base only");
        assertEq(token.balanceOf(address(payments)), 0, "contract holds nothing");
    }

    function test_Cleaning_WithholdsNineTenthsOfVat() public {
        _pay(keccak256("INV-CLEAN-1"), CLEANING, 1_000 ether);

        // VAT 200, withheld 180, payee gets 1000 + 20
        assertEq(token.balanceOf(payee), 1_020 ether, "net");
        assertEq(token.balanceOf(taxOffice), 180 ether, "VAT withholding");
        assertEq(token.balanceOf(payer), 1_000_000 ether - 1_200 ether, "gross");
    }

    function test_Freelance_VatAndIncomeTax() public {
        _pay(keccak256("INV-FREE-1"), FREELANCE, 1_000 ether);

        // VAT 200 to payee, stopaj 200 to tax office
        assertEq(token.balanceOf(payee), 1_000 ether, "net");
        assertEq(token.balanceOf(taxOffice), 200 ether, "stopaj");
        assertEq(token.balanceOf(payer), 1_000_000 ether - 1_200 ether, "gross");
    }

    function test_Quote_MatchesPayment() public view {
        (TaxWithholdingPayments.Breakdown memory b, uint32 version, address authority) =
            payments.quote(CLEANING, 1_000 ether);
        assertEq(version, 1);
        assertEq(authority, taxOffice);
        assertEq(b.vatAmount, 200 ether);
        assertEq(b.vatWithheld, 180 ether);
        assertEq(b.incomeTaxWithheld, 0);
        assertEq(b.grossAmount, 1_200 ether);
        assertEq(b.netAmount, 1_020 ether);
        assertEq(b.taxAmount, 180 ether);
    }

    function test_Receipt_IsStored() public {
        bytes32 invoice = keccak256("INV-FREE-2");
        vm.warp(1_800_000_000);
        uint256 id = _pay(invoice, FREELANCE, 500 ether);

        TaxWithholdingPayments.Receipt memory r = payments.receipt(id);
        assertEq(id, 1);
        assertEq(payments.receiptCount(), 1);
        assertEq(payments.receiptIdOf(payer, invoice), 1);
        assertEq(r.invoiceHash, invoice);
        assertEq(r.category, FREELANCE);
        assertEq(r.payer, payer);
        assertEq(r.payee, payee);
        assertEq(r.token, address(token));
        assertEq(r.taxAuthority, taxOffice);
        assertEq(r.ruleVersion, 1);
        assertEq(r.paidAt, 1_800_000_000);
        assertEq(r.baseAmount, 500 ether);
        assertEq(r.vatAmount, 100 ether);
        assertEq(r.vatWithheld, 0);
        assertEq(r.incomeTaxWithheld, 100 ether);
    }

    function test_Pay_EmitsPaymentSplit() public {
        bytes32 invoice = keccak256("INV-CLEAN-2");
        TaxWithholdingPayments.Breakdown memory expected = TaxWithholdingPayments.Breakdown({
            baseAmount: 1_000 ether,
            vatAmount: 200 ether,
            vatWithheld: 180 ether,
            incomeTaxWithheld: 0,
            grossAmount: 1_200 ether,
            netAmount: 1_020 ether,
            taxAmount: 180 ether
        });
        vm.expectEmit(address(payments));
        emit TaxWithholdingPayments.PaymentSplit(1, invoice, payer, payee, address(token), CLEANING, 1, expected);
        _pay(invoice, CLEANING, 1_000 ether);
    }

    function test_Rounding_DustStaysWithPayeeAndNothingIsLost() public {
        // FREELANCE, 7 units: VAT = 1 (floor of 1.4), stopaj = 1 (floor of 1.4), no VAT withholding.
        _pay(keccak256("INV-TINY"), FREELANCE, 7);
        assertEq(token.balanceOf(taxOffice), 1);
        assertEq(token.balanceOf(payee), 7);
        assertEq(token.balanceOf(payer), 1_000_000 ether - 8);

        // CLEANING, 7 units: VAT = 1, withheld = floor(0.9) = 0 -> the dust stays with the payee.
        _pay(keccak256("INV-TINY-2"), CLEANING, 7);
        assertEq(token.balanceOf(taxOffice), 1);
        assertEq(token.balanceOf(payee), 15);
    }

    // ------------------------------------------------------------------
    // Attacks and misuse
    // ------------------------------------------------------------------

    function test_RevertWhen_InvoicePaidTwice() public {
        bytes32 invoice = keccak256("INV-DUP");
        _pay(invoice, CLEANING, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(TaxWithholdingPayments.InvoiceAlreadyPaid.selector, invoice, 1));
        _pay(invoice, CLEANING, 100 ether);
    }

    function test_RevertWhen_SameInvoiceUnderAnotherCategory() public {
        bytes32 invoice = keccak256("INV-DUP-2");
        _pay(invoice, CLEANING, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(TaxWithholdingPayments.InvoiceAlreadyPaid.selector, invoice, 1));
        _pay(invoice, RENT, 100 ether);
    }

    function test_FrontRunningCannotLockSomeoneElsesInvoice() public {
        bytes32 invoice = keccak256("INV-VICTIM");
        // Attacker sees the payer's transaction and pays the same hash first with dust.
        token.mint(attacker, 1 ether);
        vm.startPrank(attacker);
        token.approve(address(payments), type(uint256).max);
        payments.pay(invoice, RENT, address(token), attacker, 1, 1, taxOffice);
        vm.stopPrank();

        // The real payment still goes through and gets its own receipt.
        uint256 id = _pay(invoice, CLEANING, 1_000 ether);
        assertEq(id, 2);
        assertEq(payments.receiptIdOf(payer, invoice), 2);
        assertEq(payments.receiptIdOf(attacker, invoice), 1);
        assertEq(token.balanceOf(payee), 1_020 ether);
    }

    function test_RevertWhen_PayeeIsTheContract() public {
        // Funds sent to the contract itself would be stuck forever.
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(TaxWithholdingPayments.InvalidPayee.selector, address(payments)));
        payments.pay(keccak256("INV-SELF"), RENT, address(token), address(payments), 1 ether, 1, taxOffice);
    }

    function test_RevertWhen_NonOwnerChangesRules() public {
        vm.startPrank(attacker);
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker);

        vm.expectRevert(err);
        payments.addCategory(bytes32("EVIL"), 0, 0, 0, 10_000);
        vm.expectRevert(err);
        payments.scheduleRuleChange(RENT, 0, 0, 0, 10_000, true, uint64(block.timestamp + 2 days));
        vm.expectRevert(err);
        payments.cancelRuleChange(RENT);
        vm.expectRevert(err);
        payments.scheduleTaxAuthorityChange(attacker, uint64(block.timestamp + 2 days));
        vm.expectRevert(err);
        payments.cancelTaxAuthorityChange();
        vm.expectRevert(err);
        payments.setTokenAllowed(attacker, true);
        vm.expectRevert(err);
        payments.pause();
        vm.expectRevert(err);
        payments.unpause();
        vm.stopPrank();
    }

    function test_RevertWhen_RuleChangeWithoutNotice() public {
        uint64 tooSoon = uint64(block.timestamp + 1 days - 1);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                TaxWithholdingPayments.NoticeTooShort.selector, tooSoon, uint64(block.timestamp + 1 days)
            )
        );
        payments.scheduleRuleChange(RENT, 0, 0, 0, 3000, true, tooSoon);
    }

    function test_RuleChange_TakesEffectOnlyAtEffectiveTime() public {
        uint64 at = uint64(block.timestamp + 2 days);
        vm.prank(owner);
        payments.scheduleRuleChange(RENT, 0, 0, 0, 1500, true, at);

        // Before: old rule, version 1
        assertEq(payments.currentRule(RENT).incomeTaxBps, 2000);
        assertEq(payments.scheduledRule(RENT).version, 2);
        _pay(keccak256("INV-R-OLD"), RENT, 100 ether);
        assertEq(token.balanceOf(taxOffice), 20 ether);

        // After: new rule, version 2
        vm.warp(at);
        assertEq(payments.currentRule(RENT).incomeTaxBps, 1500);
        assertEq(payments.scheduledRule(RENT).version, 0);
        vm.prank(payer);
        payments.pay(keccak256("INV-R-NEW"), RENT, address(token), payee, 100 ether, 2, taxOffice);
        assertEq(token.balanceOf(taxOffice), 35 ether);
    }

    function test_RevertWhen_PayerSignedOldRuleVersion() public {
        uint64 at = uint64(block.timestamp + 1 days);
        vm.prank(owner);
        payments.scheduleRuleChange(CLEANING, 2000, 10, 10, 0, true, at);
        vm.warp(at);

        // A transaction prepared under version 1 must not silently use the new rule.
        vm.expectRevert(abi.encodeWithSelector(TaxWithholdingPayments.RuleVersionMismatch.selector, 1, 2));
        _pay(keccak256("INV-STALE"), CLEANING, 100 ether);
    }

    function test_ReplacedAnnouncement_GetsNewVersion() public {
        vm.startPrank(owner);
        payments.scheduleRuleChange(RENT, 0, 0, 0, 1500, true, uint64(block.timestamp + 2 days));
        payments.scheduleRuleChange(RENT, 0, 0, 0, 3000, true, uint64(block.timestamp + 2 days));
        vm.stopPrank();
        // Same timing but different rates must never share a version number.
        assertEq(payments.scheduledRule(RENT).version, 3);
    }

    function test_CancelRuleChange() public {
        vm.startPrank(owner);
        payments.scheduleRuleChange(RENT, 0, 0, 0, 5000, true, uint64(block.timestamp + 2 days));
        payments.cancelRuleChange(RENT);
        vm.expectRevert(TaxWithholdingPayments.NothingScheduled.selector);
        payments.cancelRuleChange(RENT);
        vm.stopPrank();

        vm.warp(block.timestamp + 3 days);
        assertEq(payments.currentRule(RENT).incomeTaxBps, 2000);
        assertEq(payments.currentRule(RENT).version, 1);
    }

    function test_RevertWhen_CancellingRuleAlreadyInEffect() public {
        vm.prank(owner);
        payments.scheduleRuleChange(RENT, 0, 0, 0, 1500, true, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        vm.expectRevert(TaxWithholdingPayments.NothingScheduled.selector);
        payments.cancelRuleChange(RENT);
        assertEq(payments.currentRule(RENT).incomeTaxBps, 1500);
    }

    function test_DueRuleIsPromotedBeforeNextAnnouncement() public {
        // Time is kept in a local variable: with viaIR, block.timestamp is not re-read after vm.warp.
        uint64 t0 = uint64(block.timestamp);
        vm.prank(owner);
        payments.scheduleRuleChange(RENT, 0, 0, 0, 1500, true, t0 + 1 days);
        vm.warp(t0 + 1 days);
        vm.prank(owner);
        payments.scheduleRuleChange(RENT, 0, 0, 0, 1000, true, t0 + 2 days);

        // Version 2 stays in force until version 3 starts.
        assertEq(payments.currentRule(RENT).version, 2);
        assertEq(payments.currentRule(RENT).incomeTaxBps, 1500);
        vm.warp(t0 + 2 days);
        assertEq(payments.currentRule(RENT).version, 3);
    }

    function test_RevertWhen_CategoryClosed() public {
        vm.prank(owner);
        payments.scheduleRuleChange(RENT, 0, 0, 0, 2000, false, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1 days);

        vm.expectRevert(abi.encodeWithSelector(TaxWithholdingPayments.CategoryInactive.selector, RENT));
        payments.quote(RENT, 1 ether);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(TaxWithholdingPayments.CategoryInactive.selector, RENT));
        payments.pay(keccak256("INV-CLOSED"), RENT, address(token), payee, 1 ether, 2, taxOffice);
    }

    function test_TaxAuthorityChange_IsDelayed() public {
        address newOffice = makeAddr("newTaxOffice");
        uint64 at = uint64(block.timestamp + 1 days);
        vm.prank(owner);
        payments.scheduleTaxAuthorityChange(newOffice, at);

        (address scheduled, uint64 when) = payments.scheduledTaxAuthority();
        assertEq(scheduled, newOffice);
        assertEq(when, at);

        _pay(keccak256("INV-TA-1"), RENT, 100 ether);
        assertEq(token.balanceOf(taxOffice), 20 ether, "old office until effective time");

        vm.warp(at);
        vm.prank(payer);
        payments.pay(keccak256("INV-TA-2"), RENT, address(token), payee, 100 ether, 1, newOffice);
        assertEq(token.balanceOf(newOffice), 20 ether, "new office after effective time");
        assertEq(payments.currentTaxAuthority(), newOffice);
    }

    function test_RevertWhen_PayerSignedOldTaxAuthority() public {
        address newOffice = makeAddr("newTaxOffice");
        vm.prank(owner);
        payments.scheduleTaxAuthorityChange(newOffice, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1 days);

        // A transaction prepared before the change must not silently send taxes elsewhere.
        vm.expectRevert(
            abi.encodeWithSelector(TaxWithholdingPayments.TaxAuthorityMismatch.selector, taxOffice, newOffice)
        );
        _pay(keccak256("INV-TA-STALE"), RENT, 100 ether);
    }

    function test_DueTaxAuthorityIsPromotedBeforeNextAnnouncement() public {
        address second = makeAddr("second");
        address third = makeAddr("third");
        uint64 t0 = uint64(block.timestamp);
        vm.prank(owner);
        payments.scheduleTaxAuthorityChange(second, t0 + 1 days);
        vm.warp(t0 + 1 days);
        vm.prank(owner);
        payments.scheduleTaxAuthorityChange(third, t0 + 2 days);

        assertEq(payments.currentTaxAuthority(), second, "second stays until third starts");
        vm.warp(t0 + 2 days);
        assertEq(payments.currentTaxAuthority(), third);
    }

    function test_RevertWhen_TaxAuthorityChangeWithoutNotice() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                TaxWithholdingPayments.NoticeTooShort.selector,
                uint64(block.timestamp),
                uint64(block.timestamp + 1 days)
            )
        );
        payments.scheduleTaxAuthorityChange(attacker, uint64(block.timestamp));
    }

    function test_CancelTaxAuthorityChange() public {
        vm.startPrank(owner);
        payments.scheduleTaxAuthorityChange(attacker, uint64(block.timestamp + 1 days));
        payments.cancelTaxAuthorityChange();
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        assertEq(payments.currentTaxAuthority(), taxOffice);
    }

    function test_RevertWhen_TokenNotAllowed() public {
        MockERC20 other = new MockERC20();
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(TaxWithholdingPayments.TokenNotAllowed.selector, address(other)));
        payments.pay(keccak256("INV-TOKEN"), RENT, address(other), payee, 1 ether, 1, taxOffice);
    }

    function test_RevertWhen_Paused() public {
        vm.prank(owner);
        payments.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _pay(keccak256("INV-PAUSED"), RENT, 1 ether);

        vm.prank(owner);
        payments.unpause();
        _pay(keccak256("INV-PAUSED"), RENT, 1 ether);
    }

    function test_RevertWhen_ReentrantTokenCallsBack() public {
        ReentrantToken evil = new ReentrantToken();
        vm.prank(owner);
        payments.setTokenAllowed(address(evil), true); // owner mistake: a callback token
        evil.mint(payer, 100 ether);
        vm.prank(payer);
        evil.approve(address(payments), type(uint256).max);
        evil.arm(payments, RENT, 1, taxOffice);

        vm.prank(payer);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        payments.pay(keccak256("INV-EVIL"), RENT, address(evil), payee, 10 ether, 1, taxOffice);
        assertEq(payments.receiptCount(), 0, "whole payment rolled back");
    }

    function test_RevertWhen_AllowanceTooLow() public {
        address buyer = makeAddr("buyer");
        token.mint(buyer, 10_000 ether); // enough balance, so only the allowance can fail
        vm.startPrank(buyer);
        token.approve(address(payments), 1_000 ether); // covers the base, not base + VAT
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(payments), 1_000 ether, 1_020 ether
            )
        );
        payments.pay(keccak256("INV-LOW"), CLEANING, address(token), payee, 1_000 ether, 1, taxOffice);
        vm.stopPrank();
        assertEq(payments.receiptIdOf(buyer, keccak256("INV-LOW")), 0, "invoice stays unpaid");
    }

    function test_RevertWhen_InvalidInputs() public {
        vm.startPrank(payer);
        vm.expectRevert(TaxWithholdingPayments.EmptyInvoiceHash.selector);
        payments.pay(bytes32(0), RENT, address(token), payee, 1 ether, 1, taxOffice);
        vm.expectRevert(abi.encodeWithSelector(TaxWithholdingPayments.InvalidPayee.selector, address(0)));
        payments.pay(keccak256("x"), RENT, address(token), address(0), 1 ether, 1, taxOffice);
        vm.expectRevert(TaxWithholdingPayments.ZeroAmount.selector);
        payments.pay(keccak256("x"), RENT, address(token), payee, 0, 1, taxOffice);
        vm.expectRevert(abi.encodeWithSelector(TaxWithholdingPayments.UnknownCategory.selector, bytes32("NOPE")));
        payments.pay(keccak256("x"), bytes32("NOPE"), address(token), payee, 1 ether, 1, taxOffice);
        vm.stopPrank();
    }

    function test_RevertWhen_InvalidRule() public {
        vm.startPrank(owner);
        vm.expectRevert(TaxWithholdingPayments.InvalidRate.selector);
        payments.addCategory(bytes32("A"), 10_001, 0, 0, 0);
        vm.expectRevert(TaxWithholdingPayments.InvalidRate.selector);
        payments.addCategory(bytes32("A"), 0, 0, 0, 10_001);
        vm.expectRevert(TaxWithholdingPayments.InvalidWithholdingFraction.selector);
        payments.addCategory(bytes32("A"), 2000, 11, 10, 0); // more than all of the VAT
        vm.expectRevert(TaxWithholdingPayments.InvalidWithholdingFraction.selector);
        payments.addCategory(bytes32("A"), 2000, 1, 11, 0); // denominator above 10
        vm.expectRevert(TaxWithholdingPayments.InvalidWithholdingFraction.selector);
        payments.addCategory(bytes32("A"), 2000, 0, 10, 0); // half-defined fraction
        vm.expectRevert(TaxWithholdingPayments.InvalidWithholdingFraction.selector);
        payments.addCategory(bytes32("A"), 0, 5, 10, 0); // withholding without VAT
        vm.expectRevert(TaxWithholdingPayments.EmptyCategory.selector);
        payments.addCategory(bytes32(0), 0, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(TaxWithholdingPayments.CategoryAlreadyExists.selector, RENT));
        payments.addCategory(RENT, 0, 0, 0, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_RenounceOwnership() public {
        vm.prank(owner);
        vm.expectRevert(TaxWithholdingPayments.RenounceDisabled.selector);
        payments.renounceOwnership();
    }

    function test_OwnershipTransfer_IsTwoStep() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        payments.transferOwnership(newOwner);
        assertEq(payments.owner(), owner, "unchanged until accepted");
        vm.prank(newOwner);
        payments.acceptOwnership();
        assertEq(payments.owner(), newOwner);
    }

    // ------------------------------------------------------------------
    // Fuzz: money is conserved for any amount and any valid rule
    // ------------------------------------------------------------------

    function testFuzz_SplitConservesValue(
        uint256 base,
        uint16 vatBps,
        uint8 num,
        uint8 den,
        uint16 incomeTaxBps,
        bool withholdVat
    ) public {
        base = bound(base, 1, 1e30);
        vatBps = uint16(bound(vatBps, 0, 10_000));
        incomeTaxBps = uint16(bound(incomeTaxBps, 0, 10_000));
        if (withholdVat && vatBps != 0) {
            den = uint8(bound(den, 1, 10));
            num = uint8(bound(num, 1, den));
        } else {
            (num, den) = (0, 0); // no VAT withholding (also covers rules without VAT)
        }

        bytes32 cat = bytes32("FUZZ");
        vm.prank(owner);
        payments.addCategory(cat, vatBps, num, den, incomeTaxBps);

        (TaxWithholdingPayments.Breakdown memory q,,) = payments.quote(cat, base);
        token.mint(payer, q.grossAmount);
        uint256 payerBefore = token.balanceOf(payer);

        vm.prank(payer);
        payments.pay(keccak256(abi.encode(base, vatBps)), cat, address(token), payee, base, 1, taxOffice);

        uint256 paid = payerBefore - token.balanceOf(payer);
        assertEq(paid, q.grossAmount, "payer pays exactly the quote");
        assertEq(paid, token.balanceOf(payee) + token.balanceOf(taxOffice), "nothing lost or created");
        assertEq(token.balanceOf(address(payments)), 0, "contract holds nothing");
        assertLe(q.vatWithheld, q.vatAmount, "withholding never exceeds VAT");
        assertLe(q.incomeTaxWithheld, base, "stopaj never exceeds base");
    }

    function testFuzz_RevertWhen_WrongRuleVersion(uint32 wrongVersion) public {
        vm.assume(wrongVersion != 1);
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(TaxWithholdingPayments.RuleVersionMismatch.selector, wrongVersion, 1)
        );
        payments.pay(keccak256("INV-V"), RENT, address(token), payee, 1 ether, wrongVersion, taxOffice);
    }
}
