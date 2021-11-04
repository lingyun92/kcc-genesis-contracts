// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.8.0;

import "./interfaces/IValidators.sol";
import "./interfaces/IPunish.sol";

contract Params {
    bool public initialized;

    // System contracts
    IValidators public constant validatorsContract = IValidators(0x000000000000000000000000000000000000F333);
    IPunish public constant punishContract = IPunish(0x000000000000000000000000000000000000F444);

    // System params
    uint16 public constant MaxValidators = 29;

    uint public constant PosMinMargin = 1000 ether; // 1000kcs
    uint public constant PoaMinMargin = 32 ether; // 32kcs

    uint public constant PunishAmount = 10 ether; // 10kcs

    uint public constant JailPeriod = 86400; // 3 days
    uint public constant MarginLockPeriod = 403200; // 2 weeks
    uint public constant WithdrawLockPeriod = 86400; // 3 days
    uint public constant PercentChangeLockPeriod = 86400; // 3 days
    uint public constant PERCENT_BASE = 100;

    modifier onlyMiner() {
        require(msg.sender == block.coinbase, "Miner only");
        _;
    }

    modifier onlyNotInitialized() {
        require(!initialized, "Already initialized");
        _;
    }

    modifier onlyInitialized() {
        require(initialized, "Not init yet");
        _;
    }

    modifier onlyPunishContract() {
        require(msg.sender == address(punishContract), "Punish contract only");
        _;
    }

    modifier onlyBlockEpoch(uint256 epoch) {
        require(block.number % epoch == 0, "Block epoch only");
        _;
    }

    modifier onlyValidatorsContract() {
        require(msg.sender == address(validatorsContract), "Validators contract only");
        _;
    }

    modifier onlyValidAddress(address _address) {
        require(_address != address(0), "Invalid address");
        _;
    }
}
