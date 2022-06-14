// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/utils/Address.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import {Math} from "@openzeppelin/contracts-ethereum-package/contracts/math/Math.sol";
import {ReentrancyGuardUpgradeSafe} from "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";
import "./Params.sol";
import "./library/SortedList.sol";
import "./library/SafeSend.sol";
import "./interfaces/IReservePool.sol";
import "./Admin.sol";

import "hardhat/console.sol";

contract Validators is
    Params,
    Admin,
    ReentrancyGuardUpgradeSafe,
    IValidators,
    SafeSend
{
    using SafeMath for uint256;
    //using SafeERC20 for IERC20;
    using Address for address;
    using EnumerableSet for EnumerableSet.UintSet;
    using SortedLinkedList for SortedLinkedList.List;
    //
    // CONSTANT
    //
    // apply to calculate fee distribution.
    uint256 public constant FEE_TOTAL_SHARES = 10000;
    uint256 public constant MAX_FEE_SHARES = 3000;
    uint256 public constant VOTE_UNIT = 1e18;

    //
    // EVENTS
    //
    event SetMinSelfBallots(uint256 min);
    event SetMaxPunishmentBallots(uint256 max);
    event SetRevokeLockingDuration(uint256 duration);
    event SetFeeSetLockingDuration(uint256 duration);
    event SetMarginLockingDuration(uint256 duration);

    event NewValidatorAdded(
        address indexed _validator, 
        address indexed _manager,
        uint256 _feeShares,
        bool    _reused
    );

    event PunishValidator(
        address indexed _validator,
        uint256 indexed _blocknum,
        uint256 _amount
    );
    event SetPoolStatus(address indexed validator, bool enabled);
    event SetFeeShares(
        address indexed _validator,
        uint256 _feeShares
    );
    event Vote(address indexed user, address indexed validator, uint256 amount);
    event Revoke(
        address indexed user,
        address indexed validator,
        uint256 amount,
        uint256 lockingEndTime
    );
    event Withdraw(
        address indexed user,
        address indexed validator,
        uint256 amount
    );
    event ClaimReward(
        address indexed user,
        address indexed validator,
        uint256 pendingReward
    );
    event ClaimFeeReward(address indexed validator, uint256 amount);
    event RewardTransfer(
        address indexed from,
        address indexed to,
        uint256 amount
    );
    event DepositMargin(address indexed from, address indexed validator, uint256 amount);
    event RedeemMargin(address indexed from, address indexed validator, uint256 amount);
    event ValidatorClaimReward(
        address indexed validator,
        uint256 pendingReward
    );
    event ReceiveKCS(address from, uint256 _amount);


    // Total Ballots
    uint256 public totalBallot;

    // The duration to wait after revoking ballots and before withdrawing.  
    uint256 public revokeLockingDuration;

    // The duration to wait after the last change of fee.
    uint256 public feeSetLockingDuration;

    // The duration to wait after revoking margins and before withdrawing. 
    uint256 public marginLockingDuration;

    uint256 public maxPunishmentAmount;

    // The minimum margin in ballots that a validator needs to deposit. 
    uint256 public minSelfBallots;

    // The _sortedEnabledValidators contains all the enabled 
    // validators that are in descending order. 
    SortedLinkedList.List private _sortedEnabledValidators;

    uint256 public rewardsLeft;

    mapping(uint256 => mapping(Operation => bool)) public operationsDone;

    mapping(address => PoolInfo) internal poolInfos;
    mapping(address => Description) public candidateInfos;

    mapping(bytes32 => bool) public usedProposals;

    // Info of each user that votes.
    mapping(address => mapping(address => UserInfo)) public userInfo;

    // Info on each user's revoking ballots
    mapping(address => mapping(address => RevokingInfo)) public revokingInfo;

    // Mapping from the voter's address to 
    // the validators that the voter voted.
    mapping(address => EnumerableSet.AddressSet) private _votingRecordIndexInfo;

    // Mapping from the manager's address to 
    // the validators that the manager controls.
    mapping(address => EnumerableSet.AddressSet) private managedValidatorInfo;

    // The active validators in this epoch 
    address[] public activeValidators;

    // 
    // @params _validators initial validators 
    // @params _managers managers for each initial validator
    // @params _admin the initial admin account (Gnosis Safe or Aragon Agent) 
    // 
    // @audit PVE004 The initialize function can only be called from the node once.
    function initialize(
        address[] calldata _validators,
        address[] calldata _managers,
        uint256[] calldata _feeShares,
        address _admin,
        address _validatorsContract,
        address _punishContract,
        address _proposalContract,
        address _reservePool,
        uint256 _epoch
    ) external initializer {
        require(
            _validators.length == _feeShares.length && _validators.length == _managers.length && _validators.length > 0,
            "invalid validator and it's manager"
        );

        revokeLockingDuration = 3 days;
        marginLockingDuration = 15 days;
        feeSetLockingDuration = 1 days;
        maxPunishmentAmount = 100 ether;
        minSelfBallots =  10000 ;

        require(address(this).balance >= minSelfBallots.mul(_validators.length).mul(VOTE_UNIT), "no enough kcs in validators contract");

        _Admin_Init(_admin);
        _setAddressesAndEpoch(
            _validatorsContract,
            _punishContract,
            _proposalContract,
            _reservePool,
            _epoch
        );
        __ReentrancyGuard_init();


        for (uint256 i = 0; i < _validators.length; ++i) {
            address val = _validators[i];
            uint256 feeShares = _feeShares[i];
            // update PoolInfo
            PoolInfo storage pool = poolInfos[val];
            pool.manager = _managers[i];
            pool.validator = val;
            pool.selfBallots = minSelfBallots;
            pool.feeShares = feeShares;
            pool.pendingFee = 0;
            pool.feeDebt = 0;
            pool.lastRewardBlock = block.number;
            // solhint-disable not-rely-on-times
            pool.feeSettLockingEndTime = block.timestamp.add( 
                feeSetLockingDuration
            ); 
            pool.suppliedBallots = minSelfBallots;
            pool.accRewardPerShare = 0;
            pool.voterNumber = 0;
            pool.electedNumber = 0;
            pool.enabled = true;

            // Update Candidate Info
            Description storage desc = candidateInfos[val];
            desc.details = "";
            desc.email = "";
            desc.website = "";

            _sortedEnabledValidators.improveRanking(poolInfos, val);
            if(activeValidators.length < MAX_VALIDATORS){
                activeValidators.push(val);
            }
            totalBallot = totalBallot.add(pool.suppliedBallots);

            emit NewValidatorAdded(val,_managers[i], feeShares, false);
        }

        for (uint256 i = 0; i < _validators.length; ++i) {
            // @audit PVE001
            EnumerableSet.add(managedValidatorInfo[_managers[i]],_validators[i]);
        }
    }


    function setMinSelfBallots(uint256 _min) external onlyAdmin {
        require(_min != minSelfBallots, "Validators: No change detected.");

        minSelfBallots = _min;
        emit SetMinSelfBallots(_min);
    }

    function setMaxPunishmentAmount(uint256 _max) external onlyAdmin {
        require(_max != maxPunishmentAmount, "Validators: No change detected.");
        maxPunishmentAmount = _max;

        emit SetMaxPunishmentBallots(_max);
    }

    function setRevokeLockingDuration(uint256 _lockingDuration)
        external
        onlyAdmin
    {
        require(
            _lockingDuration != revokeLockingDuration,
            "Validators: No change detected."
        );

        revokeLockingDuration = _lockingDuration;
        emit SetRevokeLockingDuration(_lockingDuration);
    }

    function setFeeSetLockingDuration(uint256 _lockingDuration)
        external
        onlyAdmin
    {
        require(
            _lockingDuration != feeSetLockingDuration,
            "Validators: No change detected."
        );

        feeSetLockingDuration = _lockingDuration;
        emit SetFeeSetLockingDuration(_lockingDuration);
    }

    function setMarginLockingDuration(uint256 _lockingDuration)
        external
        onlyAdmin
    {
        require(
            _lockingDuration != marginLockingDuration,
            "Validators: No change detected."
        );

        marginLockingDuration = _lockingDuration;

        emit SetMarginLockingDuration(_lockingDuration);
    }

    function getValidatorsOfManager(address _manager) external view returns(address[] memory) {
        EnumerableSet.AddressSet storage validators = managedValidatorInfo[_manager];

        uint256 validatorsLength = EnumerableSet.length(validators);
        address[] memory validatorList = new address[](validatorsLength);

        uint256 index = 0;
        for (uint256 i = 0; i < validatorsLength; i++) {
            address val = address(EnumerableSet.at(validators, i));
            validatorList[index] = val;
            index = index.add(1);
        }
        return validatorList;
    }

    //
    // Add/Reuse a validator based on some proposal. 
    //
    // Only the admin or the validator in the proposal can call this function. 
    function addValidator(
        address _validator,
        address _manager,
        bytes32 _proposalID,
        uint256 _feeShares,
        string memory description,
        string memory website,
        string memory email
    ) public payable nonReentrant {

        require( msg.value.mod(VOTE_UNIT) == 0, "msg.value must be an integer multiple of an ether.");

        require(!usedProposals[_proposalID],"proposal cannot be reused");
        usedProposals[_proposalID] = true; 

        require(
            PROPOSAL_CONTRACT.isProposalPassed(_validator, _proposalID),
            "proposal is not passed"
        );

        require(
            msg.sender == admin || msg.sender == _validator,
            "only validator in the proposal or admin can call addValidator"
        );

        require(_validator != address(0), "Validators: ZERO_ADDRESS.");
        require(
            _feeShares <= MAX_FEE_SHARES,
            "Validators: the fee shares should be in the range(0..3000)."
        );
        require(
            poolInfos[_validator].enabled  == false,
            "already have an enabled pool"
        );

        // how many votes does the validator's margin contribute 
        // to the pool 
        uint256 votes = msg.value.div(VOTE_UNIT);

        if (poolInfos[_validator].validator == _validator) {
            // reuse a previous pool 
            PoolInfo storage pool = poolInfos[_validator];

            if (pool.selfBallots >= minSelfBallots) {
                // @audit PVE003 
                // notice: if _manager != pool.manager, 
                //         rewards will be sent to the previous manager of the validator 
                _validatorClaimReward(_validator);
            }

            // @audit PVE001
            EnumerableSet.add(managedValidatorInfo[_manager],_validator);

            pool.selfBallots = pool.selfBallots.add(votes);
            pool.selfBallotsRewardsDebt = pool.accRewardPerShare.mul(pool.selfBallots).div(1e12);
            pool.suppliedBallots = pool.suppliedBallots.add(votes);
            pool.enabled = true;
            pool.manager = _manager;
            candidateInfos[_validator].website = website; 
            candidateInfos[_validator].email = email; 
            candidateInfos[_validator].details = description; 

            emit NewValidatorAdded(_validator, _manager, _feeShares, true);

        } else {
            
            poolInfos[_validator] = PoolInfo({
                validator: _validator,
                manager: _manager,
                selfBallots: votes,
                selfBallotsRewardsDebt: 0,
                feeShares: _feeShares,
                lastRewardBlock: block.number,
                feeSettLockingEndTime: block.timestamp.add(
                    feeSetLockingDuration
                ), // solhint-disable not-rely-on-time
                pendingFee: 0,
                feeDebt: 0,
                suppliedBallots: votes,
                accRewardPerShare: 0,
                voterNumber: 0,
                electedNumber: 0,
                enabled: true 
            });
            candidateInfos[_validator] = Description({
                website: website,
                email: email,
                details: description
            });

            emit NewValidatorAdded(_validator, _manager, _feeShares, false);
        }

        if (poolInfos[_validator].selfBallots >= minSelfBallots) {
            _sortedEnabledValidators.improveRanking(poolInfos, _validator);
        }

        totalBallot = totalBallot.add(votes);

    }

    // Enable/disable the target pool 
    // Only admin can call this function. 
    function setPoolStatus(address _val, bool _enabled) public onlyAdmin {
        _setPoolStatus(_val, _enabled);
    }

    // Update the given validator's commission rate.
    // Only the manager of the pool can call this function. 
    function setFeeSharesOfValidator(uint256 _shares, address _val) public {
        // @audit PVE001-2 : only the manager of the validator can change the fee shares 
        PoolInfo storage pool = poolInfos[_val];
        require(msg.sender == pool.manager, "only manager can change it");
        require(pool.enabled, "pool is not enabled");
        require(pool.validator != address(0), "Pool does not exist");
        require(
            _shares <= MAX_FEE_SHARES,
            "Validators: the fee shares should be in the range(0..3000)."
        );
        require(
            block.timestamp >= pool.feeSettLockingEndTime,
            "Validators: one time of change within 24 hours."
        ); // solhint-disable not-rely-on-time

        require(_shares != pool.feeShares, "Validators: no change detected.");

        // total 10000(1e4) shares, how many shares validator itself occupies.
        pool.feeShares = _shares;
        // 
        pool.feeSettLockingEndTime = block.timestamp.add(feeSetLockingDuration); // solhint-disable not-rely-on-time

        emit SetFeeShares(_val, _shares);

    }

    // Only the miner can call this function to distribute rewards to validators.
    function distributeBlockReward()
        external
        payable
        override
        onlyMiner
        nonReentrant
    {

        require(!operationsDone[block.number][Operation.Distributed],"cannot be called more than once in a single block");

        operationsDone[block.number][Operation.Distributed] = true;

        uint256 rewardsFromReservePool = RESERVEPOOL_CONTRACT.withdrawBlockReward();
        if (rewardsFromReservePool == 0) {
            return;
        }

        uint256 numOfValidatorRewarded = 0;
        // total amount available for distribution:
        //   rewardLeft + rewardsFromReservePool
        uint256 totalAvailable = rewardsLeft.add(rewardsFromReservePool);
        uint256 totalDistributed = 0; // actually distributed 

        if (activeValidators.length > 0) {
            // The total ballots of all active validators 
            uint256 _totalBallot = 0;
            for (uint8 i = 0; i < activeValidators.length; i++) {
                PoolInfo storage pool = poolInfos[activeValidators[i]];

                // Distribute block rewards only to validators that have enough ballots and are enabled
                if (pool.selfBallots >= minSelfBallots && pool.enabled) {
                    _totalBallot = _totalBallot.add(poolInfos[activeValidators[i]].suppliedBallots);
                }
            }

            if (_totalBallot > 0) {
                // roundoff error - 
                uint256 rewardsPerShare = totalAvailable.div(_totalBallot);

                for (uint8 i = 0; i < activeValidators.length; i++) {
                    PoolInfo storage pool = poolInfos[activeValidators[i]];

                    if (pool.selfBallots < minSelfBallots || !pool.enabled) {
                        continue;
                    }

                    uint256 poolRewards = rewardsPerShare.mul(pool.suppliedBallots);

                    // roundoff error -
                    // validator's commission fee 
                    uint256 feeReward = poolRewards.mul(pool.feeShares).div(
                        FEE_TOTAL_SHARES
                    );

                    pool.pendingFee = pool.pendingFee.add(feeReward);

                    // reward to be distributed to staked users
                    uint256 votingReward = poolRewards.sub(feeReward);
 
                    {
                        pool.accRewardPerShare = pool.accRewardPerShare.add(
                            votingReward.mul(1e12).div(pool.suppliedBallots) // roundoff error -
                        );

                    }

                    // roundoff error -
                    totalDistributed = totalDistributed.add(poolRewards); 
                    pool.lastRewardBlock = block.number;
                    pool.electedNumber = pool.electedNumber.add(1);   
                    numOfValidatorRewarded++;                 
                }
            }


        }

        require(
            totalAvailable >= totalDistributed,
            "Validators: totalAvailable is less than totalDistributed"
        );


        //
        rewardsLeft = totalAvailable.sub(totalDistributed);

    }

    function updateActiveValidatorSet(address[] calldata newSet)
        external
        override
        onlyMiner
        onlyBlockEpoch
    {
        operationsDone[block.number][Operation.UpdatedValidators] = true;

        require(newSet.length > 0 && newSet.length <= MAX_VALIDATORS, "invalid length of newSet array");

        activeValidators = newSet; // FIXME: gas cost ?
    }

    function getTopValidators()
        external
        view
        override
        returns (address[] memory)
    {

        uint256 nValidators = Math.min(
            MAX_VALIDATORS,
            _sortedEnabledValidators.length
        );

        if (nValidators == 0) {
            return new address[](0);
        }

        address[] memory topValidators = new address[](nValidators);

        // The first element
        address currVal = _sortedEnabledValidators.head;
        topValidators[0] = currVal;

        // All other elements
        uint256 nextIndex = 1;
        while (nextIndex < nValidators) {
            currVal = _sortedEnabledValidators.next[currVal];
            topValidators[nextIndex] = currVal;
            nextIndex++;
        }

        return topValidators;
    }

    // punish validator
    //  @params validator the address of the validator
    //  @params remove whether remove the validator from the set of active validators
    function punish(address validator, bool remove)
        external
        override
        onlyPunishContract
    {
        // 
        if (remove) {
            _setPoolStatus(validator, false);
        }

        uint256 punishAmount = maxPunishmentAmount;
        PoolInfo storage pool = poolInfos[validator];
        uint256 selfBallotsReward = pool.accRewardPerShare.mul(pool.selfBallots).div(1e12).sub(pool.selfBallotsRewardsDebt);

        uint256 amount = 0;
        if (pool.pendingFee >= punishAmount) {
            // from pendingFee 
            pool.pendingFee = pool.pendingFee.sub(punishAmount);
            pool.feeDebt = pool.feeDebt.add(punishAmount);
            amount = punishAmount;
        } else {
            // from pendingFee + selfBallotsReward 
            uint256 sub = punishAmount.sub(pool.pendingFee);
            amount = amount.add(pool.pendingFee);
            pool.feeDebt = pool.feeDebt.add(pool.pendingFee);
            pool.pendingFee = 0;

            if (selfBallotsReward >= sub) {
                pool.selfBallotsRewardsDebt = pool.selfBallotsRewardsDebt.add(sub);
                amount = amount.add(sub);
            } else {
                pool.selfBallotsRewardsDebt = pool.selfBallotsRewardsDebt.add(selfBallotsReward);
                amount = amount.add(selfBallotsReward);
            }
        }

        _sendValue(payable(address(RESERVEPOOL_CONTRACT)), amount);

        emit PunishValidator(validator, block.number, amount);
    }

    // Deposit ballot - KCS to the target validator for Reward allocation.
    function vote(address _val) public payable nonReentrant {
        PoolInfo storage pool = poolInfos[_val];
        require(pool.selfBallots >= minSelfBallots, "Validators: must require minSelfBallots");

        require(msg.sender != _val, "validator can only vote to himself by depositing margin.");

        uint256 ballotAmount = msg.value.div(VOTE_UNIT);

        // 
        require(
            msg.value > 0 && ballotAmount > 0,
            "Validators: votes must be integer multiple of 1 KCS."
        );

        uint256 ballotValue = ballotAmount.mul(VOTE_UNIT);
        uint256 diff = msg.value.sub(ballotValue);

        _vote(msg.sender, _val, ballotAmount, pool);

        // @audit N1 Remove unsued accessControl 
        if (diff > 0) {
            _safeTransfer(diff, msg.sender);
        }
    }

    // Withdraw vote tokens from target pool.
    function revokeVote(address _val, uint256 _amount) external nonReentrant {
        require(msg.sender!= _val, "validator can only vote to himself by depositing margin.");
        _revokeVote(msg.sender, _val, _amount);
    }

    function withdraw(address _val) external nonReentrant {
        require(msg.sender!= _val, "validator can only vote to himself by depositing margin.");
        require(
            isWithdrawable(msg.sender, _val),
            "Validators: no ballots to withdraw or ballots are still locking."
        );

        _withdraw(msg.sender, _val);
    }

    // claim reward tokens from target pool.
    function claimReward(address _val) external nonReentrant {
        return _claimReward(_val);
    }

    // Claim commission fee of a validator 
    // @param _val the address of the validator 
    function claimFeeReward(address _val) external nonReentrant {
        PoolInfo storage pool = poolInfos[_val];

        require(pool.validator == _val, "no such pool");

        require(
            pool.manager == msg.sender,
            "Validators: only manager of the pool can claim fee rewards"
        );

        require(pool.pendingFee > 0, "Validators: no pending fee reward to claim.");

        uint256 feeReward = pool.pendingFee;
        pool.pendingFee = 0; // reset to 0
        pool.feeDebt = pool.feeDebt.add(feeReward);

        //
        _safeTransfer(feeReward,msg.sender);

        // 
        emit ClaimFeeReward(pool.validator, feeReward);
    }


    // 
    function isPool(address _validator) external view returns (bool) {
        return (poolInfos[_validator].validator != address(0));
    }


    // A user's pending rewards in a pool of a validator.
    function pendingReward(address _val, address _user)
        external
        view
        returns (uint256)
    {
        return _calculatePendingReward(_val, _user);
    }

    // The voting summary of a user
    function getUserVotingSummary(address _user)
        external
        view
        returns (VotingData[] memory votingDataList)
    {
        EnumerableSet.AddressSet storage recordIndexes = _votingRecordIndexInfo[
            _user
        ];

        uint256 recordIndexesLength = EnumerableSet.length(recordIndexes);
        votingDataList = new VotingData[](recordIndexesLength);

        uint256 index = 0;
        for (uint256 i = 0; i < recordIndexesLength; i++) {
            address val = address(EnumerableSet.at(recordIndexes, i));

            PoolInfo memory pool = poolInfos[val];
            UserInfo memory user = userInfo[val][_user];
            RevokingInfo memory revokingInfoItem = revokingInfo[_user][val];

            uint256 pending = _calculatePendingReward(val, _user);
            votingDataList[index] = VotingData({
                validator: pool.validator,
                validatorBallot: pool.suppliedBallots,
                feeShares: pool.feeShares,
                ballot: user.amount,
                pendingReward: pending,
                revokingBallot: revokingInfoItem.amount,
                revokeLockingEndTime: revokingInfoItem.lockingEndTime
            });
            index = index.add(1);
        }
    }


    // 
    function isWithdrawable(address _user, address _val)
        public
        view
        returns (bool)
    {
        RevokingInfo memory revokingInfoItem = revokingInfo[_user][_val];
        return (revokingInfoItem.amount > 0 &&
            block.timestamp >= revokingInfoItem.lockingEndTime); // solhint-disable not-rely-on-time
    }

    function _calculatePendingReward(address _val, address _user)
        internal
        view
        returns (uint256)
    {
        PoolInfo memory pool = poolInfos[_val];
        UserInfo memory user = userInfo[_val][_user];

        return
            user.amount.mul(pool.accRewardPerShare).div(1e12).sub(
                user.rewardDebt
            );
    }

     
    function _vote(
        address _user,
        address _val,
        uint256 _amount,
        PoolInfo storage pool
    ) internal {

        UserInfo storage user = userInfo[_val][_user];

         
        if (user.amount > 0) {
             
            uint256 pending = _calculatePendingReward(_val, _user);
            if (pending > 0) {
                _safeTransfer(pending,msg.sender);
                emit ClaimReward(_user, _val, pending);
            }
        } else {
             
             
            pool.voterNumber = pool.voterNumber.add(1);

            EnumerableSet.AddressSet
                storage recordIndexes = _votingRecordIndexInfo[_user];
            EnumerableSet.add(recordIndexes, _val);
        }
        
        user.amount = user.amount.add(_amount);
        
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
        
        pool.suppliedBallots = pool.suppliedBallots.add(_amount);
         
        totalBallot = totalBallot.add(_amount);

        if(pool.selfBallots >= minSelfBallots && pool.enabled){
            _sortedEnabledValidators.improveRanking(poolInfos, pool.validator);
        }
        // emit event
        emit Vote(_user, _val, _amount);
    }

    function _withdraw(address _user, address _val) internal {
        RevokingInfo storage revokingInfoItem = revokingInfo[_user][_val];
        UserInfo memory user = userInfo[_val][_user];

        uint256 amount = revokingInfoItem.amount;

        
        revokingInfoItem.amount = 0;
        

        _safeTransfer(amount.mul(VOTE_UNIT),msg.sender);

        
        if (user.amount == 0) {
            EnumerableSet.AddressSet
                storage recordIndexes = _votingRecordIndexInfo[_user];
            
            EnumerableSet.remove(recordIndexes, _val);
        }
        emit Withdraw(_user, _val, amount);
    }


    // @param _amount is the number of ballots 
    function _revokeVote(
        address _user,
        address _val,
        uint256 _amount
    ) internal {
        require(
            _amount > 0 ,"the revoking amount must be greater than zero"
        );

        PoolInfo storage pool = poolInfos[_val];
        UserInfo storage user = userInfo[_val][_user];

        uint256 availableAmount = user.amount;
        require(
            availableAmount >= _amount,
            "Validators: no enough ballots to revoke."
        );

        
        uint256 pending = _calculatePendingReward(_val, _user);

        if (pending > 0) {
            _safeTransfer(pending,msg.sender);
            emit ClaimReward(_user, _val, pending);
        }

        
        if (isWithdrawable(_user, _val)) {
            _withdraw(_user, _val);
        }
        
        pool.suppliedBallots = pool.suppliedBallots.sub(_amount);
        
        user.amount = availableAmount.sub(_amount);
        
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
        
        totalBallot = totalBallot.sub(_amount);

        if (user.amount == 0) {
            
            
            pool.voterNumber = pool.voterNumber.sub(1);
        }

        _updateRevokingInfo(_user, _val, _amount,revokeLockingDuration);
        
        _sortedEnabledValidators.lowerRanking(poolInfos, _val);
    }

    function _safeTransfer(uint256 _amount, address to) internal {
        uint256 totalSpendableReward = address(this).balance;
        if (_amount > totalSpendableReward) {
            _sendValue(payable(to),totalSpendableReward);
            emit RewardTransfer(
                address(this),
                to,
                totalSpendableReward
            );
        } else {
            
            _sendValue(payable(to),_amount);
            emit RewardTransfer(address(this), to, _amount);
        }
    }

    receive() external payable {
        emit ReceiveKCS(msg.sender, msg.value);
    }

    function isActiveValidator(address val)
        external
        view
        override
        returns (bool)
    {
        for (uint256 i = 0; i < activeValidators.length; ++i) {
            if (activeValidators[i] == val) {
                return true;
            }
        }
        return false;
    }

    function getActiveValidators()
        external
        view
        override
        returns (address[] memory)
    {
        return activeValidators;
    }

    // @param _val is validator address
    function depositMargin(address _val) external payable nonReentrant {

        require(
            msg.value > 0 && msg.value.mod(VOTE_UNIT) == 0,
            "Validators: votes must be integer multiple of 1 KCS."
        );
        uint256 ballots = msg.value.div(VOTE_UNIT);

        require(msg.sender == poolInfos[_val].manager, "pool does not exist or msg.sender is not the manager of the pool");
        PoolInfo storage pool = poolInfos[_val];

        if (pool.selfBallots > 0) {
            _validatorClaimReward(_val);
        }

        pool.selfBallots = pool.selfBallots.add(ballots);
        pool.selfBallotsRewardsDebt = pool.accRewardPerShare.mul(pool.selfBallots).div(1e12);
        pool.suppliedBallots = pool.suppliedBallots.add(ballots);
        totalBallot = totalBallot.add(ballots);

        if (pool.selfBallots >= minSelfBallots && pool.enabled) {
           _sortedEnabledValidators.improveRanking(poolInfos, _val);
        }

        emit DepositMargin(msg.sender, _val, msg.value);
    }

    
    
    // @param _val validator address
    // @param _amount is an integer of votes
    function redeemMargin(address _val, uint256 _amount) external nonReentrant {
        require(_amount > 0 , "Validators: redeem amount must be greater than 0");
        require(msg.sender == poolInfos[_val].manager, "pool does not exist or msg.sender is not the manager of the pool");

        PoolInfo storage pool = poolInfos[_val];
        require(_amount <= pool.selfBallots, "Validators: invalid amount.");

        _validatorClaimReward(_val);

        
        if (isWithdrawable(_val, _val)) {
            _withdrawMargin(msg.sender); // => redeemMargin
        }


        uint256 ballot = pool.suppliedBallots;
        pool.suppliedBallots = ballot.sub(_amount);
        totalBallot = totalBallot.sub(_amount);
        pool.selfBallots = pool.selfBallots.sub(_amount);
        pool.selfBallotsRewardsDebt = pool.accRewardPerShare.mul(pool.selfBallots).div(1e12);


        if (pool.selfBallots < minSelfBallots) {
            _sortedEnabledValidators.removeRanking(_val);
        } else {
            _sortedEnabledValidators.lowerRanking(poolInfos, _val);
        }

        _updateRevokingInfo(_val, _val, _amount,marginLockingDuration);

        emit RedeemMargin(msg.sender, _val, _amount);
    }

    function _claimReward(address _val) internal {
        UserInfo storage user = userInfo[_val][msg.sender];
        
        uint256 pending = _calculatePendingReward(_val, msg.sender);
        require(pending > 0, "Validators: no pending reward to claim.");

        
        user.rewardDebt = user
            .amount
            .mul(poolInfos[_val].accRewardPerShare)
            .div(1e12);
        _safeTransfer(pending,msg.sender);

        emit ClaimReward(msg.sender, _val, pending);
    }

    function updateCandidateInfo(
        address _validator,
        string memory details,
        string memory website,
        string memory email
    ) external onlyAdmin {
        require(bytes(details).length <= 3000, "description is too long");
        require(bytes(website).length <= 100, "website is too long");
        require(bytes(email).length <= 50, "email is too long");

        Description storage desc = candidateInfos[_validator];

        if (
            bytes(details).length >= 0 &&
            keccak256(bytes(details)) != keccak256(bytes(desc.details))
        ) {
            desc.details = details;
        }
        if (
            bytes(website).length >= 0 &&
            keccak256(bytes(website)) != keccak256(bytes(desc.website))
        ) {
            desc.website = website;
        }
        if (
            bytes(email).length >= 0 &&
            keccak256(bytes(email)) != keccak256(bytes(desc.email))
        ) {
            desc.email = email;
        }

        // @audit N2-2 Remove unused codes 

        return;
    }

    function _calculateValidatorPendingReward(address _val)
        internal
        view
        returns (uint256)
    {
        PoolInfo memory pool = poolInfos[_val];

        return
            // roundoff error - 
            pool.selfBallots.mul(pool.accRewardPerShare).div(1e12).sub(
                pool.selfBallotsRewardsDebt
            );
    }

    function _validatorClaimReward(address _val) internal {
        PoolInfo storage pool = poolInfos[_val];

        // 
        uint256 pending = _calculateValidatorPendingReward(_val); // roundoff error - 
        if (pending > 0) {
            // @audit PVE003 
            _safeTransfer(pending,pool.manager);
        }
        // 
        // roundoff error -
        pool.selfBallotsRewardsDebt = pool.selfBallots.mul(pool.accRewardPerShare).div(1e12);
        emit ValidatorClaimReward(_val, pending);
    }

    function _setPoolStatus(address _val, bool _enabled) internal {
        PoolInfo storage pool = poolInfos[_val];
        if (pool.enabled != _enabled) {
            pool.enabled = _enabled;

            if (!_enabled) {
                _sortedEnabledValidators.removeRanking(_val);
            } else {
                _sortedEnabledValidators.improveRanking(poolInfos, _val);
            }
        }
        emit SetPoolStatus(_val, _enabled);
    }

    function _updateRevokingInfo(address _user, address _val, uint256 _amount, uint256 lockingDuration) internal {
        RevokingInfo storage revokingInfoItem = revokingInfo[_user][_val];
        // 
        revokingInfoItem.amount = revokingInfoItem.amount.add(_amount);
        revokingInfoItem.lockingEndTime = block.timestamp.add(
            lockingDuration
        ); // solhint-disable not-rely-on-time
    
        // emit event
        emit Revoke(
            _user,
            _val,
            revokingInfoItem.amount,
            revokingInfoItem.lockingEndTime
        );
    }

    function withdrawMargin(address _val) external nonReentrant {
        PoolInfo storage pool = poolInfos[_val];
        require(pool.validator == _val, "no such pool");
        require(pool.manager == msg.sender, "operation is only allowed by manager");
        if(isWithdrawable(_val, _val)){
            _withdrawMargin(_val);
        }  
    }

    function _withdrawMargin(address _val) internal {
        RevokingInfo storage revokingInfoItem = revokingInfo[_val][_val];

        uint256 amount = revokingInfoItem.amount;

        revokingInfoItem.amount = 0;

        _safeTransfer(amount.mul(VOTE_UNIT),msg.sender);
    }

    // claim the Ballot Rewards of a validator's SelfBallots 
    // @param _val validator address 
    function claimSelfBallotsReward(address _val) external nonReentrant{
        PoolInfo storage pool = poolInfos[_val];

        require(pool.validator == _val, "no such pool");
        require(msg.sender == pool.manager, "only the pool manager can claim rewards" );

        _validatorClaimReward(_val);
    }


    // pool getters 

    function getPoolSelfBallots(address val) external view returns (uint256) {
        return poolInfos[val].selfBallots;
    }

    function getPoolSelfBallotsRewardsDebt(address val)
        public
        view
        returns (uint256)
    {
        return poolInfos[val].selfBallotsRewardsDebt;
    }

    function getPoolfeeShares(address val) external view returns (uint256) {
        return poolInfos[val].feeShares;
    }

    function getPoolpendingFee(address val) external view returns (uint256) {
        return poolInfos[val].pendingFee;
    }

    function getPoolfeeDebt(address val) external view returns (uint256) {
        return poolInfos[val].feeDebt;
    }

    function getPoollastRewardBlock(address val) external view returns (uint256) {
        return poolInfos[val].lastRewardBlock;
    }

    function getPoolfeeSettLockingEndTime(address val) external view returns (uint256) {
        return poolInfos[val].feeSettLockingEndTime;
    }

    function getPoolsuppliedBallot(address val) external view returns (uint256) {
        return poolInfos[val].suppliedBallots;
    }

    function getPoolaccRewardPerShare(address val) external view returns (uint256) {
        return poolInfos[val].accRewardPerShare;
    }

    function getPoolvoterNumber(address val) external view returns (uint256) {
        return poolInfos[val].voterNumber;
    }

    function getPoolelectedNumber(address val) external view returns (uint256) {
        return poolInfos[val].electedNumber;
    }

    function getPoolenabled(address val) external view override returns (bool) {
        return poolInfos[val].enabled;
    }

    function getPoolManager(address val) external view returns (address) {
        return poolInfos[val].manager;
    }
}
