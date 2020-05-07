pragma solidity ^0.5.0;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";

/**
 * @title Props Rewards Library
 * @dev Library to manage application and validators and parameters
 **/
library PropsRewardsLib {
    using SafeMath for uint256;
    /*
    *  Events
    */

    /*
    *  Storage
    */

    // The various parameters used by the contract
    enum ParameterName {
        ApplicationRewardsPercent,
        ApplicationRewardsMaxVariationPercent,
        ValidatorMajorityPercent,
        ValidatorRewardsPercent,
        StakingInterestRate,
        UnstakingCooldownPeriodDays
    }
    enum RewardedEntityType { Application, Validator }

    // Represents a parameter current, previous and time of change
    struct Parameter {
        uint256 currentValue;                   // current value in Pphm valid after timestamp
        uint256 previousValue;                  // previous value in Pphm for use before timestamp
        uint256 rewardsDay;                     // timestamp of when the value was updated
    }
    // Represents application details
    struct RewardedEntity {
        bytes32 name;                           // Application name
        address rewardsAddress;                 // address where rewards will be minted to
        address sidechainAddress;               // address used on the sidechain
        bool isInitializedState;                // A way to check if there's something in the map and whether it is already added to the list
        RewardedEntityType entityType;          // Type of rewarded entity
    }

    // Represents validators current and previous lists
    struct RewardedEntityList {
        mapping (address => bool) current;
        mapping (address => bool) previous;
        address[] currentList;
        address[] previousList;
        uint256 rewardsDay;
    }

    // Represents daily rewards submissions and confirmations
    struct DailyRewards {
        mapping (bytes32 => Submission) submissions;
        bytes32[] submittedRewardsHashes;
        uint256 totalSupply;
        bytes32 lastConfirmedRewardsHash;
        uint256 lastApplicationsRewardsDay;
    }

    struct Submission {
        mapping (address => bool) validators;
        address[] validatorsList;
        uint256 confirmations;
        uint256 finalizedStatus;               // 0 - initialized, 1 - finalized
        bool isInitializedState;               // A way to check if there's something in the map and whether it is already added to the list
    }


    // represent the storage structures
    struct Data {
        // applications data
        mapping (address => RewardedEntity) applications;
        address[] applicationsList;
        // validators data
        mapping (address => RewardedEntity) validators;
        address[] validatorsList;
        // adjustable parameters data
        mapping (uint256 => Parameter) parameters; // uint256 is the parameter enum index
        // the participating validators
        RewardedEntityList selectedValidators;
        // the participating applications
        RewardedEntityList selectedApplications;
        // daily rewards submission data
        DailyRewards dailyRewards;
        uint256 minSecondsBetweenDays;
        uint256 rewardsStartTimestamp;
        uint256 maxTotalSupply;
        uint256 lastValidatorsRewardsDay;
    }
    /*
    *  Modifiers
    */
    modifier onlyOneConfirmationPerValidatorPerRewardsHash(Data storage _self, bytes32 _rewardsHash) {
        require(
            !_self.dailyRewards.submissions[_rewardsHash].validators[msg.sender],
            "Must be one submission per validator"
        );
         _;
    }

    modifier onlyExistingApplications(Data storage _self, address[] memory _entities) {
        for (uint256 i = 0; i < _entities.length; i++) {
            require(
                _self.applications[_entities[i]].isInitializedState,
                "Application must exist"
            );
        }
        _;
    }

    modifier onlyExistingValidators(Data storage _self, address[] memory _entities) {
        for (uint256 i = 0; i < _entities.length; i++) {
            require(
                _self.validators[_entities[i]].isInitializedState,
                "Validator must exist"
            );
        }
        _;
    }

    modifier onlySelectedValidators(Data storage _self, uint256 _rewardsDay) {
        if (!_usePreviousSelectedRewardsEntityList(_self.selectedValidators, _rewardsDay)) {
            require (
                _self.selectedValidators.current[msg.sender],
                "Must be a current selected validator"
            );
        } else {
            require (
                _self.selectedValidators.previous[msg.sender],
                "Must be a previous selected validator"
            );
        }
        _;
    }

    modifier onlyValidRewardsDay(Data storage _self, uint256 _rewardsDay) {
        require(
            _currentRewardsDay(_self) > _rewardsDay && _rewardsDay > _self.lastValidatorsRewardsDay,
            "Must be for a previous day but after the last rewards day"
        );
         _;
    }

    modifier onlyValidFutureRewardsDay(Data storage _self, uint256 _rewardsDay) {
        require(
            _rewardsDay >= _currentRewardsDay(_self),
            "Must be future rewardsDay"
        );
         _;
    }

    modifier onlyValidAddresses(address _rewardsAddress, address _sidechainAddress) {
        require(
            _rewardsAddress != address(0) &&
            _sidechainAddress != address(0),
            "Must have valid rewards and sidechain addresses"
        );
        _;
    }

    /**
    * @dev The function is called by validators with the calculation of the daily rewards
    * @param _self Data pointer to storage
    * @param _rewardsDay uint256 the rewards day
    * @param _rewardsHash bytes32 hash of the rewards data
    * @param _allValidators bool should the calculation be based on all the validators or just those which submitted
    */
    function calculateValidatorRewards(
        Data storage _self,
        uint256 _rewardsDay,
        bytes32 _rewardsHash,
        bool _allValidators
    )
        public
        view
        returns (uint256)
    {
        uint256 numOfValidators;
        if (_self.dailyRewards.submissions[_rewardsHash].finalizedStatus == 1)
        {
            if (_allValidators) {
                numOfValidators = _requiredValidatorsForValidatorsRewards(_self, _rewardsDay);
                if (numOfValidators > _self.dailyRewards.submissions[_rewardsHash].confirmations) return 0;
            } else {
                numOfValidators = _self.dailyRewards.submissions[_rewardsHash].confirmations;
            }
            uint256 rewardsPerValidator = _getValidatorRewardsDailyAmountPerValidator(_self, _rewardsDay, numOfValidators);
            return rewardsPerValidator;
        }
        return 0;
    }

    /**
    * @dev The function is called by validators with the calculation of the daily rewards
    * @param _self Data pointer to storage
    * @param _rewardsDay uint256 the rewards day
    * @param _rewardsHash bytes32 hash of the rewards data
    * @param _applications address[] array of application addresses getting the daily reward
    * @param _amounts uint256[] array of amounts each app should get
    * @param _currentTotalSupply uint256 current total supply
    */
    function calculateAndFinalizeApplicationRewards(
        Data storage _self,
        uint256 _rewardsDay,
        bytes32 _rewardsHash,
        address[] memory _applications,
        uint256[] memory _amounts,
        uint256 _currentTotalSupply
    )
        public
        onlyValidRewardsDay(_self, _rewardsDay)
        onlyOneConfirmationPerValidatorPerRewardsHash(_self, _rewardsHash)
        onlySelectedValidators(_self, _rewardsDay)
        returns (uint256)
    {
        require(
                _rewardsHashIsValid(_self, _rewardsDay, _rewardsHash, _applications, _amounts),
                "Rewards Hash is invalid"
        );
        if (!_self.dailyRewards.submissions[_rewardsHash].isInitializedState) {
            _self.dailyRewards.submissions[_rewardsHash].isInitializedState = true;
            _self.dailyRewards.submittedRewardsHashes.push(_rewardsHash);
        }
        _self.dailyRewards.submissions[_rewardsHash].validators[msg.sender] = true;
        _self.dailyRewards.submissions[_rewardsHash].validatorsList.push(msg.sender);
        _self.dailyRewards.submissions[_rewardsHash].confirmations++;

        if (_self.dailyRewards.submissions[_rewardsHash].confirmations == _requiredValidatorsForAppRewards(_self, _rewardsDay)) {
            uint256 sum = _validateSubmittedData(_self, _applications, _amounts);
            require(
                sum <= _getMaxAppRewardsDailyAmount(_self, _rewardsDay, _currentTotalSupply),
                "Rewards data is invalid - exceed daily variation"
            );
            _finalizeDailyApplicationRewards(_self, _rewardsDay, _rewardsHash, _currentTotalSupply);
            return sum;
        }
        return 0;
    }

    /**
    * @dev Finalizes the state, rewards Hash, total supply and block timestamp for the day
    * @param _self Data pointer to storage
    * @param _rewardsDay uint256 the rewards day
    * @param _rewardsHash bytes32 the daily rewards hash
    * @param _currentTotalSupply uint256 the current total supply
    */
    function _finalizeDailyApplicationRewards(Data storage _self, uint256 _rewardsDay, bytes32 _rewardsHash, uint256 _currentTotalSupply)
        public
    {
        _self.dailyRewards.totalSupply = _currentTotalSupply;
        _self.dailyRewards.lastConfirmedRewardsHash = _rewardsHash;
        _self.dailyRewards.lastApplicationsRewardsDay = _rewardsDay;
        _self.dailyRewards.submissions[_rewardsHash].finalizedStatus = 1;
    }

    /**
    * @dev Get parameter's value
    * @param _self Data pointer to storage
    * @param _name ParameterName name of the parameter
    * @param _rewardsDay uint256 the rewards day
    */
    function getParameterValue(
        Data storage _self,
        ParameterName _name,
        uint256 _rewardsDay
    )
        public
        view
        returns (uint256)
    {
        if (_rewardsDay >= _self.parameters[uint256(_name)].rewardsDay) {
            return _self.parameters[uint256(_name)].currentValue;
        } else {
            return _self.parameters[uint256(_name)].previousValue;
        }
    }

    /**
    * @dev Allows the controller/owner to update rewards parameters
    * @param _self Data pointer to storage
    * @param _name ParameterName name of the parameter
    * @param _value uint256 new value for the parameter
    * @param _rewardsDay uint256 the rewards day
    */
    function updateParameter(
        Data storage _self,
        ParameterName _name,
        uint256 _value,
        uint256 _rewardsDay
    )
        public
        onlyValidFutureRewardsDay(_self, _rewardsDay)
    {
        if (_rewardsDay <= _self.parameters[uint256(_name)].rewardsDay) {
           _self.parameters[uint256(_name)].currentValue = _value;
           _self.parameters[uint256(_name)].rewardsDay = _rewardsDay;
        } else {
            _self.parameters[uint256(_name)].previousValue = _self.parameters[uint256(_name)].currentValue;
            _self.parameters[uint256(_name)].currentValue = _value;
           _self.parameters[uint256(_name)].rewardsDay = _rewardsDay;
        }
    }

    /**
    * @dev Allows an application to add/update its details
    * @param _self Data pointer to storage
    * @param _entityType RewardedEntityType either application (0) or validator (1)
    * @param _name bytes32 name of the app
    * @param _rewardsAddress address an address for the app to receive the rewards
    * @param _sidechainAddress address the address used for using the sidechain
    */
    function updateEntity(
        Data storage _self,
        RewardedEntityType _entityType,
        bytes32 _name,
        address _rewardsAddress,
        address _sidechainAddress
    )
        public
        onlyValidAddresses(_rewardsAddress, _sidechainAddress)
    {
        if (_entityType == RewardedEntityType.Application) {
            updateApplication(_self, _name, _rewardsAddress, _sidechainAddress);
        } else {
            updateValidator(_self, _name, _rewardsAddress, _sidechainAddress);
        }
    }

    /**
    * @dev Allows an application to add/update its details
    * @param _self Data pointer to storage
    * @param _name bytes32 name of the app
    * @param _rewardsAddress address an address for the app to receive the rewards
    * @param _sidechainAddress address the address used for using the sidechain
    */
    function updateApplication(
        Data storage _self,
        bytes32 _name,
        address _rewardsAddress,
        address _sidechainAddress
    )
        public
        returns (uint256)
    {
        _self.applications[msg.sender].name = _name;
        _self.applications[msg.sender].rewardsAddress = _rewardsAddress;
        _self.applications[msg.sender].sidechainAddress = _sidechainAddress;
        if (!_self.applications[msg.sender].isInitializedState) {
            _self.applicationsList.push(msg.sender);
            _self.applications[msg.sender].isInitializedState = true;
            _self.applications[msg.sender].entityType = RewardedEntityType.Application;
        }
        return uint256(RewardedEntityType.Application);
    }

    /**
    * @dev Allows a validator to add/update its details
    * @param _self Data pointer to storage
    * @param _name bytes32 name of the validator
    * @param _rewardsAddress address an address for the validator to receive the rewards
    * @param _sidechainAddress address the address used for using the sidechain
    */
    function updateValidator(
        Data storage _self,
        bytes32 _name,
        address _rewardsAddress,
        address _sidechainAddress
    )
        public
        returns (uint256)
    {
        _self.validators[msg.sender].name = _name;
        _self.validators[msg.sender].rewardsAddress = _rewardsAddress;
        _self.validators[msg.sender].sidechainAddress = _sidechainAddress;
        if (!_self.validators[msg.sender].isInitializedState) {
            _self.validatorsList.push(msg.sender);
            _self.validators[msg.sender].isInitializedState = true;
            _self.validators[msg.sender].entityType = RewardedEntityType.Validator;
        }
        return uint256(RewardedEntityType.Validator);
    }

    /**
    * @dev Set new validators list
    * @param _self Data pointer to storage
    * @param _rewardsDay uint256 the rewards day from which the list should be active
    * @param _validators address[] array of validators
    */
    function setValidators(
        Data storage _self,
        uint256 _rewardsDay,
        address[] memory _validators
    )
        public
        onlyValidFutureRewardsDay(_self, _rewardsDay)
        onlyExistingValidators(_self, _validators)
    {
        // no need to update the previous if its' the first time or second update in the same day
        if (_rewardsDay > _self.selectedValidators.rewardsDay && _self.selectedValidators.currentList.length > 0)
            _updatePreviousEntityList(_self.selectedValidators);

        _updateCurrentEntityList(_self.selectedValidators, _validators);
        _self.selectedValidators.rewardsDay = _rewardsDay;
    }

   /**
    * @dev Set new applications list
    * @param _self Data pointer to storage
    * @param _rewardsDay uint256 the rewards day from which the list should be active
    * @param _applications address[] array of applications
    */
    function setApplications(
        Data storage _self,
        uint256 _rewardsDay,
        address[] memory _applications
    )
        public
        onlyValidFutureRewardsDay(_self, _rewardsDay)
        onlyExistingApplications(_self, _applications)
    {

        if (_rewardsDay > _self.selectedApplications.rewardsDay && _self.selectedApplications.currentList.length > 0)
                _updatePreviousEntityList(_self.selectedApplications);
        _updateCurrentEntityList(_self.selectedApplications, _applications);
        _self.selectedApplications.rewardsDay = _rewardsDay;
    }

    /**
    * @dev Get applications or validators list
    * @param _self Data pointer to storage
    * @param _entityType RewardedEntityType either application (0) or validator (1)
    * @param _rewardsDay uint256 the rewards day to determine which list to get
    */
    function getEntities(
        Data storage _self,
        RewardedEntityType _entityType,
        uint256 _rewardsDay
    )
        public
        view
        returns (address[] memory)
    {
        if (_entityType == RewardedEntityType.Application) {
            if (!_usePreviousSelectedRewardsEntityList(_self.selectedApplications, _rewardsDay)) {
                return _self.selectedApplications.currentList;
            } else {
                return _self.selectedApplications.previousList;
            }
        } else {
            if (!_usePreviousSelectedRewardsEntityList(_self.selectedValidators, _rewardsDay)) {
                return _self.selectedValidators.currentList;
            } else {
                return _self.selectedValidators.previousList;
            }
        }
    }

    /**
    * @dev Get which entity list to use. If true use previous if false use current
    * @param _rewardedEntitylist RewardedEntityList pointer to storage
    * @param _rewardsDay uint256 the rewards day to determine which list to get
    */
    function _usePreviousSelectedRewardsEntityList(RewardedEntityList memory _rewardedEntitylist, uint256 _rewardsDay)
        internal
        pure
        returns (bool)
    {
        if (_rewardsDay >= _rewardedEntitylist.rewardsDay) {
            return false;
        } else {
            return true;
        }
    }

    /**
    * @dev Checks how many validators are needed for app rewards
    * @param _self Data pointer to storage
    * @param _rewardsDay uint256 the rewards day
    * @param _currentTotalSupply uint256 current total supply
    */
    function _getMaxAppRewardsDailyAmount(
        Data storage _self,
        uint256 _rewardsDay,
        uint256 _currentTotalSupply
    )
        public
        view
        returns (uint256)
    {
        return ((_self.maxTotalSupply.sub(_currentTotalSupply)).mul(
        getParameterValue(_self, ParameterName.ApplicationRewardsPercent, _rewardsDay)).mul(
        getParameterValue(_self, ParameterName.ApplicationRewardsMaxVariationPercent, _rewardsDay))).div(1e16);
    }


    /**
    * @dev Checks how many validators are needed for app rewards
    * @param _self Data pointer to storage
    * @param _rewardsDay uint256 the rewards day
    * @param _numOfValidators uint256 number of validators
    */
    function _getValidatorRewardsDailyAmountPerValidator(
        Data storage _self,
        uint256 _rewardsDay,
        uint256 _numOfValidators
    )
        public
        view
        returns (uint256)
    {
        return (((_self.maxTotalSupply.sub(_self.dailyRewards.totalSupply)).mul(
        getParameterValue(_self, ParameterName.ValidatorRewardsPercent, _rewardsDay))).div(1e8)).div(_numOfValidators);
    }

    /**
    * @dev Checks if app daily rewards amount is valid
    * @param _self Data pointer to storage
    * @param _applications address[] array of application addresses getting the daily rewards
    * @param _amounts uint256[] array of amounts each app should get
    */
    function _validateSubmittedData(
        Data storage _self,
        address[] memory _applications,
        uint256[] memory _amounts
    )
        public
        view
        returns (uint256)
    {
        uint256 sum;
        bool valid = true;
        for (uint256 i = 0; i < _amounts.length; i++) {
            sum = sum.add(_amounts[i]);
            if (!_self.applications[_applications[i]].isInitializedState) valid = false;
        }
        require(
                sum > 0 && valid,
                "Sum zero or none existing app submitted"
        );
        return sum;
    }

    /**
    * @dev Checks if submitted data matches rewards hash
    * @param _rewardsDay uint256 the rewards day
    * @param _rewardsHash bytes32 hash of the rewards data
    * @param _applications address[] array of application addresses getting the daily rewards
    * @param _amounts uint256[] array of amounts each app should get
    */
    function _rewardsHashIsValid(
        Data storage _self,
        uint256 _rewardsDay,
        bytes32 _rewardsHash,
        address[] memory _applications,
        uint256[] memory _amounts
    )
        public
        view
        returns (bool)
    {
        bool nonActiveApplication = false;
        if (!_usePreviousSelectedRewardsEntityList(_self.selectedApplications, _rewardsDay)) {
            for (uint256 i = 0; i < _applications.length; i++) {
                if (!_self.selectedApplications.current[_applications[i]]) {
                    nonActiveApplication = true;
                }
            }
        } else {
            for (uint256 j = 0; j < _applications.length; j++) {
                if (!_self.selectedApplications.previous[_applications[j]]) {
                    nonActiveApplication = true;
                }
            }
        }
        return
            _applications.length > 0 &&
            _applications.length == _amounts.length &&
            !nonActiveApplication &&
            keccak256(abi.encodePacked(_rewardsDay, _applications.length, _amounts.length, _applications, _amounts)) == _rewardsHash;
    }

    /**
    * @dev Checks how many validators are needed for app rewards
    * @param _self Data pointer to storage
    * @param _rewardsDay uint256 the rewards day
    */
    function _requiredValidatorsForValidatorsRewards(Data storage _self, uint256 _rewardsDay)
        public
        view
        returns (uint256)
    {
        if (!_usePreviousSelectedRewardsEntityList(_self.selectedValidators, _rewardsDay)) {
            return _self.selectedValidators.currentList.length;
        } else {
            return _self.selectedValidators.previousList.length;
        }
    }

    /**
    * @dev Checks how many validators are needed for app rewards
    * @param _self Data pointer to storage
    * @param _rewardsDay uint256 the rewards day
    */
    function _requiredValidatorsForAppRewards(Data storage _self, uint256 _rewardsDay)
        public
        view
        returns (uint256)
    {
        if (!_usePreviousSelectedRewardsEntityList(_self.selectedValidators, _rewardsDay)) {
            return ((_self.selectedValidators.currentList.length.mul(getParameterValue(_self, ParameterName.ValidatorMajorityPercent, _rewardsDay))).div(1e8)).add(1);
        } else {
            return ((_self.selectedValidators.previousList.length.mul(getParameterValue(_self, ParameterName.ValidatorMajorityPercent, _rewardsDay))).div(1e8)).add(1);
        }
    }

    /**
    * @dev Get rewards day from block.timestamp
    * @param _self Data pointer to storage
    */
    function _currentRewardsDay(Data storage _self)
        public
        view
        returns (uint256)
    {
        //the the start time - floor timestamp to previous midnight divided by seconds in a day will give the rewards day number
       if (_self.minSecondsBetweenDays > 0) {
            return (block.timestamp.sub(_self.rewardsStartTimestamp)).div(_self.minSecondsBetweenDays).add(1);
        } else {
            return 0;
        }
    }

    /**
    * @dev Update current daily applications list.
    * If new, push.
    * If same size, replace
    * If different size, delete, and then push.
    * @param _rewardedEntitylist RewardedEntityList pointer to storage
    * @param _entities address[] array of entities
    */
    //_updateCurrentEntityList(_rewardedEntitylist, _entities,_rewardedEntityType),
    function _updateCurrentEntityList(
        RewardedEntityList storage _rewardedEntitylist,
        address[] memory _entities
    )
        internal
    {
        bool emptyCurrentList = _rewardedEntitylist.currentList.length == 0;
        if (!emptyCurrentList && _rewardedEntitylist.currentList.length != _entities.length) {
            _deleteCurrentEntityList(_rewardedEntitylist);
            emptyCurrentList = true;
        }

        for (uint256 i = 0; i < _entities.length; i++) {
            if (emptyCurrentList) {
                _rewardedEntitylist.currentList.push(_entities[i]);
            } else {
                _rewardedEntitylist.currentList[i] = _entities[i];
            }
            _rewardedEntitylist.current[_entities[i]] = true;
        }
    }

    /**
    * @dev Update previous daily list
    * @param _rewardedEntitylist RewardedEntityList pointer to storage
    */
    function _updatePreviousEntityList(RewardedEntityList storage _rewardedEntitylist)
        internal
    {
        bool emptyPreviousList = _rewardedEntitylist.previousList.length == 0;
        if (
            !emptyPreviousList &&
            _rewardedEntitylist.previousList.length != _rewardedEntitylist.currentList.length
        ) {
            _deletePreviousEntityList(_rewardedEntitylist);
            emptyPreviousList = true;
        }
        for (uint256 i = 0; i < _rewardedEntitylist.currentList.length; i++) {
            if (emptyPreviousList) {
                _rewardedEntitylist.previousList.push(_rewardedEntitylist.currentList[i]);
            } else {
                _rewardedEntitylist.previousList[i] = _rewardedEntitylist.currentList[i];
            }
            _rewardedEntitylist.previous[_rewardedEntitylist.currentList[i]] = true;
        }
    }

    /**
    * @dev Delete existing values from the current list
    * @param _rewardedEntitylist RewardedEntityList pointer to storage
    */
    function _deleteCurrentEntityList(RewardedEntityList storage _rewardedEntitylist)
        internal
    {
        for (uint256 i = 0; i < _rewardedEntitylist.currentList.length ; i++) {
             delete _rewardedEntitylist.current[_rewardedEntitylist.currentList[i]];
        }
        delete  _rewardedEntitylist.currentList;
    }

    /**
    * @dev Delete existing values from the previous applications list
    * @param _rewardedEntitylist RewardedEntityList pointer to storage
    */
    function _deletePreviousEntityList(RewardedEntityList storage _rewardedEntitylist)
        internal
    {
        for (uint256 i = 0; i < _rewardedEntitylist.previousList.length ; i++) {
            delete _rewardedEntitylist.previous[_rewardedEntitylist.previousList[i]];
        }
        delete _rewardedEntitylist.previousList;
    }

    /**
    * @dev Deletes rewards day submission data
    * @param _self Data pointer to storage
    * @param _rewardsHash bytes32 rewardsHash
    */
    function _resetDailyRewards(
        Data storage _self,
        bytes32 _rewardsHash
    )
        public
    {
         _self.lastValidatorsRewardsDay = _self.dailyRewards.lastApplicationsRewardsDay;
        for (uint256 j = 0; j < _self.dailyRewards.submissions[_rewardsHash].validatorsList.length; j++) {
            delete(
                _self.dailyRewards.submissions[_rewardsHash].validators[_self.dailyRewards.submissions[_rewardsHash].validatorsList[j]]
            );
        }
            delete _self.dailyRewards.submissions[_rewardsHash].validatorsList;
            _self.dailyRewards.submissions[_rewardsHash].confirmations = 0;
            _self.dailyRewards.submissions[_rewardsHash].finalizedStatus = 0;
            _self.dailyRewards.submissions[_rewardsHash].isInitializedState = false;
    }
}