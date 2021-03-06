// SPDX-License-Identifier: MIT

pragma solidity 0.6.8;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/math/SignedSafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import "./interfaces/IPropsProtocol.sol";
import "./interfaces/IPropsToken.sol";
import "./interfaces/IRPropsToken.sol";
import "./interfaces/ISPropsToken.sol";
import "./interfaces/IStaking.sol";

/**
 * @title  PropsProtocol
 * @author Props
 * @notice Entry point for participating in the Props protocol. All user actions
 *         are to be done exclusively through this contract.
 * @dev    It is responsible for proxying staking-related actions to the appropriate
 *         staking contracts. Moreover, it also handles sProps minting and burning,
 *         sProps staking, swapping earned rProps for regular Props and escrowing
 *         user Props rewards.
 */
contract PropsProtocol is Initializable, PausableUpgradeable, IPropsProtocol {
    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /**************************************
                     FIELDS
    ***************************************/

    // The Props protocol controller
    address public controller;

    // The Props protocol guardian (has the ability to pause/unpause the protocol)
    address public guardian;

    // Props protocol related tokens
    address public propsToken;
    address public sPropsToken;
    address public rPropsToken;

    // The factory contract for deploying new apps
    address public appProxyFactory;

    // The staking contract for earning apps Props rewards
    address public propsAppStaking;
    // The staking contract for earning users Props rewards
    address public propsUserStaking;

    // Mapping from app points contract to the associated app points staking contract
    mapping(address => address) public appPointsStaking;

    // Mapping of the total amount of Props principal staked by each user to every app
    // eg. stakes[userAddress][appPointsAddress]
    mapping(address => mapping(address => uint256)) public stakes;
    // Mapping of the total amount of Props rewards staked by each user to every app
    // eg. rewardStakes[userAddress][appPointsAddress]
    mapping(address => mapping(address => uint256)) public rewardStakes;

    // Keeps track of the staking delegatees of users
    mapping(address => address) public delegates;

    // Mapping of the total amount of escrowed rewards of each user
    mapping(address => uint256) public rewardsEscrow;
    // Mapping of the unlock time for the escrowed rewards of each user
    mapping(address => uint256) public rewardsEscrowUnlock;

    // The cooldown period for the rewards escrow
    uint256 public rewardsEscrowCooldown;

    // Keeps track of the protocol-whitelisted apps
    mapping(address => uint8) private whitelist;

    /**************************************
                     EVENTS
    ***************************************/

    event Stake(address indexed app, address indexed account, int256 amount);
    event RewardsStake(address indexed app, address indexed account, int256 amount);
    event RewardsEscrowUpdated(address indexed account, uint256 lockedAmount, uint256 unlockTime);
    event AppWhitelisted(address indexed app);
    event AppBlacklisted(address indexed app);
    event DelegateChanged(address indexed delegator, address indexed delegatee);

    /**************************************
                    MODIFIERS
    ***************************************/

    modifier only(address _account) {
        require(msg.sender == _account, "Unauthorized");
        _;
    }

    modifier notSet(address _field) {
        require(_field == address(0), "Already set");
        _;
    }

    modifier validApp(address _app) {
        require(appPointsStaking[_app] != address(0), "Invalid app");
        _;
    }

    /***************************************
                   INITIALIZER
    ****************************************/

    /**
     * @dev Initializer.
     * @param _controller The Props protocol controller
     * @param _guardian The Props protocol guardian
     * @param _propsToken The Props token contract
     */
    function initialize(
        address _controller,
        address _guardian,
        address _propsToken
    ) public initializer {
        PausableUpgradeable.__Pausable_init();

        controller = _controller;
        guardian = _guardian;
        propsToken = _propsToken;
        rewardsEscrowCooldown = 90 days;
    }

    /***************************************
                GUARDIAN ACTIONS
    ****************************************/

    /**
     * @dev Pause the protocol.
     */
    function pause() external only(guardian) {
        _pause();
    }

    /**
     * @dev Unpause the protocol.
     */
    function unpause() external only(guardian) {
        _unpause();
    }

    /***************************************
                CONTROLLER ACTIONS
    ****************************************/

    /*
     * The following set methods are required to be called before any contract interaction:
     * - setAppProxyFactory
     * - setRPropsToken
     * - setSPropsToken
     * - setPropsAppStaking
     * - setPropsUserStaking
     */

    /**
     * @dev Set the app proxy factory contract.
     * @param _appProxyFactory The address of the app proxy factory contract
     */
    function setAppProxyFactory(address _appProxyFactory)
        external
        only(controller)
        notSet(appProxyFactory)
    {
        appProxyFactory = _appProxyFactory;
    }

    /**
     * @dev Set the rProps token contract.
     * @param _rPropsToken The address of the rProps token contract
     */
    function setRPropsToken(address _rPropsToken) external only(controller) notSet(rPropsToken) {
        rPropsToken = _rPropsToken;
    }

    /**
     * @dev Set the sProps token contract.
     * @param _sPropsToken The address of the sProps token contract
     */
    function setSPropsToken(address _sPropsToken) external only(controller) notSet(sPropsToken) {
        sPropsToken = _sPropsToken;
    }

    /**
     * @dev Set the staking contract for earning apps Props rewards.
     * @param _propsAppStaking The address of the staking contract for earning apps Props rewards
     */
    function setPropsAppStaking(address _propsAppStaking)
        external
        only(controller)
        notSet(propsAppStaking)
    {
        propsAppStaking = _propsAppStaking;
    }

    /**
     * @dev Set the staking contract for earning users Props rewards.
     * @param _propsUserStaking The address of the staking contract for earning users Props rewards.
     */
    function setPropsUserStaking(address _propsUserStaking)
        external
        only(controller)
        notSet(propsUserStaking)
    {
        propsUserStaking = _propsUserStaking;
    }

    /**
     * @dev Change the cooldown period for the escrowed rewards.
     * @param _rewardsEscrowCooldown The cooldown period for the escrowed rewards
     */
    function changeRewardsEscrowCooldown(uint256 _rewardsEscrowCooldown) external only(controller) {
        rewardsEscrowCooldown = _rewardsEscrowCooldown;
    }

    /**
     * @dev Whitelist an app.
     * @param _app The address of the app to be whitelisted
     */
    function whitelistApp(address _app) external only(controller) {
        whitelist[_app] = 1;
        emit AppWhitelisted(_app);
    }

    /**
     * @dev Blacklist an app.
     * @param _app The address of the app to be blacklisted
     */
    function blacklistApp(address _app) external only(controller) {
        whitelist[_app] = 0;
        emit AppBlacklisted(_app);
    }

    /**
     * @dev Distribute the rProps rewards to the app and user Props staking contracts.
     * @param _appRewardsPercentage The percentage of minted rProps to go to the app Props staking contract
     * @param _userRewardsPercentage The percentage of minted rProps to go to the user Props staking contract
     */
    function distributePropsRewards(uint256 _appRewardsPercentage, uint256 _userRewardsPercentage)
        external
        only(controller)
    {
        IRPropsToken(rPropsToken).distributeRewards(
            propsAppStaking,
            _appRewardsPercentage,
            propsUserStaking,
            _userRewardsPercentage
        );
    }

    /***************************************
               APP FACTORY ACTIONS
    ****************************************/

    /**
     * @dev Save identification information for a newly deployed app.
     * @param _appPoints The address of the app points contract
     * @param _appPointsStaking The address of the app points staking contract
     */
    function saveApp(address _appPoints, address _appPointsStaking)
        external
        override
        only(appProxyFactory)
        whenNotPaused
    {
        appPointsStaking[_appPoints] = _appPointsStaking;
    }

    /***************************************
                  USER ACTIONS
    ****************************************/

    /**
     * @dev Delegate staking rights.
     * @param _to The account to delegate to
     */
    function delegate(address _to) external whenNotPaused {
        delegates[msg.sender] = _to;
        emit DelegateChanged(msg.sender, _to);
    }

    /**
     * @dev Stake on behalf of an account. It makes it possible to easily
     *      transfer a staking portofolio to someone else. The staked Props
     *      are transferred from the sender's account but staked on behalf of
     *      the requested account.
     * @param _apps Array of apps to stake to
     * @param _amounts Array of amounts to stake to each app
     * @param _account Account to stake on behalf of
     */
    function stakeOnBehalf(
        address[] memory _apps,
        uint256[] memory _amounts,
        address _account
    ) public whenNotPaused {
        // Convert from uint256 to int256
        int256[] memory amounts = new int256[](_amounts.length);
        for (uint256 i = 0; i < _amounts.length; i++) {
            amounts[i] = _safeInt256(_amounts[i]);
        }

        _stake(_apps, amounts, msg.sender, _account, false);
    }

    /**
     * @dev Same as above but uses an off-chain signature to approve and
     *      stake in the same transaction.
     */
    function stakeOnBehalfWithPermit(
        address[] calldata _apps,
        uint256[] calldata _amounts,
        address _account,
        address _owner,
        address _spender,
        uint256 _amount,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external whenNotPaused {
        IPropsToken(propsToken).permit(_owner, _spender, _amount, _deadline, _v, _r, _s);
        stakeOnBehalf(_apps, _amounts, _account);
    }

    /**
     * @dev Stake/unstake to/from apps. This function is used for both staking
     *      and unstaking to/from apps. It accepts both positive and negative
     *      amounts, which represent an adjustment of the staked amount to the
     *      corresponding app.
     * @param _apps Array of apps to stake/unstake to/from
     * @param _amounts Array of amounts to stake/unstake to/from each app
     */
    function stake(address[] memory _apps, int256[] memory _amounts) public whenNotPaused {
        _stake(_apps, _amounts, msg.sender, msg.sender, false);
    }

    /**
     * @dev Same as above but uses an off-chain signature to approve and
     *      stake in the same transaction.
     */
    function stakeWithPermit(
        address[] calldata _apps,
        int256[] calldata _amounts,
        address _owner,
        address _spender,
        uint256 _amount,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external whenNotPaused {
        IPropsToken(propsToken).permit(_owner, _spender, _amount, _deadline, _v, _r, _s);
        stake(_apps, _amounts);
    }

    /**
     * @dev Stake on behalf of a delegator.
     * @param _apps Array of app tokens to stake/unstake to/from
     * @param _amounts Array of amounts to stake/unstake to/from each app token
     * @param _account Delegator account to stake on behalf of
     */
    function stakeAsDelegate(
        address[] calldata _apps,
        int256[] calldata _amounts,
        address _account
    ) external only(delegates[_account]) whenNotPaused {
        _stake(_apps, _amounts, _account, _account, false);
    }

    /**
     * @dev Similar to a regular stake operation, this function is used to
     *      stake/unstake to/from apps. The only difference is that it uses
     *      the escrowed rewards instead of transferring from the user's wallet.
     * @param _apps Array of apps to stake/unstake to/from
     * @param _amounts Array of amounts to stake/unstake to/from each app
     */
    function stakeRewards(address[] memory _apps, int256[] memory _amounts) public whenNotPaused {
        _stake(_apps, _amounts, msg.sender, msg.sender, true);
    }

    /**
     * @dev Stake rewards on behalf of a delegator.
     * @param _apps Array of apps to stake/unstake to/from
     * @param _amounts Array of amounts to stake/unstake to/from each app
     * @param _account Delegator account to stake on behalf of
     */
    function stakeRewardsAsDelegate(
        address[] memory _apps,
        int256[] memory _amounts,
        address _account
    ) public only(delegates[_account]) whenNotPaused {
        _stake(_apps, _amounts, _account, _account, true);
    }

    /**
     * @dev Allow users to claim their app points rewards.
     * @param _app The app to claim the app points rewards of
     */
    function claimAppPointsRewards(address _app) external validApp(_app) whenNotPaused {
        // Claim the rewards and transfer them to the user's wallet
        uint256 reward = IStaking(appPointsStaking[_app]).earned(msg.sender);
        if (reward > 0) {
            IStaking(appPointsStaking[_app]).claimReward(msg.sender);
            IERC20Upgradeable(_app).safeTransfer(msg.sender, reward);
        }
    }

    /**
     * @dev Allow app owners to claim their app's Props rewards.
     * @param _app The app to claim the Props rewards of
     */
    function claimAppPropsRewards(address _app)
        external
        validApp(_app)
        only(OwnableUpgradeable(_app).owner())
        whenNotPaused
    {
        // Claim the rewards and transfer them to the user's wallet
        uint256 reward = IStaking(propsAppStaking).earned(_app);
        if (reward > 0) {
            IStaking(propsAppStaking).claimReward(_app);
            IERC20Upgradeable(rPropsToken).safeTransfer(msg.sender, reward);
            // Since the rewards are in rProps, swap it for regular Props
            IRPropsToken(rPropsToken).swap(msg.sender);
        }
    }

    /**
     * @dev Allow app owners to claim and directly stake their app's Props rewards.
     * @param _app The app to claim and stake the Props rewards of
     */
    function claimAppPropsRewardsAndStake(address _app)
        external
        validApp(_app)
        only(OwnableUpgradeable(_app).owner())
        whenNotPaused
    {
        uint256 reward = IStaking(propsAppStaking).earned(_app);
        if (reward > 0) {
            IStaking(propsAppStaking).claimReward(_app);
            // Since the rewards are in rProps, swap it for regular Props
            IRPropsToken(rPropsToken).swap(address(this));

            address[] memory _apps = new address[](1);
            _apps[0] = _app;
            uint256[] memory _amounts = new uint256[](1);
            _amounts[0] = reward;

            this.stakeOnBehalf(_apps, _amounts, msg.sender);
        }
    }

    /**
     * @dev Allow users to claim their Props rewards.
     */
    function claimUserPropsRewards() external whenNotPaused {
        uint256 reward = IStaking(propsUserStaking).earned(msg.sender);
        if (reward > 0) {
            // Claim the rewards but don't transfer them to the user's wallet
            IStaking(propsUserStaking).claimReward(msg.sender);
            // Since the rewards are in rProps, swap it for regular Props
            IRPropsToken(rPropsToken).swap(address(this));

            // Place the rewards in the escrow and extend the cooldown period
            rewardsEscrow[msg.sender] = rewardsEscrow[msg.sender].add(reward);
            rewardsEscrowUnlock[msg.sender] = block.timestamp.add(rewardsEscrowCooldown);

            emit RewardsEscrowUpdated(
                msg.sender,
                rewardsEscrow[msg.sender],
                rewardsEscrowUnlock[msg.sender]
            );
        }
    }

    /**
     * @dev Allow users to claim and directly stake their Props rewards, without
     *      having the rewards go through the escrow (and thus having the unlock
     *      time of the escrow extended).
     * @param _apps Array of apps to stake to
     * @param _percentages Array of percentages of the claimed rewards to stake to each app
     */
    function claimUserPropsRewardsAndStake(
        address[] calldata _apps,
        uint256[] calldata _percentages
    ) external whenNotPaused {
        _claimUserPropsRewardsAndStake(_apps, _percentages, msg.sender);
    }

    /**
     * @dev Claim and stake user Props rewards on behalf of a delegator.
     * @param _apps Array of apps to stake to
     * @param _percentages Array of percentages of the claimed rewards to stake to each app
     * @param _account Delegator account to claim and stake on behalf of
     */
    function claimUserPropsRewardsAndStakeAsDelegate(
        address[] calldata _apps,
        uint256[] calldata _percentages,
        address _account
    ) external only(delegates[_account]) whenNotPaused {
        _claimUserPropsRewardsAndStake(_apps, _percentages, _account);
    }

    /**
     * @dev Allow users to unlock their escrowed Props rewards.
     */
    function unlockUserPropsRewards() external whenNotPaused {
        require(block.timestamp >= rewardsEscrowUnlock[msg.sender], "Rewards locked");

        if (rewardsEscrow[msg.sender] > 0) {
            // Empty the escrow
            uint256 escrowedRewards = rewardsEscrow[msg.sender];
            rewardsEscrow[msg.sender] = 0;

            // Transfer the rewards to the user's wallet
            IERC20Upgradeable(propsToken).safeTransfer(msg.sender, escrowedRewards);

            emit RewardsEscrowUpdated(msg.sender, 0, 0);
        }
    }

    /***************************************
                     HELPERS
    ****************************************/

    function _stake(
        address[] memory _apps,
        int256[] memory _amounts,
        address _from,
        address _to,
        bool _rewards
    ) internal {
        require(_apps.length == _amounts.length, "Invalid input");

        // First, handle all unstakes (negative amounts)
        uint256 totalUnstakedAmount = 0;
        for (uint256 i = 0; i < _apps.length; i++) {
            require(appPointsStaking[_apps[i]] != address(0), "Invalid app");

            if (_amounts[i] < 0) {
                uint256 amountToUnstake = uint256(SignedSafeMathUpgradeable.mul(_amounts[i], -1));

                // Update user total staked amounts
                if (_rewards) {
                    rewardStakes[_to][_apps[i]] = rewardStakes[_to][_apps[i]].sub(amountToUnstake);
                } else {
                    stakes[_to][_apps[i]] = stakes[_to][_apps[i]].sub(amountToUnstake);
                }

                // Unstake the Props from the app points staking contract
                IStaking(appPointsStaking[_apps[i]]).withdraw(_to, amountToUnstake);

                // Unstake the sProps from the app Props staking contract
                IStaking(propsAppStaking).withdraw(_apps[i], amountToUnstake);

                // Don't unstake the sProps from the user Props staking contract since some
                // of them might get re-staked when handling the positive amounts (only unstake
                // the left amount at the end)

                // Update the total unstaked amount
                totalUnstakedAmount = totalUnstakedAmount.add(amountToUnstake);

                if (_rewards) {
                    emit RewardsStake(_apps[i], _to, _amounts[i]);
                } else {
                    emit Stake(_apps[i], _to, _amounts[i]);
                }
            }
        }

        // Handle all stakes (positive amounts)
        for (uint256 i = 0; i < _apps.length; i++) {
            if (_amounts[i] > 0) {
                require(whitelist[_apps[i]] != 0, "App blacklisted");

                uint256 amountToStake = uint256(_amounts[i]);

                // Update user total staked amounts
                if (_rewards) {
                    rewardStakes[_to][_apps[i]] = rewardStakes[_to][_apps[i]].add(amountToStake);
                } else {
                    stakes[_to][_apps[i]] = stakes[_to][_apps[i]].add(amountToStake);
                }

                if (totalUnstakedAmount >= amountToStake) {
                    // If the previously unstaked amount can cover the stake then use that
                    totalUnstakedAmount = totalUnstakedAmount.sub(amountToStake);
                } else {
                    uint256 left = amountToStake.sub(totalUnstakedAmount);

                    if (_rewards) {
                        // Otherwise, if we are handling the rewards, get the needed Props from escrow
                        rewardsEscrow[_from] = rewardsEscrow[_from].sub(left);

                        emit RewardsEscrowUpdated(
                            _to,
                            rewardsEscrow[_to],
                            rewardsEscrowUnlock[_to]
                        );
                    } else if (_from != address(this)) {
                        // When acting on behalf of a delegator no transfers are allowed
                        require(msg.sender == _from, "Unauthorized");

                        // Otherwise, if we are handling the principal, transfer the needed Props
                        IERC20Upgradeable(propsToken).safeTransferFrom(_from, address(this), left);
                    }

                    // Mint corresponding sProps
                    ISPropsToken(sPropsToken).mint(_to, left);

                    // Also stake the corresponding sProps in the user Props staking contract
                    IStaking(propsUserStaking).stake(_to, left);

                    totalUnstakedAmount = 0;
                }

                // Stake the Props in the app points staking contract
                IStaking(appPointsStaking[_apps[i]]).stake(_to, amountToStake);

                // Stake the sProps in the app Props staking contract
                IStaking(propsAppStaking).stake(_apps[i], amountToStake);

                if (_rewards) {
                    emit RewardsStake(_apps[i], _to, _amounts[i]);
                } else {
                    emit Stake(_apps[i], _to, _amounts[i]);
                }
            }
        }

        // If more tokens were unstaked than staked
        if (totalUnstakedAmount > 0) {
            // When acting on behalf of a delegator no withdraws are allowed
            require(msg.sender == _from, "Unauthorized");

            // Unstake the corresponding sProps from the user Props staking contract
            IStaking(propsUserStaking).withdraw(_to, totalUnstakedAmount);

            if (_rewards) {
                rewardsEscrow[_to] = rewardsEscrow[_to].add(totalUnstakedAmount);
                rewardsEscrowUnlock[_to] = block.timestamp.add(rewardsEscrowCooldown);

                emit RewardsEscrowUpdated(_to, rewardsEscrow[_to], rewardsEscrowUnlock[_to]);
            } else {
                // Transfer any left Props back to the user
                IERC20Upgradeable(propsToken).safeTransfer(_to, totalUnstakedAmount);
            }

            // Burn the sProps
            ISPropsToken(sPropsToken).burn(_to, totalUnstakedAmount);
        }
    }

    function _claimUserPropsRewardsAndStake(
        address[] memory _apps,
        uint256[] memory _percentages,
        address _account
    ) internal {
        uint256 reward = IStaking(propsUserStaking).earned(_account);
        if (reward > 0) {
            // Claim the rewards but don't transfer them to the user's wallet
            IStaking(propsUserStaking).claimReward(_account);
            // Since the rewards are in rProps, swap it for regular Props
            IRPropsToken(rPropsToken).swap(address(this));

            // Place the rewards in the escrow but don't extend the cooldown period
            rewardsEscrow[_account] = rewardsEscrow[_account].add(reward);

            // Calculate amounts from the given percentages
            uint256 totalPercentage = 0;
            uint256 totalAmountSoFar = 0;
            int256[] memory amounts = new int256[](_percentages.length);
            for (uint256 i = 0; i < _percentages.length; i++) {
                if (i < _percentages.length.sub(1)) {
                    amounts[i] = _safeInt256(reward.mul(_percentages[i]).div(1e6));
                } else {
                    // Make sure nothing gets lost
                    amounts[i] = _safeInt256(reward.sub(totalAmountSoFar));
                }

                totalPercentage = totalPercentage.add(_percentages[i]);
                totalAmountSoFar = totalAmountSoFar.add(uint256(amounts[i]));
            }
            // The given percentages must add up to 100%
            require(totalPercentage == 1e6, "Invalid percentages");

            if (_account == msg.sender) {
                stakeRewards(_apps, amounts);
            } else {
                stakeRewardsAsDelegate(_apps, amounts, _account);
            }
        }
    }

    function _safeInt256(uint256 a) internal pure returns (int256) {
        require(a <= 2**255 - 1, "Overflow");
        return int256(a);
    }
}
