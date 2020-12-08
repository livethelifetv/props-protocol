// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import "@openzeppelin/contracts/math/SafeMath.sol";

import "./interfaces/ILockableERC20.sol";

contract SProps is ILockableERC20 {
    /// @notice EIP-20 token name for this token
    string public constant name = "sProps";

    /// @notice EIP-20 token symbol for this token
    string public constant symbol = "SPROPS";

    /// @notice EIP-20 token decimals for this token
    uint8 public constant decimals = 18;

    /// @notice Total number of tokens in circulation
    uint256 public override totalSupply = 1_000_000_000e18; // 1 billion sProps

    /// @notice Address which may mint new tokens
    address public minter;

    /// @notice The timestamp after which minting may occur
    uint256 public mintingAllowedAfter;

    /// @notice Minimum time between mints
    uint32 public constant minimumTimeBetweenMints = 1 days * 365;

    /// @notice Cap on the percentage of totalSupply that can be minted at each mint
    uint8 public constant mintCap = 2;

    /// @notice Allowance amounts on behalf of others
    mapping(address => mapping(address => uint96)) internal allowances;

    /// @notice Official record of token balances for each account
    mapping(address => uint96) internal balances;

    /// @notice Lock duration
    uint32 public constant lockDuration = 1 days * 30;

    /// @notice A record of each accounts total locked tokens
    mapping(address => uint96) public totalLocked;

    /// @notice A record of each accounts individual lock times on tokens
    mapping(address => uint256[]) public lockTimes;

    /// @notice A record of each accounts individual locks on tokens
    mapping(address => mapping(uint256 => uint96)) public locks;

    /// @notice A record of each accounts delegate
    mapping(address => address) public delegates;

    /// @notice A checkpoint for marking number of votes from a given block
    struct Checkpoint {
        uint32 fromBlock;
        uint96 votes;
    }

    /// @notice A record of votes checkpoints for each account, by index
    mapping(address => mapping(uint32 => Checkpoint)) public checkpoints;

    /// @notice The number of checkpoints for each account
    mapping(address => uint32) public numCheckpoints;

    /// @notice The EIP-712 typehash for the contract"s domain
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    /// @notice The EIP-712 typehash for the delegation struct used by the contract
    bytes32 public constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    /// @notice The EIP-712 typehash for the permit struct used by the contract
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );

    /// @notice A record of states for signing / validating signatures
    mapping(address => uint256) public nonces;

    /// @notice An event thats emitted when the minter address is changed
    event MinterChanged(address minter, address newMinter);

    /// @notice An event thats emitted when an account receives new locked tokens
    event Locked(address indexed account, uint256 amount, uint256 lockTime, uint256 unlockTime);

    /// @notice An event thats emitted when an account unlocks previously locked tokens
    event Unlocked(address indexed account, uint256 amount, uint256 lockTime);

    /// @notice An event thats emitted when an account changes its delegate
    event DelegateChanged(
        address indexed delegator,
        address indexed fromDelegate,
        address indexed toDelegate
    );

    /// @notice An event thats emitted when a delegate account"s vote balance changes
    event DelegateVotesChanged(
        address indexed delegate,
        uint256 previousBalance,
        uint256 newBalance
    );

    /// @notice The standard EIP-20 transfer event
    event Transfer(address indexed from, address indexed to, uint256 amount);

    /// @notice The standard EIP-20 approval event
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    /**
     * @notice Construct a new SProps token
     * @param account The initial account to grant all the tokens
     * @param minter_ The account with minting ability
     * @param mintingAllowedAfter_ The timestamp after which minting may occur
     */
    constructor(
        address account,
        address minter_,
        uint256 mintingAllowedAfter_
    ) public {
        require(
            mintingAllowedAfter_ >= block.timestamp,
            "SProps::constructor: minting can only begin after deployment"
        );

        balances[account] = uint96(totalSupply);
        emit Transfer(address(0), account, totalSupply);
        minter = minter_;
        emit MinterChanged(address(0), minter);
        mintingAllowedAfter = mintingAllowedAfter_;
    }

    /**
     * @notice Change the minter address
     * @param minter_ The address of the new minter
     */
    function setMinter(address minter_) external {
        require(
            msg.sender == minter,
            "SProps::setMinter: only the minter can change the minter address"
        );
        emit MinterChanged(minter, minter_);
        minter = minter_;
    }

    /**
     * @notice Mint new tokens
     * @param dst The address of the destination account
     * @param rawAmount The number of tokens to be minted
     */
    function mint(address dst, uint256 rawAmount) external {
        require(msg.sender == minter, "SProps::mint: only the minter can mint");
        require(block.timestamp >= mintingAllowedAfter, "SProps::mint: minting not allowed yet");
        require(dst != address(0), "SProps::mint: cannot transfer to the zero address");

        // record the mint
        mintingAllowedAfter = SafeMath.add(block.timestamp, minimumTimeBetweenMints);

        // mint the amount
        uint96 amount = safe96(rawAmount, "SProps::mint: amount exceeds 96 bits");
        require(
            amount <= SafeMath.div(SafeMath.mul(totalSupply, mintCap), 100),
            "SProps::mint: exceeded mint cap"
        );
        totalSupply = safe96(
            SafeMath.add(totalSupply, amount),
            "SProps::mint: totalSupply exceeds 96 bits"
        );

        // transfer the amount to the recipient
        balances[dst] = add96(balances[dst], amount, "SProps::mint: transfer amount overflows");
        emit Transfer(address(0), dst, amount);

        // move delegates
        _moveDelegates(address(0), delegates[dst], amount);
    }

    /**
     * @notice Get the number of tokens `spender` is approved to spend on behalf of `account`
     * @param account The address of the account holding the funds
     * @param spender The address of the account spending the funds
     * @return The number of tokens approved
     */
    function allowance(address account, address spender) external view override returns (uint256) {
        return allowances[account][spender];
    }

    /**
     * @notice Approve `spender` to transfer up to `amount` from `src`
     * @dev This will overwrite the approval amount for `spender`
     *  and is subject to issues noted [here](https://eips.ethereum.org/EIPS/eip-20#approve)
     * @param spender The address of the account which may transfer tokens
     * @param rawAmount The number of tokens that are approved (2^256-1 means infinite)
     * @return Whether or not the approval succeeded
     */
    function approve(address spender, uint256 rawAmount) external override returns (bool) {
        uint96 amount;
        if (rawAmount == uint256(-1)) {
            amount = uint96(-1);
        } else {
            amount = safe96(rawAmount, "SProps::approve: amount exceeds 96 bits");
        }

        allowances[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Triggers an approval from owner to spends
     * @param owner The address to approve from
     * @param spender The address to be approved
     * @param rawAmount The number of tokens that are approved (2^256-1 means infinite)
     * @param deadline The time at which to expire the signature
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     */
    function permit(
        address owner,
        address spender,
        uint256 rawAmount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        uint96 amount;
        if (rawAmount == uint256(-1)) {
            amount = uint96(-1);
        } else {
            amount = safe96(rawAmount, "SProps::permit: amount exceeds 96 bits");
        }

        bytes32 domainSeparator =
            keccak256(
                abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), getChainId(), address(this))
            );
        bytes32 structHash =
            keccak256(
                abi.encode(PERMIT_TYPEHASH, owner, spender, rawAmount, nonces[owner]++, deadline)
            );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "SProps::permit: invalid signature");
        require(signatory == owner, "SProps::permit: unauthorized");
        require(now <= deadline, "SProps::permit: signature expired");

        allowances[owner][spender] = amount;

        emit Approval(owner, spender, amount);
    }

    /**
     * @notice Get the number of tokens held by the `account`
     * @param account The address of the account to get the balance of
     * @return The number of tokens held
     */
    function balanceOf(address account) public view override returns (uint256) {
        return balances[account];
    }

    /**
     * @notice Get the total number of tokens held by the `account` (locked + transferable)
     * @param account The address of the account to get the total balance of
     * @return The total number of tokens held
     */
    function totalBalanceOf(address account) public view override returns (uint256) {
        return SafeMath.add(balances[account], totalLocked[account]);
    }

    /**
     * @notice Transfer `amount` tokens from `msg.sender` to `dst`
     * @param dst The address of the destination account
     * @param rawAmount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transfer(address dst, uint256 rawAmount) external override returns (bool) {
        uint96 amount = safe96(rawAmount, "SProps::transfer: amount exceeds 96 bits");
        _transferTokens(msg.sender, dst, amount);
        return true;
    }

    /**
     * @notice Transfer `amount` tokens from `src` to `dst`
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param rawAmount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transferFrom(
        address src,
        address dst,
        uint256 rawAmount
    ) external override returns (bool) {
        address spender = msg.sender;
        uint96 spenderAllowance = allowances[src][spender];
        uint96 amount = safe96(rawAmount, "SProps::transferFrom: amount exceeds 96 bits");

        if (spender != src && spenderAllowance != uint96(-1)) {
            uint96 newAllowance =
                sub96(
                    spenderAllowance,
                    amount,
                    "SProps::transferFrom: transfer amount exceeds spender allowance"
                );
            allowances[src][spender] = newAllowance;

            emit Approval(src, spender, newAllowance);
        }

        _transferTokens(src, dst, amount);
        return true;
    }

    /**
     * @notice Transfers and locks `amount` tokens from `msg.sender` to `dst`
     * @param dst The address of the destination account
     * @param rawAmount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transferWithLock(address dst, uint256 rawAmount) external override returns (bool) {
        require(locks[dst][now] == 0, "SProps::transferWithLock: tokens already locked");
        require(rawAmount != 0, "SProps::transferWithLock: amount cannot be 0");

        uint96 amount = safe96(rawAmount, "SProps::transferWithLock: amount exceeds 96 bits");

        locks[dst][now] = amount;
        totalLocked[dst] = add96(
            totalLocked[dst],
            amount,
            "SProps::transferWithLock: total locked amount overflows"
        );
        lockTimes[dst].push(now);

        _transferTokens(msg.sender, address(this), amount);

        emit Locked(dst, amount, now, SafeMath.add(now, lockDuration));
        return true;
    }

    /**
     * @notice Unlocks the requested locked tokens of the `account`
     * @param account Address claiming back unlockable tokens
     * @param lockTimesToUnlock Array of lock times requested to be unlocked
     */
    function unlock(address account, uint256[] calldata lockTimesToUnlock) external override {
        uint96 unlockedTokens = 0;
        for (uint256 i = 0; i < lockTimesToUnlock.length; i++) {
            uint96 lockedTokens = locks[account][lockTimesToUnlock[i]];
            if (lockedTokens > 0 && SafeMath.sub(now, lockTimesToUnlock[i]) > lockDuration) {
                delete locks[account][lockTimesToUnlock[i]];
                unlockedTokens = add96(
                    unlockedTokens,
                    lockedTokens,
                    "SProps::unlock: unlockable amount overflows"
                );
                totalLocked[account] = sub96(
                    totalLocked[account],
                    lockedTokens,
                    "SProps::unlock: total locked amount underflows"
                );
                emit Unlocked(account, lockedTokens, lockTimesToUnlock[i]);
            }
        }

        if (unlockedTokens > 0) {
            _transferTokens(address(this), account, unlockedTokens);
        }
    }

    /**
     * @notice Delegate votes from `msg.sender` to `delegatee`
     * @param delegatee The address to delegate votes to
     */
    function delegate(address delegatee) public {
        return _delegate(msg.sender, delegatee);
    }

    /**
     * @notice Delegates votes from signatory to `delegatee`
     * @param delegatee The address to delegate votes to
     * @param nonce The contract state required to match the signature
     * @param expiry The time at which to expire the signature
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     */
    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        bytes32 domainSeparator =
            keccak256(
                abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), getChainId(), address(this))
            );
        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "SProps::delegateBySig: invalid signature");
        require(nonce == nonces[signatory]++, "SProps::delegateBySig: invalid nonce");
        require(now <= expiry, "SProps::delegateBySig: signature expired");
        return _delegate(signatory, delegatee);
    }

    /**
     * @notice Gets the current votes balance for `account`
     * @param account The address to get votes balance
     * @return The number of current votes for `account`
     */
    function getCurrentVotes(address account) external view returns (uint96) {
        uint32 nCheckpoints = numCheckpoints[account];
        return nCheckpoints > 0 ? checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    /**
     * @notice Determine the prior number of votes for an account as of a block number
     * @dev Block number must be a finalized block or else this function will revert to prevent misinformation.
     * @param account The address of the account to check
     * @param blockNumber The block number to get the vote balance at
     * @return The number of votes the account had as of the given block
     */
    function getPriorVotes(address account, uint256 blockNumber) public view returns (uint96) {
        require(blockNumber < block.number, "SProps::getPriorVotes: not yet determined");

        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return checkpoints[account][nCheckpoints - 1].votes;
        }

        // Next check implicit zero balance
        if (checkpoints[account][0].fromBlock > blockNumber) {
            return 0;
        }

        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[account][center];
            if (cp.fromBlock == blockNumber) {
                return cp.votes;
            } else if (cp.fromBlock < blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return checkpoints[account][lower].votes;
    }

    function _delegate(address delegator, address delegatee) internal {
        address currentDelegate = delegates[delegator];
        uint96 delegatorBalance =
            safe96(
                this.totalBalanceOf(delegator),
                "SProps::_delegate: total balance of delegator overflows"
            );
        delegates[delegator] = delegatee;

        emit DelegateChanged(delegator, currentDelegate, delegatee);

        _moveDelegates(currentDelegate, delegatee, delegatorBalance);
    }

    function _transferTokens(
        address src,
        address dst,
        uint96 amount
    ) internal {
        require(
            src != address(0),
            "SProps::_transferTokens: cannot transfer from the zero address"
        );
        require(dst != address(0), "SProps::_transferTokens: cannot transfer to the zero address");

        balances[src] = sub96(
            balances[src],
            amount,
            "SProps::_transferTokens: transfer amount exceeds balance"
        );
        balances[dst] = add96(
            balances[dst],
            amount,
            "SProps::_transferTokens: transfer amount overflows"
        );
        emit Transfer(src, dst, amount);

        _moveDelegates(delegates[src], delegates[dst], amount);
    }

    function _moveDelegates(
        address srcRep,
        address dstRep,
        uint96 amount
    ) internal {
        if (srcRep != dstRep && amount > 0) {
            if (srcRep != address(0)) {
                uint32 srcRepNum = numCheckpoints[srcRep];
                uint96 srcRepOld = srcRepNum > 0 ? checkpoints[srcRep][srcRepNum - 1].votes : 0;
                uint96 srcRepNew =
                    sub96(srcRepOld, amount, "SProps::_moveVotes: vote amount underflows");
                _writeCheckpoint(srcRep, srcRepNum, srcRepOld, srcRepNew);
            }

            if (dstRep != address(0)) {
                uint32 dstRepNum = numCheckpoints[dstRep];
                uint96 dstRepOld = dstRepNum > 0 ? checkpoints[dstRep][dstRepNum - 1].votes : 0;
                uint96 dstRepNew =
                    add96(dstRepOld, amount, "SProps::_moveVotes: vote amount overflows");
                _writeCheckpoint(dstRep, dstRepNum, dstRepOld, dstRepNew);
            }
        }
    }

    function _writeCheckpoint(
        address delegatee,
        uint32 nCheckpoints,
        uint96 oldVotes,
        uint96 newVotes
    ) internal {
        uint32 blockNumber =
            safe32(block.number, "SProps::_writeCheckpoint: block number exceeds 32 bits");

        if (nCheckpoints > 0 && checkpoints[delegatee][nCheckpoints - 1].fromBlock == blockNumber) {
            checkpoints[delegatee][nCheckpoints - 1].votes = newVotes;
        } else {
            checkpoints[delegatee][nCheckpoints] = Checkpoint(blockNumber, newVotes);
            numCheckpoints[delegatee] = nCheckpoints + 1;
        }

        emit DelegateVotesChanged(delegatee, oldVotes, newVotes);
    }

    function safe32(uint256 n, string memory errorMessage) internal pure returns (uint32) {
        require(n < 2**32, errorMessage);
        return uint32(n);
    }

    function safe96(uint256 n, string memory errorMessage) internal pure returns (uint96) {
        require(n < 2**96, errorMessage);
        return uint96(n);
    }

    function add96(
        uint96 a,
        uint96 b,
        string memory errorMessage
    ) internal pure returns (uint96) {
        uint96 c = a + b;
        require(c >= a, errorMessage);
        return c;
    }

    function sub96(
        uint96 a,
        uint96 b,
        string memory errorMessage
    ) internal pure returns (uint96) {
        require(b <= a, errorMessage);
        return a - b;
    }

    function getChainId() internal pure returns (uint256) {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        return chainId;
    }
}