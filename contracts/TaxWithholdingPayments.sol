// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TaxWithholdingPayments
/// @author Furkan Bozkurt
/// @notice Educational contract that pays an invoice and splits the payment in a single
///         transaction: the payee receives the net amount, the tax authority receives the
///         withheld taxes.
///
///         Terms (Turkish tax practice):
///         - base amount (matrah): invoice amount before VAT
///         - VAT (KDV): added on top of the base amount
///         - VAT withholding (KDV tevkifati): a fraction of the VAT (e.g. 9/10) that the buyer
///           pays directly to the tax authority instead of to the seller
///         - income tax withholding (stopaj): a percentage of the base amount (e.g. 20% on rent)
///           withheld by the payer on behalf of the payee
///
///         payer pays      = base + VAT
///         tax authority  <- VAT withholding + income tax withholding
///         payee          <- base + VAT - VAT withholding - income tax withholding
///
/// @dev    The contract never holds funds: tokens move from the payer straight to the payee
///         and to the tax authority with `transferFrom`. Rates and the tax authority address
///         can only change with advance notice (`MIN_NOTICE`), like a law that is published
///         before it takes effect. Only invoice hashes are stored on chain, never the invoice.
///
///         NOT AUDITED. FOR EDUCATIONAL USE ONLY. NOT TAX ADVICE. Example rates are illustrative.
contract TaxWithholdingPayments is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @notice Basis points denominator: 10_000 = 100%.
    uint16 public constant BPS = 10_000;

    /// @notice Minimum notice between announcing a change and the change taking effect.
    uint64 public constant MIN_NOTICE = 1 days;

    /// @notice Largest allowed VAT withholding denominator (Turkish practice uses tenths).
    uint8 public constant MAX_WITHHOLDING_DENOMINATOR = 10;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @notice Tax rule of one payment category (e.g. "RENT", "CLEANING").
    /// @param vatBps                  VAT rate in basis points (2000 = 20%).
    /// @param vatWithholdingNumerator VAT withholding numerator (9 in 9/10); 0 = none.
    /// @param vatWithholdingDenominator VAT withholding denominator (10 in 9/10); 0 = none.
    /// @param incomeTaxBps            Income tax withholding rate in basis points.
    /// @param active                  Whether payments in this category are accepted.
    /// @param version                 Increases with every change; payers pin it.
    /// @param effectiveAt             Timestamp from which the rule applies.
    struct TaxRule {
        uint16 vatBps;
        uint8 vatWithholdingNumerator;
        uint8 vatWithholdingDenominator;
        uint16 incomeTaxBps;
        bool active;
        uint32 version;
        uint64 effectiveAt;
    }

    /// @notice Amounts of one payment.
    struct Breakdown {
        uint256 baseAmount;
        uint256 vatAmount;
        uint256 vatWithheld;
        uint256 incomeTaxWithheld;
        uint256 grossAmount; // paid by the payer: base + VAT
        uint256 netAmount; // received by the payee
        uint256 taxAmount; // received by the tax authority
    }

    /// @notice On-chain receipt of one payment (makbuz).
    struct Receipt {
        bytes32 invoiceHash;
        bytes32 category;
        address payer;
        address payee;
        address token;
        address taxAuthority;
        uint32 ruleVersion;
        uint64 paidAt;
        uint256 baseAmount;
        uint256 vatAmount;
        uint256 vatWithheld;
        uint256 incomeTaxWithheld;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    mapping(bytes32 category => TaxRule) private _rules;
    mapping(bytes32 category => TaxRule) private _pendingRules;
    mapping(bytes32 category => uint32) private _lastVersion;

    address private _taxAuthority;
    address private _pendingTaxAuthority;
    uint64 private _pendingTaxAuthorityEffectiveAt;

    /// @notice Tokens accepted for payment (e.g. a stablecoin). Plain ERC-20 only.
    mapping(address token => bool) public isTokenAllowed;

    /// @notice Receipt id of an invoice paid by `payer`; 0 = unpaid.
    /// @dev Keyed by payer so that a third party cannot front-run and lock someone else's
    ///      invoice hash with a dust payment.
    mapping(address payer => mapping(bytes32 invoiceHash => uint256 receiptId)) public receiptIdOf;

    mapping(uint256 receiptId => Receipt) private _receipts;

    /// @notice Number of receipts issued; receipt ids start at 1.
    uint256 public receiptCount;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event CategoryAdded(bytes32 indexed category, TaxRule rule);
    event RuleChangeScheduled(bytes32 indexed category, TaxRule rule);
    event RuleChangeCancelled(bytes32 indexed category, uint32 version);
    event TaxAuthorityChangeScheduled(address indexed newTaxAuthority, uint64 effectiveAt);
    event TaxAuthorityChangeCancelled(address indexed cancelledTaxAuthority);
    event TokenAllowanceSet(address indexed token, bool allowed);
    event PaymentSplit(
        uint256 indexed receiptId,
        bytes32 indexed invoiceHash,
        address indexed payer,
        address payee,
        address token,
        bytes32 category,
        uint32 ruleVersion,
        Breakdown breakdown
    );

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error EmptyInvoiceHash();
    error EmptyCategory();
    error InvalidRate();
    error InvalidWithholdingFraction();
    error CategoryAlreadyExists(bytes32 category);
    error UnknownCategory(bytes32 category);
    error CategoryInactive(bytes32 category);
    error NoticeTooShort(uint64 effectiveAt, uint64 earliestAllowed);
    error NothingScheduled();
    error InvoiceAlreadyPaid(bytes32 invoiceHash, uint256 receiptId);
    error TokenNotAllowed(address token);
    error RuleVersionMismatch(uint32 expected, uint32 current);
    error TaxAuthorityMismatch(address expected, address current);
    error InvalidPayee(address payee);
    error RenounceDisabled();

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param initialOwner Administrator of rates, tokens and the tax authority address.
    /// @param initialTaxAuthority Address that receives withheld taxes.
    constructor(address initialOwner, address initialTaxAuthority) Ownable(initialOwner) {
        if (initialTaxAuthority == address(0)) revert ZeroAddress();
        _taxAuthority = initialTaxAuthority;
    }

    // ---------------------------------------------------------------------
    // Payment
    // ---------------------------------------------------------------------

    /// @notice Pays an invoice and splits the amount between the payee and the tax authority.
    /// @dev The payer must approve `grossAmount` (see `quote`) for this contract beforehand.
    /// @param invoiceHash Hash of the invoice (e.g. keccak256 of the e-invoice UUID); a payer
    ///        can pay each hash once.
    /// @param category Payment category whose tax rule applies.
    /// @param token Allowed ERC-20 token used for payment.
    /// @param payee Seller / service provider receiving the net amount.
    /// @param baseAmount Invoice amount before VAT, in token units.
    /// @param expectedRuleVersion Rule version the payer agreed to (from `quote`); the payment
    ///        reverts if the rule changed in the meantime.
    /// @param expectedTaxAuthority Tax authority address the payer agreed to (from `quote`); the
    ///        payment reverts if it changed in the meantime.
    /// @return receiptId Id of the stored receipt.
    function pay(
        bytes32 invoiceHash,
        bytes32 category,
        address token,
        address payee,
        uint256 baseAmount,
        uint32 expectedRuleVersion,
        address expectedTaxAuthority
    ) external nonReentrant whenNotPaused returns (uint256 receiptId) {
        if (invoiceHash == bytes32(0)) revert EmptyInvoiceHash();
        if (payee == address(0) || payee == address(this)) revert InvalidPayee(payee);
        if (baseAmount == 0) revert ZeroAmount();
        if (!isTokenAllowed[token]) revert TokenNotAllowed(token);
        uint256 existing = receiptIdOf[msg.sender][invoiceHash];
        if (existing != 0) revert InvoiceAlreadyPaid(invoiceHash, existing);

        TaxRule memory rule = currentRule(category);
        if (rule.version == 0) revert UnknownCategory(category);
        if (!rule.active) revert CategoryInactive(category);
        if (rule.version != expectedRuleVersion) {
            revert RuleVersionMismatch(expectedRuleVersion, rule.version);
        }
        address authority = currentTaxAuthority();
        if (authority != expectedTaxAuthority) revert TaxAuthorityMismatch(expectedTaxAuthority, authority);

        Breakdown memory b = _compute(rule, baseAmount);

        // Effects before interactions.
        receiptId = ++receiptCount;
        receiptIdOf[msg.sender][invoiceHash] = receiptId;
        _receipts[receiptId] = Receipt({
            invoiceHash: invoiceHash,
            category: category,
            payer: msg.sender,
            payee: payee,
            token: token,
            taxAuthority: authority,
            ruleVersion: rule.version,
            paidAt: uint64(block.timestamp),
            baseAmount: b.baseAmount,
            vatAmount: b.vatAmount,
            vatWithheld: b.vatWithheld,
            incomeTaxWithheld: b.incomeTaxWithheld
        });

        emit PaymentSplit(receiptId, invoiceHash, msg.sender, payee, token, category, rule.version, b);

        // Interactions: funds go directly from the payer; the contract never holds them.
        IERC20 erc20 = IERC20(token);
        if (b.netAmount != 0) erc20.safeTransferFrom(msg.sender, payee, b.netAmount);
        if (b.taxAmount != 0) erc20.safeTransferFrom(msg.sender, authority, b.taxAmount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Breakdown of a payment under the rule that applies now.
    /// @return breakdown Amounts; `grossAmount` is what the payer must approve.
    /// @return ruleVersion Value to pass as `expectedRuleVersion` to `pay`.
    /// @return taxAuthority Value to pass as `expectedTaxAuthority` to `pay`.
    function quote(bytes32 category, uint256 baseAmount)
        external
        view
        returns (Breakdown memory breakdown, uint32 ruleVersion, address taxAuthority)
    {
        TaxRule memory rule = currentRule(category);
        if (rule.version == 0) revert UnknownCategory(category);
        if (!rule.active) revert CategoryInactive(category);
        return (_compute(rule, baseAmount), rule.version, currentTaxAuthority());
    }

    /// @notice Rule that applies now: the scheduled rule once its time has come.
    function currentRule(bytes32 category) public view returns (TaxRule memory) {
        TaxRule memory pending = _pendingRules[category];
        if (pending.version != 0 && pending.effectiveAt <= block.timestamp) return pending;
        return _rules[category];
    }

    /// @notice Announced rule that is not yet in effect (version 0 = none).
    function scheduledRule(bytes32 category) external view returns (TaxRule memory rule) {
        rule = _pendingRules[category];
        if (rule.effectiveAt <= block.timestamp) delete rule;
    }

    /// @notice Address that receives withheld taxes now.
    function currentTaxAuthority() public view returns (address) {
        if (_pendingTaxAuthority != address(0) && _pendingTaxAuthorityEffectiveAt <= block.timestamp) {
            return _pendingTaxAuthority;
        }
        return _taxAuthority;
    }

    /// @notice Announced tax authority address that is not yet in effect.
    function scheduledTaxAuthority() external view returns (address account, uint64 effectiveAt) {
        if (_pendingTaxAuthority != address(0) && _pendingTaxAuthorityEffectiveAt > block.timestamp) {
            return (_pendingTaxAuthority, _pendingTaxAuthorityEffectiveAt);
        }
        return (address(0), 0);
    }

    /// @notice Receipt of a payment.
    function receipt(uint256 receiptId) external view returns (Receipt memory) {
        return _receipts[receiptId];
    }

    // ---------------------------------------------------------------------
    // Administration
    // ---------------------------------------------------------------------

    /// @notice Adds a new category; effective immediately (no payer depends on it yet).
    function addCategory(
        bytes32 category,
        uint16 vatBps,
        uint8 vatWithholdingNumerator,
        uint8 vatWithholdingDenominator,
        uint16 incomeTaxBps
    ) external onlyOwner {
        if (category == bytes32(0)) revert EmptyCategory();
        if (_lastVersion[category] != 0) revert CategoryAlreadyExists(category);
        _validate(vatBps, vatWithholdingNumerator, vatWithholdingDenominator, incomeTaxBps);

        TaxRule memory rule = TaxRule({
            vatBps: vatBps,
            vatWithholdingNumerator: vatWithholdingNumerator,
            vatWithholdingDenominator: vatWithholdingDenominator,
            incomeTaxBps: incomeTaxBps,
            active: true,
            version: 1,
            effectiveAt: uint64(block.timestamp)
        });
        _lastVersion[category] = 1;
        _rules[category] = rule;
        emit CategoryAdded(category, rule);
    }

    /// @notice Announces a new rule for an existing category, effective at `effectiveAt`
    ///         (at least `MIN_NOTICE` from now). Replaces an earlier announcement that is not
    ///         yet in effect. Use `active = false` to close a category.
    function scheduleRuleChange(
        bytes32 category,
        uint16 vatBps,
        uint8 vatWithholdingNumerator,
        uint8 vatWithholdingDenominator,
        uint16 incomeTaxBps,
        bool active,
        uint64 effectiveAt
    ) external onlyOwner {
        if (_lastVersion[category] == 0) revert UnknownCategory(category);
        _validate(vatBps, vatWithholdingNumerator, vatWithholdingDenominator, incomeTaxBps);
        _requireNotice(effectiveAt);
        _promoteDueRule(category);

        uint32 version = ++_lastVersion[category];
        TaxRule memory rule = TaxRule({
            vatBps: vatBps,
            vatWithholdingNumerator: vatWithholdingNumerator,
            vatWithholdingDenominator: vatWithholdingDenominator,
            incomeTaxBps: incomeTaxBps,
            active: active,
            version: version,
            effectiveAt: effectiveAt
        });
        _pendingRules[category] = rule;
        emit RuleChangeScheduled(category, rule);
    }

    /// @notice Cancels an announced rule that is not yet in effect.
    function cancelRuleChange(bytes32 category) external onlyOwner {
        TaxRule memory pending = _pendingRules[category];
        if (pending.version == 0 || pending.effectiveAt <= block.timestamp) revert NothingScheduled();
        delete _pendingRules[category];
        emit RuleChangeCancelled(category, pending.version);
    }

    /// @notice Announces a new tax authority address, effective at `effectiveAt`.
    function scheduleTaxAuthorityChange(address newTaxAuthority, uint64 effectiveAt) external onlyOwner {
        if (newTaxAuthority == address(0)) revert ZeroAddress();
        _requireNotice(effectiveAt);
        _promoteDueTaxAuthority();
        _pendingTaxAuthority = newTaxAuthority;
        _pendingTaxAuthorityEffectiveAt = effectiveAt;
        emit TaxAuthorityChangeScheduled(newTaxAuthority, effectiveAt);
    }

    /// @notice Cancels an announced tax authority change that is not yet in effect.
    function cancelTaxAuthorityChange() external onlyOwner {
        address pending = _pendingTaxAuthority;
        if (pending == address(0) || _pendingTaxAuthorityEffectiveAt <= block.timestamp) {
            revert NothingScheduled();
        }
        _pendingTaxAuthority = address(0);
        _pendingTaxAuthorityEffectiveAt = 0;
        emit TaxAuthorityChangeCancelled(pending);
    }

    /// @notice Allows or disallows a payment token. Only plain ERC-20 tokens are supported
    ///         (no fee-on-transfer, rebasing or callback tokens).
    function setTokenAllowed(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        isTokenAllowed[token] = allowed;
        emit TokenAllowanceSet(token, allowed);
    }

    /// @notice Stops new payments (emergency brake).
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resumes payments.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Disabled: without an owner, rates could never be updated again.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev All amounts are rounded down to the token's smallest unit, so any rounding dust
    ///      (at most 1 unit per tax item) stays with the payee. Turkish practice rounds to the
    ///      nearest kurus; with an 18-decimal token the difference is negligible.
    function _compute(TaxRule memory rule, uint256 baseAmount) internal pure returns (Breakdown memory b) {
        b.baseAmount = baseAmount;
        b.vatAmount = (baseAmount * rule.vatBps) / BPS;
        if (rule.vatWithholdingDenominator != 0) {
            b.vatWithheld = (b.vatAmount * rule.vatWithholdingNumerator) / rule.vatWithholdingDenominator;
        }
        b.incomeTaxWithheld = (baseAmount * rule.incomeTaxBps) / BPS;
        b.grossAmount = baseAmount + b.vatAmount;
        b.taxAmount = b.vatWithheld + b.incomeTaxWithheld;
        // Cannot underflow: vatWithheld <= vatAmount and incomeTaxWithheld <= baseAmount.
        b.netAmount = b.grossAmount - b.taxAmount;
    }

    function _validate(uint16 vatBps, uint8 num, uint8 den, uint16 incomeTaxBps) internal pure {
        if (vatBps > BPS || incomeTaxBps > BPS) revert InvalidRate();
        if (num == 0 && den == 0) return;
        if (num == 0 || den == 0 || num > den || den > MAX_WITHHOLDING_DENOMINATOR) {
            revert InvalidWithholdingFraction();
        }
        if (vatBps == 0) revert InvalidWithholdingFraction();
    }

    function _requireNotice(uint64 effectiveAt) internal view {
        uint64 earliest = uint64(block.timestamp) + MIN_NOTICE;
        if (effectiveAt < earliest) revert NoticeTooShort(effectiveAt, earliest);
    }

    function _promoteDueRule(bytes32 category) internal {
        TaxRule memory pending = _pendingRules[category];
        if (pending.version != 0 && pending.effectiveAt <= block.timestamp) {
            _rules[category] = pending;
            delete _pendingRules[category];
        }
    }

    function _promoteDueTaxAuthority() internal {
        if (_pendingTaxAuthority != address(0) && _pendingTaxAuthorityEffectiveAt <= block.timestamp) {
            _taxAuthority = _pendingTaxAuthority;
            _pendingTaxAuthority = address(0);
            _pendingTaxAuthorityEffectiveAt = 0;
        }
    }
}
