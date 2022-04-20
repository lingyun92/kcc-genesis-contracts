// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.8.0;


import "@openzeppelin/contracts-ethereum-package/contracts/Initializable.sol";


contract Admin is Initializable {

    address public admin; 

    // solhint-disable func-name-mixedcase
    function _Admin_Init(address _admin) internal initializer{
        admin = _admin;
    }

    modifier onlyAdmin(){
        require(msg.sender == admin,"must be admin");
        _;
    }

    function changeAdmin(address _admin) public onlyAdmin{
        admin = _admin;
    }

}