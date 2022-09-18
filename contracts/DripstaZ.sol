// SPDX-License-Identifier: GPL-3.0
// Authored by Plastic Digits
pragma solidity ^0.8.4;
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "./interfaces/IAmmPair.sol";
import "./interfaces/IAmmRouter02.sol";
import "./interfaces/ICurve.sol";
import "./AutoRewardPoolDrz.sol";

contract DripstaZ is AccessControlEnumerable, ERC20PresetMinterPauser {
    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER = keccak256("MANAGER");

    IERC20 public constant BUSD =
        IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    IERC20 public constant CZUSD =
        IERC20(0xE68b79e51bf826534Ff37AA9CeE71a3842ee9c70);
    ICurve public czusdBusdPairEps =
        ICurve(0x4d9508257Af7442827951f30dbFe3ee2a04ADCeE);
    IERC20 public drx;
    AutoRewardPoolDrz public rewardPoolDrz;

    IAmmPair public ammCzusdPair = IAmmPair(0xd7C6Fc00FAe64cb7D242186BFD21e31C5b175671);
    IAmmRouter02 public ammRouter = IAmmRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    // To reduce gas costs, fees are actually slightly less than set as the lp fee is taken either first or second.
    uint256 public fee_airdropBps = 200;
    uint256 public fee_rewardPoolBps = 500;
    uint256 public fee_lockedLpBps = 300;
    uint256 public maxFeeBps = 3500;

    uint256 public maxAmmSlippage = 100;

    constructor(
        IERC20 _drx,
        AutoRewardPoolDrz _rewardPoolDrz
    ) ERC20PresetMinterPauser("DripstaZ", "DRZ") {
        //NOTE: This contract should be exempted from DRX fees.
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER, msg.sender);
        _grantRole(MINTER_ROLE, address(this));
        _grantRole(PAUSER_ROLE, msg.sender);

        drx = _drx;
        ADMIN_setRewardPoolDrz(_rewardPoolDrz);
    }

    function depositBusd(uint256 _wad) external {
        //Get busd from caller
        BUSD.transferFrom(msg.sender, address(this), _wad);

        //Swap busd for czusd
        BUSD.approve(address(czusdBusdPairEps), _wad);
        czusdBusdPairEps.exchange(1, 0, _wad, (_wad * (10000 - maxAmmSlippage)) / 10000);

        //Figure out where the CZUSD should go.
        uint256 czusdBal = CZUSD.balanceOf(address(this));
        uint256 airdropFee = (czusdBal * fee_airdropBps) / 10000;
        uint256 rewardPoolFee = (czusdBal * fee_rewardPoolBps) / 10000;
        uint256 czusdForLp = czusdBal - airdropFee - rewardPoolFee;

        //Send the CZUSD for fees
        CZUSD.transfer(address(rewardPoolDrz), rewardPoolFee);
        CZUSD.approve(address(rewardPoolDrz), airdropFee);
        //Airdrop will first call updatePool, which will add the rewardPoolFee to rewardPerSecond.
        rewardPoolDrz.airdrop(airdropFee);

        //Swap half the CZUSD for lp for DRX.
        uint256 czusdToSwapForDrx = czusdForLp / 2;
        path[0] = address(CZUSD);
        path[1] = address(drx);
        CZUSD.approve(address(ammRouter), czusdToSwapForDrx);
        //Since this contract is exempt from fees, it is difficult for frontrunning bots to exploit this swap.
        ammRouter.swapExactTokensForTokens(
            czusdToSwapForDrx,
            0,
            path,
            address(this),
            block.timestamp
        );

        //Add liquidity
        czusdBal = CZUSD.balanceOf(address(this));
        uint256 drxBal = drx.balanceOf(address(this));
        CZUSD.approve(address(ammRouter), czusdBal);
        drx.approve(address(ammRouter), drxBal);
        (, , uint256 liqMinted) = ammRouter.addLiquidity(
            address(drx),
            address(CZUSD),
            drxBal,
            czusdBal,
            0,
            0,
            address(this),
            block.timestamp
        );

        //Send locked liquidity portion to drx contract
        uint256 lockedLiquidity = (liqMinted * fee_lockedLpBps) / 10000;
        ammCzusdPair.transfer(address(drx), lockedLiquidity);

        //Mint sender DRZ at rate of 1 per liq minted.
        _mint(msg.sender, liqMinted - lockedLiquidity);
    }

    function withdrawBusd(uint256 _drzWad) external {
        burnFrom(msg.sender,_drzWad);
        initialCzusdBal = CZUSD.balanceOf(address(this));
        initialBusdBal = BUSD.balanceOf(address(this));

        //Send locked liquidity portion to drx contract
        uint256 lockedLiquidity = (_drzWad * fee_lockedLpBps) / 10000;
        ammCzusdPair.transfer(address(drx), lockedLiquidity);

        //Remove the drx/czusd liquiidity
        ammCzusdPair.removeLiquidity(
        drx,//address tokenA,
        CZUSD,//address tokenB,
        _drzWad - lockedLiquidity,//uint256 liquidity,
        0,//uint256 amountAMin,
        0,//uint256 amountBMin,
        address(this),//address to,
        block.timestamp//uint256 deadline
        );

        //Swap the drx to CZUSD
        uint256 drxBal = drx.balanceOf(address(this));
        path[0] = address(drx);
        path[1] = address(CZUSD);
        drx.approve(address(ammRouter), drxBal);
        ammRouter.swapExactTokensForTokens(
            drxBal,
            0,
            path,
            address(this),
            block.timestamp
        );        

        //Figure out where the CZUSD should go.
        uint256 czusdSwapped = CZUSD.balanceOf(address(this)) - initialCzusdBal;
        uint256 airdropFee = (czusdSwapped * fee_airdropBps) / 10000;
        uint256 rewardPoolFee = (czusdSwapped * fee_rewardPoolBps) / 10000;
        uint256 swapToBusd = czusdSwapped - airdropFee - rewardPoolFee;

        //Send the CZUSD for fees
        CZUSD.transfer(address(rewardPoolDrz), rewardPoolFee);
        CZUSD.approve(address(rewardPoolDrz), airdropFee);
        //Airdrop will first call updatePool, which will add the rewardPoolFee to rewardPerSecond.
        rewardPoolDrz.airdrop(airdropFee);

        //Swap czusd for busd
        CZUSD.approve(address(czusdBusdPairEps), swapToBusd);
        czusdBusdPairEps.exchange(0, 1, swapToBusd, (swapToBusd * (10000 - maxAmmSlippage)) / 10000);

        //Return BUSD to sender.
        BUSD.transfer(msg.sender,initialBusdBal-BUSD.balanceOf(address(this)))
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override {
        super._transfer(sender, recipient, amount);

        //Update the holdings for autostaking.
        rewardPoolDrz.deposit(recipient, amount);
        rewardPoolDrz.withdraw(sender, amount);
    }

    function _mint(address account, uint256 amount) internal override {
        super._mint(account, amount);
        rewardPoolDrz.deposit(account, amount);
    }

    function _burn(address account, uint256 amount) internal override {
        super._burn(account, amount);
        rewardPoolDrz.withdraw(account, amount);
    }

    function getDrzPriceInCzusdWad() public view returns (uint256 priceWad_) {
        uint256 pairTokenSupply = ammCzusdPair.totalSupply();
        uint256 pairTokenBalanceOfDrz = ammCzusdPair.balanceOf(address(this));
        uint256 pairCzusdBal = CZUSD.balanceOf(address(ammCzusdPair));

        priceWad_ =
            (2 * 1 ether * pairCzusdBal * pairTokenBalanceOfDrz) /
            (pairTokenSupply * totalSupply());
    }

    function MANAGER_setBps(
        uint256 _fee_airdropBps,
        uint256 _fee_rewardPoolBps,
        uint256 _fee_lockedLpBps
    ) public onlyRole(MANAGER) {
        require(
            _fee_airdropBps + _fee_rewardPoolBps + _fee_lockedLpBps <=
                maxFeeBps,
            "DRZ: Fee too high"
        );
        fee_airdropBps = _fee_airdropBps;
        fee_rewardPoolBps = _fee_rewardPoolBps;
        fee_lockedLpBps = _fee_lockedLpBps;
    }

    function ADMIN_setAmmRouter(IAmmRouter02 _to)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        ammRouter = _to;
    }czusdBusdPairEps

    function ADMIN_setAmmCzusdPair(IAmmPair _to)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        ammCzusdPair = _to;
    }

    function ADMIN_setCzusdBusdPairEps(ICurve _to)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        czusdBusdPairEps = _to;
    }

    function ADMIN_setMaxFeeBps(uint256 _to)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        maxFeeBps = _to;
    }

    function ADMIN_setMaxAmmSlippage(uint256 _to)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        maxAmmSlippage = _to;
    }

    function ADMIN_setRewardPoolDrz(AutoRewardPoolDrz _to)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        rewardPoolDrz = _to;
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
}
