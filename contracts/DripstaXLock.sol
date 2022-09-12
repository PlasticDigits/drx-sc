// SPDX-License-Identifier: GPL-3.0
// Authored by Plastic Digits 
pragma solidity ^0.8.4;
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "./DripstaX.sol";
import "./AutoRewardPool.sol";

contract DripstaXLock is 
    AccessControlEnumerable
{
    using SafeERC20 for IERC20;
    struct Boost {
        uint64 period;
        uint64 boostBps;
    }

    uint256 public periodSinceFirstBuyToLock = 7 days;

    Boost[] public boostOptions;
    mapping(address=>uint64) public withdrawInitiationEpoch;
    mapping(address=>uint64) public selectedBoost;
    mapping(address=>uint256) public drxLocked;
    mapping(address=>uint256) public boostedDepositWad;


    AutoRewardPool public drxRewardPool;
    DripstaX public drx;

    event Admin_AddBoostOption(uint64 period, uint64 boostBps);

    event SelectedBoost(address account, uint64 boostIndex);
    event CancelWithdrawRequest(address account);
    event InitiateWithdrawRequest(address account, uint64 initiationEpoch);
    event Lock(address account, uint256 drxWad);
    event LockUpdatedTo(address account, uint256 drxWad, uint256 boostedDepositWad);
    event Withdraw(address account);

    constructor(AutoRewardPool _drxRewardPool, DripstaX _drx) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        drxRewardPool = _drxRewardPool;
        drx = _drx;
    }

    //For first time locks to remove need for multiple tx.
    function selectBoostAndLock(uint256 _wad, uint64 _boostIndex) external {
        selectBoost(_boostIndex);
        lock(_wad);
    }

    //Locks DRX. Transfers DRX to this contract from sender. Cancels withdraw request if one is active.
    //Defaults to boost 0 if a boost has not been selected.
    //Approve this contract for DRX tranfsers before calling.
    function lock(uint256 _wad) public {
        require(_wad>0,"DrxLock: Must lock more than 0");

        if(withdrawInitiationEpoch[msg.sender]!=0) {
            cancelWithdrawRequest();
        }

        drx.transferFrom(msg.sender,address(this),_wad);
        drxLocked[msg.sender] += _wad;

        emit Lock(msg.sender,_wad);
        _updateBoostedLockWad();
    
    }

    function initiateWithdrawRequest() public {
        require(withdrawInitiationEpoch[msg.sender]==0, "DrxLock: Withdraw request already initiated");
        require(drxLocked[msg.sender] >0, "DrxLock: No drx locked");
        drxRewardPool.withdrawViaLock(msg.sender,boostedDepositWad[msg.sender]);
        boostedDepositWad[msg.sender] = 0;
        withdrawInitiationEpoch[msg.sender] = uint64(block.timestamp);
        emit InitiateWithdrawRequest(msg.sender, uint64(block.timestamp));
        emit LockUpdatedTo(msg.sender, drxLocked[msg.sender], 0);
    }

    //Withdraws all
    //Must initiate withdraw first and wait for selected boost period
    function withdraw() public {
        require(withdrawInitiationEpoch[msg.sender]>0,"DrxLock: Must initiate withdraw first");
        require(withdrawInitiationEpoch[msg.sender]>=block.timestamp+boostOptions[selectedBoost[msg.sender]].period,"DrxLock: Must wait for boost period to pass");
        drx.transfer(msg.sender,drxLocked[msg.sender]);
        drxLocked[msg.sender] = 0;
        withdrawInitiationEpoch[msg.sender] = 0;
        emit Withdraw(msg.sender);
        emit LockUpdatedTo(msg.sender, 0, 0);
    }

    //Seletcs the account's boost and relocks with new boost if already locked. 
    //To lower the boost level, must have no drx locked.
    function selectBoost(uint64 _boostIndex) public {
        require(drx.firstBuyEpoch(msg.sender)>=block.timestamp+periodSinceFirstBuyToLock,"DrxLock: Must wait for frist buy lock period");
        require(_boostIndex >= selectedBoost[msg.sender] || drxLocked[msg.sender]==0, "DrxLock: Cannot select boost lower than current boost unless no lock");
        require(withdrawInitiationEpoch[msg.sender]==0,"DrxLock: Cannot select boost when withdraw request active");

        selectedBoost[msg.sender] = _boostIndex;
        emit SelectedBoost(msg.sender,_boostIndex);


        if(drxLocked[msg.sender] != 0) {
            _updateBoostedLockWad();
        }

        if(withdrawInitiationEpoch[msg.sender]!=0) {
            cancelWithdrawRequest();
        }
    }


    function cancelWithdrawRequest() public {
        require(withdrawInitiationEpoch[msg.sender]!=0,"DrxLock: No withdraw request to cancel");
        withdrawInitiationEpoch[msg.sender] = 0;

        _updateBoostedLockWad();

        emit CancelWithdrawRequest(msg.sender);
    }

    //Updates the boosted wad, do not run if withdraw initiatied.
    function _updateBoostedLockWad() internal {
        drxRewardPool.withdrawViaLock(msg.sender,boostedDepositWad[msg.sender]);
        uint256 newBoostedDepositWad = drxLocked[msg.sender] * boostOptions[selectedBoost[msg.sender]].boostBps / 10000;
        drxRewardPool.depositViaLock(msg.sender,newBoostedDepositWad);
        boostedDepositWad[msg.sender] = newBoostedDepositWad;
        emit LockUpdatedTo(msg.sender,drxLocked[msg.sender],newBoostedDepositWad);
    }

    function ADMIN_addBoostOption(uint64 _period, uint64 _boostBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        boostOptions.push(Boost(_period,_boostBps));
        emit Admin_AddBoostOption(_period, _boostBps);
    }

}