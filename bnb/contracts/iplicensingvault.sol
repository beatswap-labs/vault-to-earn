// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ----------------------------------------------------------------------------
// IPLicensingVault
// - USDT-based vault for IP licensing flows
// - Tracks deposits, reserved/consumed balances, and royalty capacity
// - Uses EIP-712 signed messages for consumption and royalty allocation
// - Distributes BTX via epoch-based Merkle claims
// ----------------------------------------------------------------------------

interface IIDOLauncher { // Minimal interface for external IDO contracts
    function buyFor(address user, bytes32 rightId, uint256 usdtAmount) external; // Purchase on behalf of `user`
}

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";               // ERC20 interface
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";      // Safe ERC20 operations
import "@openzeppelin/contracts/access/Ownable.sol";                    // Ownership control
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";         // Reentrancy protection
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";         // ECDSA utilities
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";   // Merkle proof verification

contract IPLicensingVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ---------------- Errors ----------------
    // Custom errors for precise and gas-efficient reverts
    error ErrZeroAddress();
    error ErrOnlyRelayer();
    error ErrOnlyConsumeSigner();
    error ErrOnlyRoyaltySigner();
    error ErrAmountZero();
    error ErrInsufficient();
    error ErrCapReached();
    error ErrDepositTooLarge();
    error ErrTreasuryUnset();
    error ErrIdoNotApproved();
    error ErrRootNotSet();
    error ErrRootAlreadySet();
    error ErrBadProof();
    error ErrAlreadyClaimed();
    error ErrExpired();
    error ErrConsumedDecrease();
    error ErrConsumedOverReserve();
    error ErrRoyaltyDecrease();
    error ErrRoyaltyOverBudget();
    error ErrExceedsExcessUSDT();
    error ErrNoChange();
    error ErrIdoPullMismatch();
    error ErrDeprecated();
    error ErrPaused();
    error ErrBadSig();

    // ---------------- Immutables ----------------
    // Tokens used by the system; immutable after deployment
    IERC20 public immutable USDT; // Deposit / settlement token
    IERC20 public immutable BTX;  // Reward token

    // ---------------- Lightweight Pausable ----------------
    bool public paused;

    modifier whenNotPaused() {
        if (paused) revert ErrPaused();
        _;
    }

    function pause() external onlyOwner {
        paused = true;
    }

    function unpause() external onlyOwner {
        paused = false;
    }

    // ---------------- Access / Wiring ----------------
    address public projectTreasury;                     // Treasury that ultimately receives IDO funds
    mapping(address => bool) public isRelayer;          // Authorized relayers
    mapping(address => bool) public isApprovedIdo;      // Approved IDO contracts
    mapping(bytes32 => address) public idoOf;           // rightId → IDO contract

    event ProjectTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event RelayerUpdated(address indexed relayer, bool allowed);
    event IdoApprovalUpdated(address indexed ido, bool approved);
    event RightIdBound(bytes32 indexed rightId, address indexed ido);

    // ---------------- Accounting (packed) ----------------
    // Per-account state (packed across slots for gas efficiency)
    struct Account {
        uint128 balance;           // slot0: total USDT currently deposited
        uint128 reservedTotal;     // slot0: total reserved amount
        uint128 reservedConsumed;  // slot1: cumulative reserved amount that has been consumed
        uint64  lastTs;            // slot1: last timestamp used for time-weighted accumulation
        uint256 accBalanceSeconds; // slot2: ∑ reservedAvail * elapsedSeconds
    }

    mapping(address => Account) private accounts;
    uint256 public totalDeposits;                       // Global sum of all deposits

    // Event amounts narrowed to uint128 for gas efficiency
    event Deposit(address indexed user, uint128 amount);
    event Withdraw(address indexed user, uint128 amountFromDeposit);
    event ReservedChanged(address indexed user, uint128 total, uint128 consumed);

    // ---------------- Global royalty guard ----------------
    // Global aggregates used to enforce royalty limits
    uint256 public totalConsumedForRoyaltyAll;          // Sum of all consumption backing royalties
    uint256 public totalRoyaltyPaidAll;                 // Total USDT royalties paid out
    uint256 public totalRoyaltyAllocatedAll;            // Total royalties allocated into buffers

    event ConsumedSynced(address indexed user, uint256 newCumulative, uint128 deltaConsumed);
    event RoyaltyAllocated(address indexed rightsHolder, uint256 amount);
    event RoyaltyPaid(address indexed rightsHolder, uint256 amount);

    // ---------------- EIP-712 ----------------
    // EIP-712 domain and typed data for signed messages
    bytes32 private immutable _DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private constant _CONSUME_TYPEHASH =
        keccak256("Consume(address user,uint256 cumulativeConsumed,uint256 windowId,uint256 deadline)");
    bytes32 private constant _ROYALTY_TYPEHASH =
        keccak256("Royalty(address holder,uint256 cumulativeAmount,uint256 windowId,uint256 deadline)");

    string private constant _NAME = "IPLV";
    string private constant _VERSION = "1";

    // ---------------- Signers ----------------
    // Offchain signers for oracle-like updates
    mapping(address => bool) public isConsumeSigner;
    mapping(address => bool) public isRoyaltySigner;

    event ConsumeSignerUpdated(address indexed signer, bool allowed);
    event RoyaltySignerUpdated(address indexed signer, bool allowed);

    // ---------------- Royalty buffers ----------------
    mapping(address => uint256) public claimableRoyalty;         // Royalties ready to withdraw
    mapping(address => uint256) public royaltyClaimedCumulative; // Cumulative allocations per user

    // ---------------- BTX Merkle (immutable per epoch) ----------------
    // BTX distributions via epoch-based Merkle roots
    mapping(bytes32 => bytes32) public btxRoot;                    // Epoch → Merkle root
    mapping(bytes32 => mapping(address => uint256)) public btxClaimed; // Epoch → user → claimed amount

    event BtxRootSet(bytes32 indexed epoch, bytes32 root);
    event BTXClaimed(bytes32 indexed epoch, address indexed user, uint256 amount);

    // ---------------- Caps ----------------
    uint256 public usdtDepositCap;                                 // Per-account deposit cap

    event UsdtDepositCapUpdated(uint256 oldCap, uint256 newCap);

    // ---------------- Vault Power monthly (event-only) ----------------
    // Event-only announcements for offchain indexing
    event MonthlyVaultPowerAnnounced(
        bytes32 indexed epoch,
        uint16 year,
        uint8 month,
        uint256 snapshotTs,
        uint256 monthlyAllocation
    );

    // ---------------- Relayer mod ----------------
    modifier onlyRelayer() {
        if (!isRelayer[msg.sender]) revert ErrOnlyRelayer();
        _;
    }

    // ---------------- Constructor ----------------
    constructor(
        IERC20 _usdt,
        IERC20 _btx,
        address _projectTreasury,
        uint256 _initialUsdtDepositCap
    ) Ownable(msg.sender) {
        if (address(_usdt) == address(0) || address(_btx) == address(0) || _projectTreasury == address(0)) {
            revert ErrZeroAddress();
        }
        USDT = _usdt;
        BTX  = _btx;
        projectTreasury = _projectTreasury;
        usdtDepositCap  = _initialUsdtDepositCap;

        emit ProjectTreasuryUpdated(address(0), _projectTreasury);
        emit UsdtDepositCapUpdated(0, _initialUsdtDepositCap);

        _CACHED_CHAIN_ID  = block.chainid;
        _DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    // ---------------- Admin wiring ----------------
    function setProjectTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ErrZeroAddress();
        address old = projectTreasury;
        if (old == _treasury) revert ErrNoChange();
        projectTreasury = _treasury;
        emit ProjectTreasuryUpdated(old, _treasury);
    }

    function setRelayer(address relayer, bool allowed) external onlyOwner {
        if (relayer == address(0)) revert ErrZeroAddress();
        bool old = isRelayer[relayer];
        if (old == allowed) revert ErrNoChange();
        isRelayer[relayer] = allowed;
        emit RelayerUpdated(relayer, allowed);
    }

    function setIdoApproval(address ido, bool approved) external onlyOwner {
        if (ido == address(0)) revert ErrZeroAddress();
        bool old = isApprovedIdo[ido];
        if (old == approved) revert ErrNoChange();
        isApprovedIdo[ido] = approved;
        emit IdoApprovalUpdated(ido, approved);
    }

    // Rebinding the same rightId to a different IDO is allowed by design
    function bindRightId(bytes32 rightId, address ido) external onlyOwner {
        if (ido == address(0)) revert ErrZeroAddress();
        if (!isApprovedIdo[ido]) revert ErrIdoNotApproved();
        idoOf[rightId] = ido;
        emit RightIdBound(rightId, ido);
    }

    function setUsdtDepositCap(uint256 newCap) external onlyOwner {
        uint256 old = usdtDepositCap;
        if (old == newCap) revert ErrNoChange();
        usdtDepositCap = newCap;
        emit UsdtDepositCapUpdated(old, newCap);
    }

    function setConsumeSigner(address s, bool allowed) external onlyOwner {
        if (s == address(0)) revert ErrZeroAddress();
        bool old = isConsumeSigner[s];
        if (old == allowed) revert ErrNoChange();
        isConsumeSigner[s] = allowed;
        emit ConsumeSignerUpdated(s, allowed);
    }

    function setRoyaltySigner(address s, bool allowed) external onlyOwner {
        if (s == address(0)) revert ErrZeroAddress();
        bool old = isRoyaltySigner[s];
        if (old == allowed) revert ErrNoChange();
        isRoyaltySigner[s] = allowed;
        emit RoyaltySignerUpdated(s, allowed);
    }

    // ---------------- EIP-712 helpers ----------------
    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(_NAME)),
                keccak256(bytes(_VERSION)),
                block.chainid,
                address(this)
            )
        );
    }

    function _domainSeparator() internal view returns (bytes32) {
        return (block.chainid == _CACHED_CHAIN_ID) ? _DOMAIN_SEPARATOR : _buildDomainSeparator();
    }

    function _recoverSigner(bytes32 structHash, bytes calldata sig) internal view returns (address) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        return digest.recover(sig);
    }

    // ---------------- Internal helpers ----------------
    // Current reserved amount that is still available (not yet consumed)
    function _reservedAvail(Account storage a) private view returns (uint256) {
        return uint256(a.reservedTotal) - uint256(a.reservedConsumed);
    }

    // Helper to compute reservedAvail and withdrawable from raw values
    function _calcReservedAvailAndWithdrawable(
        uint256 balance_,
        uint256 reservedTotal_,
        uint256 reservedConsumed_
    ) internal pure returns (uint256 reservedAvail_, uint256 withdrawable_) {
        reservedAvail_ = reservedTotal_ - reservedConsumed_;
        withdrawable_ = balance_ > reservedAvail_ ? balance_ - reservedAvail_ : 0;
    }

    // Time-weighted accumulation of reservedAvail for a given user
    function _accumulate(address user) internal {
        Account storage a = accounts[user];
        uint64 nowTs = uint64(block.timestamp);
        uint64 last = a.lastTs;
        if (last == 0) {
            a.lastTs = nowTs;
            return;
        }
        if (nowTs > last) {
            uint256 ra = _reservedAvail(a);
            if (ra > 0) {
                unchecked {
                    a.accBalanceSeconds += ra * uint256(nowTs - last);
                }
            }
            a.lastTs = nowTs;
        }
    }

    // View helper: preview accBalanceSeconds as if updated to the current timestamp
    function _previewAccBalanceSeconds(Account storage a) internal view returns (uint256) {
        uint256 acc = a.accBalanceSeconds;
        uint64 lastTs = a.lastTs;
        if (lastTs != 0) {
            uint64 nowTs = uint64(block.timestamp);
            if (nowTs > lastTs) {
                uint256 ra = uint256(a.reservedTotal) - uint256(a.reservedConsumed);
                if (ra > 0) {
                    acc += ra * uint256(nowTs - lastTs);
                }
            }
        }
        return acc;
    }

    function _withdrawableOf(Account storage a) internal view returns (uint256) {
        uint256 ra = _reservedAvail(a);
        uint256 bal = uint256(a.balance);
        return bal > ra ? bal - ra : 0;
    }

    // ---------------- Deposit / Withdraw ----------------
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ErrAmountZero();
        address user = msg.sender;
        Account storage a = accounts[user];

        // Settle time-weighted state before mutating balances
        _accumulate(user);

        uint256 bal = uint256(a.balance);
        if (bal >= usdtDepositCap) revert ErrCapReached();
        uint256 room = usdtDepositCap - bal;
        if (amount > room) revert ErrDepositTooLarge();

        USDT.safeTransferFrom(user, address(this), amount);

        // Check bounds before casting to uint128
        uint256 newBal = bal + amount;
        if (newBal > type(uint128).max) revert ErrDepositTooLarge();
        uint256 newReservedTotal = uint256(a.reservedTotal) + amount;
        if (newReservedTotal > type(uint128).max) revert ErrDepositTooLarge();

        a.balance = uint128(newBal);
        totalDeposits += amount;
        a.reservedTotal = uint128(newReservedTotal);

        emit Deposit(user, uint128(amount));
        emit ReservedChanged(user, a.reservedTotal, a.reservedConsumed);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ErrAmountZero();
        address user = msg.sender;
        Account storage a = accounts[user];

        // Settle time-weighted state before mutating balances
        _accumulate(user);

        uint256 royaltyBuf = claimableRoyalty[user];
        uint256 w = _withdrawableOf(a);
        uint256 totalAvail = w + royaltyBuf;
        if (amount > totalAvail) revert ErrInsufficient();

        uint256 fromRoyalty = amount <= royaltyBuf ? amount : royaltyBuf;
        uint256 fromDeposit = amount - fromRoyalty;

        if (fromDeposit > 0) {
            unchecked {
                a.balance = uint128(uint256(a.balance) - fromDeposit);
                totalDeposits -= fromDeposit;
            }
        }
        if (fromRoyalty > 0) {
            unchecked {
                claimableRoyalty[user] = royaltyBuf - fromRoyalty;
                totalRoyaltyPaidAll += fromRoyalty;
            }
            emit RoyaltyPaid(user, fromRoyalty);
        }

        USDT.safeTransfer(user, amount);
        emit Withdraw(user, uint128(fromDeposit));
    }

    function totalWithdrawableOf(address user) external view returns (uint256) {
        Account storage a = accounts[user];
        return _withdrawableOf(a) + claimableRoyalty[user];
    }

    function royaltyBufferOf(address user) external view returns (uint256) {
        return claimableRoyalty[user];
    }

    // ---------------- Reserve increase/decrease ----------------
    // Adjust reservedTotal while keeping deposits unchanged
    function increaseReserved(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ErrAmountZero();
        address user = msg.sender;
        Account storage a = accounts[user];

        _accumulate(user);

        uint256 w = _withdrawableOf(a);
        if (amount > w) revert ErrInsufficient();

        uint256 newReservedTotal = uint256(a.reservedTotal) + amount;
        if (newReservedTotal > type(uint128).max) revert ErrDepositTooLarge();
        a.reservedTotal = uint128(newReservedTotal);
        emit ReservedChanged(user, a.reservedTotal, a.reservedConsumed);
    }

    function decreaseReserved(uint256 amount) external nonReentrant {
        if (amount == 0) revert ErrAmountZero();
        address user = msg.sender;
        Account storage a = accounts[user];

        _accumulate(user);

        uint256 ra = _reservedAvail(a);
        if (amount > ra) revert ErrInsufficient();

        unchecked {
            a.reservedTotal = uint128(uint256(a.reservedTotal) - amount);
        }
        emit ReservedChanged(user, a.reservedTotal, a.reservedConsumed);
    }

    // ---------------- Oracle: consumption sync ----------------
    // Apply signed cumulative consumption for a user
    function _applyConsumedSigned(
        address user,
        uint256 newCumConsumed,
        uint256 windowId,
        uint256 deadline,
        bytes calldata sig
    ) private returns (uint256 delta) {
        if (user == address(0)) revert ErrZeroAddress();
        if (block.timestamp > deadline) revert ErrExpired();

        // Fixed-length ECDSA signatures only
        if (sig.length != 65) revert ErrBadSig();

        bytes32 structHash =
            keccak256(abi.encode(_CONSUME_TYPEHASH, user, newCumConsumed, windowId, deadline));
        address s = _recoverSigner(structHash, sig);
        if (!isConsumeSigner[s]) revert ErrOnlyConsumeSigner();

        Account storage a = accounts[user];
        uint256 old = uint256(a.reservedConsumed);
        if (newCumConsumed < old) revert ErrConsumedDecrease();

        delta = newCumConsumed - old;
        if (delta == 0) {
            emit ConsumedSynced(user, newCumConsumed, 0);
            return 0;
        }
        if (newCumConsumed > uint256(a.reservedTotal)) revert ErrConsumedOverReserve();

        // Settle time-weighted state before moving reservedConsumed
        _accumulate(user);

        uint256 bal = uint256(a.balance);
        if (bal < delta) revert ErrInsufficient();

        unchecked {
            a.balance = uint128(bal - delta);
            totalDeposits -= delta;
            a.reservedConsumed = uint128(newCumConsumed);
            totalConsumedForRoyaltyAll += delta;
        }

        emit ConsumedSynced(user, newCumConsumed, uint128(delta));
    }

    function syncConsumedSigned(
        address user,
        uint256 newCumConsumed,
        uint256 windowId,
        uint256 deadline,
        bytes calldata sig
    ) external nonReentrant whenNotPaused {
        _applyConsumedSigned(user, newCumConsumed, windowId, deadline, sig);
    }

    function syncConsumedAndWithdraw(
        uint256 withdrawAmount,
        uint256 newCumConsumed,
        uint256 windowId,
        uint256 deadline,
        bytes calldata sig
    ) external nonReentrant whenNotPaused {
        address user = msg.sender;
        if (withdrawAmount == 0) revert ErrAmountZero();

        // First apply the signed consumption update
        _applyConsumedSigned(user, newCumConsumed, windowId, deadline, sig);

        Account storage a = accounts[user];
        uint256 royaltyBuf = claimableRoyalty[user];
        uint256 w = _withdrawableOf(a);
        uint256 totalAvail = w + royaltyBuf;
        if (withdrawAmount > totalAvail) revert ErrInsufficient();

        uint256 fromRoyalty = withdrawAmount <= royaltyBuf ? withdrawAmount : royaltyBuf;
        uint256 fromDeposit = withdrawAmount - fromRoyalty;

        if (fromDeposit > 0) {
            unchecked {
                a.balance = uint128(uint256(a.balance) - fromDeposit);
                totalDeposits -= fromDeposit;
            }
        }
        if (fromRoyalty > 0) {
            unchecked {
                claimableRoyalty[user] = royaltyBuf - fromRoyalty;
                totalRoyaltyPaidAll += fromRoyalty;
            }
            emit RoyaltyPaid(user, fromRoyalty);
        }

        USDT.safeTransfer(user, withdrawAmount);
        emit Withdraw(user, uint128(fromDeposit));
    }

    // ---------------- IDO: participate with Stateless Allowance ----------------
    event IdoParticipated(
        address indexed user,
        uint128 usdtAmount,
        address indexed ido,
        address indexed projectTreasury
    );

    // Relayer-triggered IDO participation using reserved funds
    function participateIdo(
        address user,
        uint256 usdtAmount,
        bytes32 rightId
    ) external nonReentrant whenNotPaused onlyRelayer {
        if (user == address(0)) revert ErrZeroAddress();
        if (usdtAmount == 0) revert ErrAmountZero();
        if (projectTreasury == address(0)) revert ErrTreasuryUnset();

        address ido = idoOf[rightId];
        if (ido == address(0) || !isApprovedIdo[ido]) revert ErrIdoNotApproved();

        Account storage a = accounts[user];

        _accumulate(user);

        uint256 ra = _reservedAvail(a);
        if (usdtAmount > ra) revert ErrInsufficient();

        uint256 bal = uint256(a.balance);
        if (bal < usdtAmount) revert ErrInsufficient();

        // Effects before interaction
        unchecked {
            a.balance = uint128(bal - usdtAmount);
            totalDeposits -= usdtAmount;
            a.reservedConsumed =
                uint128(uint256(a.reservedConsumed) + usdtAmount);
            totalConsumedForRoyaltyAll += usdtAmount;
        }

        emit IdoParticipated(user, uint128(usdtAmount), ido, projectTreasury);

        // Stateless allowance: approve exact amount, then reset
        USDT.forceApprove(ido, 0);
        USDT.forceApprove(ido, usdtAmount);

        uint256 beforeBal = USDT.balanceOf(address(this));
        IIDOLauncher(ido).buyFor(user, rightId, usdtAmount);
        uint256 afterBal = USDT.balanceOf(address(this));

        USDT.forceApprove(ido, 0);

        if (afterBal >= beforeBal) revert ErrIdoPullMismatch();
        if (beforeBal - afterBal != usdtAmount) revert ErrIdoPullMismatch();
    }

    // Legacy function kept only for interface compatibility; always reverts
    function setIdoAllowance(address /*ido*/, uint256 /*amount*/) external view onlyOwner {
        revert ErrDeprecated();
    }

    // ---------------- Oracle: royalty claim (cumulative) ----------------
    // Claim royalties based on a signed cumulative allocation
    function claimRoyaltySigned(
        uint256 newCumulativeAmount,
        uint256 windowId,
        uint256 deadline,
        bytes calldata sig
    ) external nonReentrant {
        if (block.timestamp > deadline) revert ErrExpired();
        if (sig.length != 65) revert ErrBadSig();
        address user = msg.sender;

        bytes32 structHash =
            keccak256(abi.encode(_ROYALTY_TYPEHASH, user, newCumulativeAmount, windowId, deadline));
        address s = _recoverSigner(structHash, sig);
        if (!isRoyaltySigner[s]) revert ErrOnlyRoyaltySigner();

        uint256 already = royaltyClaimedCumulative[user];
        if (newCumulativeAmount < already) revert ErrRoyaltyDecrease();

        uint256 delta = newCumulativeAmount - already;
        if (delta == 0) return;

        if (totalRoyaltyAllocatedAll + delta > totalConsumedForRoyaltyAll) {
            revert ErrRoyaltyOverBudget();
        }

        royaltyClaimedCumulative[user] = newCumulativeAmount;
        unchecked {
            claimableRoyalty[user] += delta;
            totalRoyaltyAllocatedAll += delta;
        }
        emit RoyaltyAllocated(user, delta);
    }

    // ---------------- BTX Merkle (immutable per epoch) ----------------
    function setBtxRoot(bytes32 epoch, bytes32 root) external onlyOwner {
        if (root == bytes32(0)) revert ErrRootNotSet();
        if (btxRoot[epoch] != bytes32(0)) revert ErrRootAlreadySet();
        btxRoot[epoch] = root;
        emit BtxRootSet(epoch, root);
    }

    function claimBTX(bytes32 epoch, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        bytes32 root = btxRoot[epoch];
        if (root == bytes32(0)) revert ErrRootNotSet();

        // Use abi.encode to preserve explicit types and lengths in the leaf
        bytes32 leaf = keccak256(abi.encode(msg.sender, amount));
        if (!MerkleProof.verify(proof, root, leaf)) revert ErrBadProof();

        uint256 already = btxClaimed[epoch][msg.sender];
        if (already >= amount) revert ErrAlreadyClaimed();

        uint256 delta = amount - already;
        unchecked {
            btxClaimed[epoch][msg.sender] = amount;
        }

        BTX.safeTransfer(msg.sender, delta);
        emit BTXClaimed(epoch, msg.sender, delta);
    }

    // ---------------- Views (cached / preview / full) ----------------
    function accountInfoRaw(address user)
        external
        view
        returns (
            uint256 balance,
            uint256 reservedTotal,
            uint256 reservedConsumed,
            uint64  lastTs,
            uint256 accBalanceSeconds,
            uint256 withdrawable,
            uint256 reservedAvail
        )
    {
        Account storage a = accounts[user];
        balance = a.balance;
        reservedTotal = a.reservedTotal;
        reservedConsumed = a.reservedConsumed;
        lastTs = a.lastTs;
        accBalanceSeconds = a.accBalanceSeconds;

        (reservedAvail, withdrawable) = _calcReservedAvailAndWithdrawable(
            uint256(balance),
            uint256(reservedTotal),
            uint256(reservedConsumed)
        );
    }

    function previewAccBalanceSeconds(address user) external view returns (uint256) {
        Account storage a = accounts[user];
        return _previewAccBalanceSeconds(a);
    }

    function withdrawableOf(address user) external view returns (uint256) {
        Account storage a = accounts[user];
        uint256 reservedAvail = uint256(a.reservedTotal) - uint256(a.reservedConsumed);
        uint256 bal = uint256(a.balance);
        return bal > reservedAvail ? bal - reservedAvail : 0;
    }

    function accountInfo(address user)
        external
        view
        returns (
            uint256 balance,
            uint256 reservedTotal,
            uint256 reservedConsumed,
            uint64  lastTs,
            uint256 accBalanceSeconds,
            uint256 withdrawable,
            uint256 reservedAvail
        )
    {
        Account storage a = accounts[user];
        balance = a.balance;
        reservedTotal = a.reservedTotal;
        reservedConsumed = a.reservedConsumed;
        lastTs = a.lastTs;

        accBalanceSeconds = _previewAccBalanceSeconds(a);

        (reservedAvail, withdrawable) = _calcReservedAvailAndWithdrawable(
            uint256(balance),
            uint256(reservedTotal),
            uint256(reservedConsumed)
        );
    }

    // ---------------- Owner excess withdraw ----------------
    // Compute how much USDT is free beyond deposits and royalty obligations
    function getUsdtWithdrawableExcess() public view returns (uint256) {
        uint256 vaultBal = USDT.balanceOf(address(this));
        uint256 paid = totalRoyaltyPaidAll;
        uint256 consumed = totalConsumedForRoyaltyAll;
        uint256 reservedForRoyalties = consumed > paid ? (consumed - paid) : 0;
        uint256 minRequired = totalDeposits + reservedForRoyalties;
        return vaultBal > minRequired ? (vaultBal - minRequired) : 0;
    }

    function withdrawExcessUSDT(uint256 amount) external onlyOwner nonReentrant {
        uint256 maxExcess = getUsdtWithdrawableExcess();
        if (amount > maxExcess) revert ErrExceedsExcessUSDT();
        USDT.safeTransfer(msg.sender, amount);
    }

    // ---------------- Monthly announcement (event-only) ----------------
    // Emit a monthly snapshot for offchain consumers
    function announceMonthlyVaultPower(
        bytes32 epoch,
        uint16 y,
        uint8 m,
        uint256 ts,
        uint256 alloc
    ) external onlyOwner {
        emit MonthlyVaultPowerAnnounced(epoch, y, m, ts, alloc);
    }
}
