// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interface/IMintBurn.sol";
import "../lib/SafeDecimalMath.sol";
import "../interface/ITunnel.sol";
import "../interface/IAddressResolver.sol";
import "../interface/IOracle.sol";

contract MigratePool is Ownable, Pausable{

    using SafeMath for uint;
    using SafeDecimalMath for uint;
    using SafeERC20 for IERC20;

    bytes32 public constant ORACLE = "Oracle";
    bytes32 public constant TUNNEL_KEY = "BTC";
    bytes32 public constant BTC = "BTC";
    bytes32 public constant BOR = "BOR";

    IERC20 public depositToken;
    IERC20 public withdrawToken;
    address public distributor;
    uint public feeRate;
    uint public decimalDiff;
    uint public conversionRatio=1e18;
    IAddressResolver public addrReso;
    uint public period = 604800;
    uint public targetTime;
    uint public depositCountLimit=5;

    struct DebtInfo {
       uint obtcAmount;
       uint borAmount;
       uint claimTime;
    }

    mapping(address=>DebtInfo[]) public debt;
    mapping(uint=>mapping(bytes32=>uint)) public priceOf;

    constructor(address _addrReso, address _distributor, address _depositToken, address _withdrawToken, uint _feeRate, uint _decimalDiff, uint _startTime) public {
        depositToken = IERC20(_depositToken);
        withdrawToken = IERC20(_withdrawToken);
        feeRate = _feeRate;
        decimalDiff = 10 ** _decimalDiff;
        addrReso = IAddressResolver(_addrReso);
        targetTime = _startTime;
        distributor = _distributor;
    }

    function oracle() internal view returns(IOracle){
       return IOracle(addrReso.requireAndKey2Address(ORACLE, "MigratePool::oracle:oracle is not exist"));
    } 

    function tunnel() internal view returns(ITunnel) {
        return ITunnel(addrReso.requireAndKey2Address(TUNNEL_KEY, "MigratePool::tunnel:tunnel is not exist"));
    }

    function bor() internal view returns(IERC20) {
        return IERC20(addrReso.requireAndKey2Address(BOR, "MigratePool::bor::bor is not exist"));
    }

    function nextTargetTime() internal returns(uint) {
        targetTime = targetTime.add(period);
    }

    function setDistributor(address account) public onlyOwner {
        distributor = account;
    }

    function setPeriod(uint _period) public onlyOwner {
        period = _period;
    }

    function setPeriodPrice(uint ts, bytes32[] memory symbols, uint[] memory prices) public onlyOwner {
        require(symbols.length == prices.length, "MigratePool:setPeriodPrice:parameters not match");
        for (uint i=0; i < symbols.length; i++) {
            priceOf[ts][symbols[i]] = prices[i];
        }
    }

    function deposit(uint amount) public whenNotPaused{
        require(debt[msg.sender].length < depositCountLimit, "MigratePool::deposit:A user have depositCountLimit in a peroid, try again after claim");
        uint issueAmount = amount.mul(decimalDiff).multiplyDecimal(feeRate).multiplyDecimal(conversionRatio);
        // pledge ratio require
        require(IERC20(withdrawToken).totalSupply().add(issueAmount) <= tunnel().canIssueAmount(), "MigratePool::deposit:NotEnoughPledgeValue");
        uint borPrice = oracle().getPrice(BOR);
        uint btcPrice = oracle().getPrice(BTC);
        uint issueBorAmount = (amount.mul(decimalDiff)-issueAmount).multiplyDecimal(btcPrice).divideDecimal(borPrice);
        if(block.timestamp >= targetTime) {
            nextTargetTime();
        }
        debt[msg.sender].push(DebtInfo(issueAmount, issueBorAmount, targetTime.add(7200)));
        
        depositToken.safeTransferFrom(msg.sender, address(this), amount);
        emit MigrateToken(msg.sender, amount, issueAmount, feeRate);
    }

    function withdrawAdmin(address account) public onlyOwner {
        if(block.timestamp >= targetTime) {
            nextTargetTime();
        }
        depositToken.safeTransfer(account, depositToken.balanceOf(address(this)));
    }

    function claim() public {
        uint claimOBTC;
        uint claimBOR;
        DebtInfo[] storage userDebt = debt[msg.sender];
        uint i = 0;
        while(i != userDebt.length) {
            if(block.timestamp >= userDebt[i].claimTime) {
                claimOBTC = claimOBTC.add(userDebt[i].obtcAmount);
                claimBOR = claimBOR.add(userDebt[i].borAmount);
                userDebt[i] = userDebt[userDebt.length.sub(1)];
                userDebt.pop();
            } else {
                i++;
            }
        }
        if (claimOBTC > 0) {
            withdrawToken.safeTransferFrom(distributor, msg.sender, claimOBTC);
        }
        if (claimBOR > 0) {
            bor().safeTransferFrom(distributor, msg.sender, claimBOR);
        }
    }

    function claimableAmount() public view returns(uint claimOBTC, uint claimBOR, uint unclaimOBTC, uint unclaimBOR){
        DebtInfo[] storage userDebt = debt[msg.sender];
        for (uint i=0; i < userDebt.length; i++) {
            if(block.timestamp >= userDebt[i].claimTime) {
                claimOBTC = claimOBTC.add(userDebt[i].obtcAmount);
                claimBOR = claimBOR.add(userDebt[i].borAmount);
            } else {
                unclaimOBTC = unclaimOBTC.add(userDebt[i].obtcAmount);
                unclaimBOR = unclaimBOR.add(userDebt[i].borAmount);
            }
        }
    }

    function canDeposit(uint amount) public view returns(bool) {
        uint issueAmount = amount.mul(decimalDiff).multiplyDecimal(feeRate).multiplyDecimal(conversionRatio);
        if(IERC20(withdrawToken).totalSupply().add(issueAmount) <= tunnel().canIssueAmount()) {
            return true;
        } else {
            return false;
        }
    }

    function modifyFeeRate(uint _feeRate) public onlyOwner {
        feeRate = _feeRate;
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function setConversionRatio(uint _ratio) public onlyOwner {
        conversionRatio = _ratio;
    }

    event MigrateToken(address user, uint amount, uint issueAmount, uint feeRate);
}