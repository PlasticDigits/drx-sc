// SPDX-License-Identifier: GPL-3.0
// Authored by Plastic Digits
pragma solidity ^0.8.4;
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/KeeperCompatibleInterface.sol";
import "./czodiac/CZUSD.sol";
import "./AutoRewardPool.sol";
import "./AutoRewardPoolDrz.sol";
import "./libs/AmmLibrary.sol";
import "./interfaces/IAmmFactory.sol";
import "./interfaces/IAmmPair.sol";
import "./interfaces/IAmmRouter02.sol";

contract DripstaX is
    AccessControlEnumerable,
    ERC20PresetMinterPauser,
    KeeperCompatibleInterface
{
    using SafeERC20 for IERC20;
    bytes32 public constant MANAGER = keccak256("MANAGER");
    AutoRewardPool public drxRewardsDistributor;
    AutoRewardPoolDrz public drzRewardsDistributor;
    address public projectDistributor;

    bool public isMintingPermanentlyDisabled = false;

    mapping(address => uint64) public firstBuyEpoch;

    IERC20 public constant BUSD =
        IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);

    uint256 public drxBurnBPS_buy = 500;
    uint256 public drxBurnBPS_sell = 800;
    uint256 public drzBurnBPS_buy = 200;
    uint256 public drzBurnBPS_sell = 300;
    uint256 public devBurnBPS_buy = 300;
    uint256 public devBurnBPS_sell = 400;
    uint256 public maxBurnBPS = 3500;
    mapping(address => bool) public isExempt;

    IAmmPair public ammCzusdPair;
    IAmmRouter02 public ammRouter;
    CZUsd public czusd;

    uint256 public baseCzusdLocked;
    uint256 public totalCzusdSpent;
    uint256 public lockedCzusdTriggerLevel = 100 ether;

    bool public tradingOpen;

    constructor(
        CZUsd _czusd,
        IAmmRouter02 _ammRouter,
        IAmmFactory _factory,
        address _drxRewardsDistributor,
        address _drzRewardsDistributor,
        uint256 _baseCzusdLocked,
        address _projectDistributor
    ) ERC20PresetMinterPauser("DripstaX", "DRX") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(MANAGER, _drxRewardsDistributor);

        ADMIN_setCzusd(_czusd);
        ADMIN_setAmmRouter(_ammRouter);
        ADMIN_setBaseCzusdLocked(_baseCzusdLocked);
        MANAGER_setProjectDistributor(_projectDistributor);
        ADMIN_setDrxRewardsDistributor(_drxRewardsDistributor);
        ADMIN_setDrzRewardsDistributor(_drzRewardsDistributor);

        MANAGER_setIsExempt(msg.sender, true);
        MANAGER_setIsExempt(_drxRewardsDistributor, true);
        MANAGER_setIsExempt(_drzRewardsDistributor, true);

        ammCzusdPair = IAmmPair(
            _factory.createPair(address(this), address(czusd))
        );
    }

    function lockedCzusd() public view returns (uint256 lockedCzusd_) {
        bool czusdIsToken0 = ammCzusdPair.token0() == address(czusd);
        (uint112 reserve0, uint112 reserve1, ) = ammCzusdPair.getReserves();
        uint256 lockedLP = ammCzusdPair.balanceOf(address(this));
        uint256 totalLP = ammCzusdPair.totalSupply();

        uint256 lockedLpCzusdBal = ((czusdIsToken0 ? reserve0 : reserve1) *
            lockedLP) / totalLP;
        uint256 lockedLpDrxBal = ((czusdIsToken0 ? reserve1 : reserve0) *
            lockedLP) / totalLP;

        if (lockedLpDrxBal == totalSupply()) {
            lockedCzusd_ = lockedLpCzusdBal;
        } else {
            lockedCzusd_ =
                lockedLpCzusdBal -
                (
                    AmmLibrary.getAmountOut(
                        totalSupply() - lockedLpDrxBal,
                        lockedLpDrxBal,
                        lockedLpCzusdBal
                    )
                );
        }
    }

    function availableWadToSend() public view returns (uint256) {
        return lockedCzusd() - baseCzusdLocked - totalCzusdSpent;
    }

    function isOverTriggerLevel() public view returns (bool) {
        return lockedCzusdTriggerLevel <= availableWadToSend();
    }

    function checkUpkeep(bytes calldata)
        public
        view
        override
        returns (bool upkeepNeeded, bytes memory)
    {
        upkeepNeeded = isOverTriggerLevel();
    }

    function performUpkeep(bytes calldata) external override {
        uint256 wadToSend = availableWadToSend();
        totalCzusdSpent += wadToSend;
        czusd.mint(address(this), wadToSend);
        czusd.approve(address(ammRouter), wadToSend);
        address[] memory path = new address[](4);
        path[0] = address(czusd);
        path[1] = address(BUSD);
        ammRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            czusd.balanceOf(address(this)),
            0,
            path,
            address(this),
            block.timestamp
        );
        uint256 totalBurnBPS = drxBurnBPS_buy + drzBurnBPS_buy + devBurnBPS_buy;
        BUSD.transfer(
            address(drxRewardsDistributor),
            (BUSD.balanceOf(address(this)) * drxBurnBPS_buy) / totalBurnBPS
        );
        BUSD.transfer(
            address(drzRewardsDistributor),
            (BUSD.balanceOf(address(this)) * drzBurnBPS_buy) / totalBurnBPS
        );
        BUSD.transfer(
            address(projectDistributor),
            BUSD.balanceOf(address(this))
        );
        drxRewardsDistributor.updateNow();
        drzRewardsDistributor.updateNow();
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        if (balanceOf(recipient) == 0 && amount > 0)
            firstBuyEpoch[recipient] = uint64(block.timestamp);

        //Handle burn
        if (
            //Check if exempt wallet is buy/sell
            isExempt[sender] ||
            isExempt[recipient] ||
            //Check if not buy/sell: if not buy sell, no burn.
            (sender != address(ammCzusdPair) &&
                recipient != address(ammCzusdPair))
        ) {
            super._transfer(sender, recipient, amount);

            //Update the holdings for autostaking.
            drxRewardsDistributor.deposit(recipient, amount);
            drxRewardsDistributor.withdraw(sender, amount);
        } else {
            require(tradingOpen, "DRX: Not open");
            //If its not buy, its a sell since the check in the if() makes sure buy or sell
            bool isBuy = sender == address(ammCzusdPair);
            uint256 burnBPS = isBuy
                ? drxBurnBPS_buy + drzBurnBPS_buy + devBurnBPS_buy
                : drxBurnBPS_sell + drzBurnBPS_sell + devBurnBPS_sell;
            uint256 burnAmount = (amount * burnBPS) / 10000;
            if (burnAmount > 0) _burn(sender, burnAmount);
            uint256 postBurnAmount = amount - burnAmount;
            super._transfer(sender, recipient, postBurnAmount);

            //Update the holdings for autostaking.
            drxRewardsDistributor.deposit(recipient, postBurnAmount);
            drxRewardsDistributor.withdraw(sender, amount);
        }
    }

    function mint(address to, uint256 amount)
        public
        override
        onlyRole(MINTER_ROLE)
    {
        require(
            !isMintingPermanentlyDisabled,
            "DRX: Minting permanently disabled."
        );
        _mint(to, amount);
        drxRewardsDistributor.deposit(to, amount);
    }

    function MANAGER_setIsExempt(address _for, bool _to)
        public
        onlyRole(MANAGER)
    {
        isExempt[_for] = _to;
    }

    function MANAGER_setBps(
        uint256 _drxBurnBPS_buy,
        uint256 _drzBurnBPS_buy,
        uint256 _devBurnBPS_buy,
        uint256 _drxBurnBPS_sell,
        uint256 _drzBurnBPS_sell,
        uint256 _devBurnBPS_sell
    ) public onlyRole(MANAGER) {
        require(
            _drxBurnBPS_buy + _drzBurnBPS_buy + _devBurnBPS_buy <= maxBurnBPS,
            "DRX: Buy Burn too high"
        );
        require(
            _drxBurnBPS_sell + _drzBurnBPS_sell + _devBurnBPS_sell <=
                maxBurnBPS,
            "DRX: Sell Burn too high"
        );
        drxBurnBPS_buy = _drxBurnBPS_buy;
        drzBurnBPS_buy = _drzBurnBPS_buy;
        devBurnBPS_buy = _devBurnBPS_buy;
        drxBurnBPS_sell = _drxBurnBPS_sell;
        drzBurnBPS_sell = _drzBurnBPS_sell;
        devBurnBPS_sell = _devBurnBPS_sell;
    }

    function MANAGER_setProjectDistributor(address _to)
        public
        onlyRole(MANAGER)
    {
        projectDistributor = _to;
    }

    function ADMIN_openTrading() external onlyRole(DEFAULT_ADMIN_ROLE) {
        isMintingPermanentlyDisabled = true;
        tradingOpen = true;
    }

    function ADMIN_recoverERC20(address tokenAddress)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        IERC20(tokenAddress).transfer(
            _msgSender(),
            IERC20(tokenAddress).balanceOf(address(this))
        );
    }

    function ADMIN_setBaseCzusdLocked(uint256 _to)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        baseCzusdLocked = _to;
    }

    function ADMIN_setLockedCzusdTriggerLevel(uint256 _to)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        lockedCzusdTriggerLevel = _to;
    }

    function ADMIN_setAmmRouter(IAmmRouter02 _to)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        ammRouter = _to;
    }

    function ADMIN_setCzusd(CZUsd _to) public onlyRole(DEFAULT_ADMIN_ROLE) {
        czusd = _to;
    }

    function ADMIN_setMaxBurnBps(uint256 _to)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        maxBurnBPS = _to;
    }

    function ADMIN_setDrxRewardsDistributor(address _to)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        drxRewardsDistributor = AutoRewardPool(_to);
    }

    function ADMIN_setDrzRewardsDistributor(address _to)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        drzRewardsDistributor = AutoRewardPoolDrz(_to);
    }

    function ADMIN_setAmmCzusdPair(IAmmPair _to)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        ammCzusdPair = _to;
    }
}
