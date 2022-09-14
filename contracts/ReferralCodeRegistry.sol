// SPDX-License-Identifier: GPL-3.0
// Authored by Plastic Digits
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


contract ReferralCodeRegistry {
    using SafeERC20 for IERC20;

    mapping(string => address) public codeToAccount;
    mapping(address => string) public accountToCode;

    mapping(address => uint256) public busdClaimable;

    event RewardsAdded(address account, uint256 wad);
    event RewardsClaimed(address account, uint256 wad);
    event CodeRegistered(address account, string code);
    event CodeUnregistered(address account, string code);

    IERC20 public constant BUSD =
        IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);

    function isValidNewCode(string calldata _code) public view returns (bool) {
        return !isCodeRegistered(_code) && keccak256(abi.encodePacked('')) == keccak256(abi.encodePacked(_code));
    }

    function isCodeRegistered(string calldata _code)
        public
        view
        returns (bool)
    {
        return codeToAccount[_code] != address(0);
    }

    function unregister() public {
        string storage code = accountToCode[msg.sender];
        delete codeToAccount[code];
        delete accountToCode[msg.sender];
        emit CodeUnregistered(msg.sender, code);
    }

    function register(string calldata _code) public {
        require(isValidNewCode(_code), "RCR: Not valid new code");
        unregister();
        codeToAccount[_code] = msg.sender;
        accountToCode[msg.sender] = _code;
        emit CodeRegistered(msg.sender, _code);
    }

    function addRewardsViaCode(string calldata _code, uint256 _wad) external {
        require(isCodeRegistered(_code), "RCR: Code not registered");
        BUSD.transferFrom(msg.sender,address(this),_wad);
        busdClaimable[codeToAccount[_code]] += _wad;
        emit RewardsAdded(codeToAccount[_code],_wad);
    }

    function addRewardsViaAccount(address _account, uint256 _wad) external {
        BUSD.transferFrom(msg.sender,address(this),_wad);
        busdClaimable[_account] += _wad;
        emit RewardsAdded(_account,_wad);
    }

    function claimRewards() external {
        uint256 wad = busdClaimable[msg.sender];
        delete busdClaimable[msg.sender];
        BUSD.transfer(msg.sender,wad);
        emit RewardsClaimed(msg.sender,wad);
    }
}
