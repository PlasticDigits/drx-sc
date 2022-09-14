// SPDX-License-Identifier: GPL-3.0
// Authored by Plastic Digits 
pragma solidity ^0.8.4;
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "./ReferralCodeRegistry.sol";
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


    ReferralCodeRegistry public referralCodeRegistry;
    AutoRewardPool public drxRewardPool;
    DripstaX public drx;

    address public projectDev;

    uint256 public referralRewardBps = 500;
    uint256 public burnBps = 500;

    event Admin_AddBoostOption(uint64 period, uint64 boostBps);

    event SelectedBoost(address account, uint64 boostIndex);
    event CancelWithdrawRequest(address account);
    event InitiateWithdrawRequest(address account, uint64 initiationEpoch);
    event Lock(address account, address referrer, uint256 drxLocked, uint256 drxBurned, uint256 drxReferred);
    event UpdateBoostedLockWad(address account, uint256 drxWad, uint256 boostedDepositWad);
    event Withdraw(address account, address referrer, uint256 drxClaimed, uint256 drxBurned, uint256 drxReferred);

    constructor(AutoRewardPool _drxRewardPool, DripstaX _drx, ReferralCodeRegistry _referralCodeRegistry, address _projectDev) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        drxRewardPool = _drxRewardPool;
        drx = _drx;
        referralCodeRegistry = _referralCodeRegistry;
        projectDev = _projectDev;
    }

    //For first time locks to remove need for multiple tx.
    function selectBoostAndLock(uint256 _wad, uint64 _boostIndex, string calldata _code) external {
        selectBoost(_boostIndex);
        lock(_wad, _code);
    }

    //Locks DRX. Transfers DRX to this contract from sender. Cancels withdraw request if one is active.
    //Defaults to boost 0 if a boost has not been selected.
    //Approve this contract for DRX tranfsers before calling.
    function lock(uint256 _wad, string calldata _code) public {
        require(_wad>0,"DrxLock: Must lock more than 0");

        //Note: Empty strings cannot be registered, so passing an empty string as code will set referrer to project dev account.
        address referrer = referralCodeRegistry.isCodeRegistered(_code) ? referralCodeRegistry.codeToAccount(_code) : projectDev;

        uint256 burnWad = _wad * burnBps / 10000;
        uint256 referrerWad = _wad * referralRewardBps / 10000;
        uint256 drxToLock = _wad - burnWad - referrerWad;

        if(withdrawInitiationEpoch[msg.sender]!=0) {
            cancelWithdrawRequest();
        }

        drx.transferFrom(msg.sender,address(this),_wad);
        drx.burn(burnWad);
        drx.approve(address(referralCodeRegistry),referrerWad);
        referralCodeRegistry.addRewardsViaAccount(referrer, referrerWad);
        drxLocked[msg.sender] += drxToLock;

        emit Lock(msg.sender,referrer,drxToLock,burnWad,referrerWad);
        _updateBoostedLockWad();
    
    }

    function initiateWithdrawRequest() public {
        require(withdrawInitiationEpoch[msg.sender]==0, "DrxLock: Withdraw request already initiated");
        require(drxLocked[msg.sender] >0, "DrxLock: No drx locked");
        drxRewardPool.withdrawViaLock(msg.sender,boostedDepositWad[msg.sender]);
        boostedDepositWad[msg.sender] = 0;
        withdrawInitiationEpoch[msg.sender] = uint64(block.timestamp);
        emit InitiateWithdrawRequest(msg.sender, uint64(block.timestamp));
        emit UpdateBoostedLockWad(msg.sender, drxLocked[msg.sender], 0);
    }

    //Withdraws all
    //Must initiate withdraw first and wait for selected boost period
    function withdraw(string calldata _code) public {
        require(withdrawInitiationEpoch[msg.sender]>0,"DrxLock: Must initiate withdraw first");
        require(withdrawInitiationEpoch[msg.sender]>=block.timestamp+boostOptions[selectedBoost[msg.sender]].period,"DrxLock: Must wait for boost period to pass");

        //Note: Empty strings cannot be registered, so passing an empty string as code will set referrer to project dev account.
        address referrer = referralCodeRegistry.isCodeRegistered(_code) ? referralCodeRegistry.codeToAccount(_code) : projectDev;

        uint256 wad = drxLocked[msg.sender];
        uint256 burnWad = wad * burnBps / 10000;
        uint256 referrerWad = wad * referralRewardBps / 10000;
        uint256 claimWad = wad - burnWad - referrerWad;

        drx.burn(burnWad);
        drx.approve(address(referralCodeRegistry),referrerWad);
        referralCodeRegistry.addRewardsViaAccount(referrer, referrerWad);
        drx.transfer(msg.sender,claimWad);

        drxLocked[msg.sender] = 0;
        withdrawInitiationEpoch[msg.sender] = 0;
        emit Withdraw(msg.sender, referrer, claimWad, burnWad, referrerWad);
        emit UpdateBoostedLockWad(msg.sender,0,0);
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
        emit UpdateBoostedLockWad(msg.sender,drxLocked[msg.sender],newBoostedDepositWad);
    }

    function ADMIN_addBoostOption(uint64 _period, uint64 _boostBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        boostOptions.push(Boost(_period,_boostBps));
        emit Admin_AddBoostOption(_period, _boostBps);
    }

    function ADMIN_setReferralCodeRegistry(ReferralCodeRegistry _referralCodeRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        referralCodeRegistry = _referralCodeRegistry;
    }

    function ADMIN_setDrxRewardPool(AutoRewardPool _drxRewardPool ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        drxRewardPool = _drxRewardPool;
    }

    function ADMIN_setDrx(DripstaX _drx ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        drx = _drx;
    }

    function ADMIN_setProjectDev(address _projectDev ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        projectDev = _projectDev;
    }

    function ADMIN_setReferralRewardBps(uint256 _referralRewardBps ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        referralRewardBps = _referralRewardBps;
    }

    function ADMIN_setBurnBps(uint256 _burnBps ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        burnBps = _burnBps;
    }

}