// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "./SafeMath.sol";
import "./IERC20.sol";
import "./SafeERC20.sol";

contract DFB {
    using SafeMath for uint256; 
    using SafeERC20 for IERC20;
    IERC20 public usdt;
    address[2] public feeReceivers;
    address public defaultRefer;
    uint256 private startTime;
    uint256 private helpBalance; // 互助余额
    uint256 private totalUser; 
    uint256 private totalLeader;
    uint256 private totalManager;
    uint256 private bonusLeft = 500; // 初始额外奖励

    uint256 private timeStep = 1 days;
    uint256 private dayPerCycle = 14 days; // 每期天数

    uint256 private feePercent = 150; // 平台运维费率
    uint256 private fundPercent = 50; // 头奖基金费率
    uint256 private ticketPercent = 200; // 门票费率
    uint256 private maxPerDayReward = 150;
    uint256 private minPerDayReward = 30;
    uint256 private bonusPercent = 500; // 额外奖励比例
    uint256 private directRate = 500;
    uint256[4] private leaderRates = [100, 200, 300, 100];
    uint256[6] private managerRates0 = [200, 100, 50, 30, 20, 10];
    uint256 private managerRate1 = 5;
    uint256 private managerRate2 = 3;
    uint256 private baseDivider = 10000;

    uint256 private referDepth = 31;

    uint256 private ticketPrice = 1e6;
    uint256 private totalSupply; // 门票总额
    uint256 private totalDestory; // 门票总消耗量

    uint256[4] private helpOptions = [300e6, 500e6, 1000e6, 2000e6];

    struct OrderInfo {
        uint256 rate; // 日利率
        uint256 amount; // 投资金额
        uint256 extra; // 额外奖励
        uint256 start; // 创建时间
        uint256 finish; // 结束时间
        uint256 unfreeze; // 0: 未解冻， 1：已解冻
        uint256 withdrawn; // 0：未提现，1：已提现
    }

    struct UserInfo {
        OrderInfo[] orders;
        address referrer;
        uint256 level; // 0:参与者, 1: 领导人, 2: 经理人
        uint256 curCycle;
        uint256 curCycleStart; 
        uint256 maxInvest;
        uint256 totalInvest;
        uint256 capitalLeft;
        uint256 ticketBal;
        uint256 ticketUsed;
        uint256 directNum;
        uint256 teamNum;
        uint256 lastWithdraw;
    }

    struct RewardInfo{
        uint256 direct;
        uint256 totalDirect;
        uint256 leader;
        uint256 managerLeft;
        uint256 managerFreezed;
        uint256 managerRelease;
        uint256 team;
        uint256 fund; // 激励奖
        uint256 extra; // 额外奖励
        uint256 withdrawn; // 静态 + 动态
    }

    struct FundPool {
        uint256 times; // 计次
        uint256 left; // 剩余待分配金额
        uint256 total; // 总计
        uint256 start; // 疲软开始时间
        uint256 orderNum; // 排单数量
        uint256 amount; // 排单总额
        uint256 curWithdrawn; // 已提款数量
        uint256 status; // 0 => 未进行， 1 => 进行中
    }

    uint256 private fundInitTime = 2 days;
    uint256 private fundPerValue = 100e6;
    uint256 private fundPerTime = 15 seconds; // 每排单100增加15s
    FundPool private fundPool; // 激励奖基金池

    mapping(uint256=>mapping(address=>uint256)) public userFundRank; // times=>user=>rank
    mapping (uint256=>mapping (uint256=>address)) public fundRankUser; // times=>rank=>user

    mapping(address=>UserInfo) private userInfo;
    mapping(address=>RewardInfo) private userRewardInfo;

    uint256[] private balDown = [10e10, 20e10, 40e10, 60e10, 100e10, 150e10, 200e10, 250e10, 350e10, 500e10, 800e10, 1000e10]; // 下降点
    uint256[] private balDownRate = [1000, 1500, 2000, 2500, 3500, 5000, 6000, 6500, 7000, 7500, 8000, 8000]; // 下降比例
    uint256[] private balRecover = [15e10, 30e10, 50e10, 80e10, 120e10, 150e10, 200e10, 250e10, 350e10, 500e10, 1000e10];// 恢复点
    mapping(uint256=>uint256) private balStatus; // 余额=>状态，0=>未触及，1=>已触及
    
    bool public isFreezeReward; // 是否处于冻结状态
    uint256 public recoverTime; // 解冻时间
    uint256 public freezeRewardTime;

    event StartHelp(address user, uint256 amount);
    event RecHelp(address user, uint256 amount);
    event WithdrawCapital(address user, uint256 amount);
    event BuyTicket(address user, uint256 price);

    constructor(address _usdtAddr, address _defaultRefer, address[2] memory _feeReceivers) public {
        usdt = IERC20(_usdtAddr);
        feeReceivers = _feeReceivers;
        startTime = block.timestamp;
        defaultRefer = _defaultRefer;
    }

    function buyTicket(uint256 _amount) external {
        uint256 price = _amount.mul(ticketPrice);
        usdt.safeTransferFrom(msg.sender, address(this), price);
        _mintTicket(msg.sender, _amount);
        emit BuyTicket(msg.sender, price);
    }

    function startHelp(address _referrer, uint256 _option) external {
        // 判断是否有资格
        require(_isOptionOk(msg.sender, _option) == true, "option err");
        UserInfo storage user = userInfo[msg.sender];
        uint256 amount = helpOptions[_option];
        // 扣排单币
        uint256 tickets = amount.mul(ticketPercent).div(baseDivider).div(1e6);
        require(user.ticketBal >= tickets, "insufficent tickets");
        _burnTicket(msg.sender, tickets);
        // 扣钱
        usdt.safeTransferFrom(msg.sender, address(this), amount);
        // 分钱
        _distributeHelp(amount);

        // 更新上级邀请
        if(user.referrer == address(0)){
            require(_referrer != msg.sender && (userInfo[_referrer].maxInvest > 0 || _referrer == defaultRefer), "referrer invalid");
            user.referrer = _referrer;
            _updateLevel(msg.sender);
        }

        // 更新上级奖励
        _updateReward(msg.sender, amount);

        // 新人 + 第一次额外奖励
        uint256 extra;
        if (user.maxInvest == 0 && user.curCycleStart == 0) {
			user.lastWithdraw = block.timestamp;
            user.curCycleStart = block.timestamp;
			totalUser = totalUser.add(1);
            if(bonusLeft > 0){
                bonusLeft = bonusLeft.sub(1);
                extra = amount.mul(bonusPercent).div(baseDivider);
            }
		}

        // 更新当前轮次
        if(user.curCycleStart.add(dayPerCycle) < block.timestamp){
            user.curCycle++;
            user.curCycleStart = block.timestamp;
        }

        // 更新个人订单
        uint256 finish = block.timestamp.add(dayPerCycle);
        user.orders.push(
            OrderInfo(
                getUserCurRate(msg.sender), 
                amount, 
                extra, 
                block.timestamp, 
                finish, 
                0,
                0
            )
        );

        // 更新个人信息
        if(amount > user.maxInvest){
            user.maxInvest = amount;
        }

        user.totalInvest = user.totalInvest.add(amount);
        user.capitalLeft = user.capitalLeft.add(amount);

        // 解冻本金
        bool isUnfreezeCapital;
        if(user.curCycle > 0){
            for(uint256 i = 0; i < user.orders.length; i++){
                OrderInfo storage order = user.orders[i];
                if(
                    order.finish < block.timestamp && 
                    order.unfreeze == 0 && 
                    amount >= order.amount
                )
                {
                    order.unfreeze = 1;
                    isUnfreezeCapital = true;
                    break;
                }
            }
        }

        if(!isUnfreezeCapital){
            // 解冻经理奖
            RewardInfo storage userReward = userRewardInfo[msg.sender];
            if(userReward.managerFreezed > 0){
                if(amount >= userReward.managerFreezed){
                    userReward.managerRelease = userReward.managerRelease.add(userReward.managerFreezed);
                    userReward.managerFreezed = 0;
                }else{
                    userReward.managerRelease = userReward.managerRelease.add(amount);
                    userReward.managerFreezed = userReward.managerFreezed.sub(amount);
                }
            }
        }

        // 分发激励奖
        _distributeFundPool();
        // 是否激励奖进行中
        if(fundPool.status == 1){
            fundPool.orderNum++;
            fundPool.amount = fundPool.amount.add(amount);
            uint256 oldRank = userFundRank[fundPool.times][msg.sender];
            if(oldRank != 0){
                fundRankUser[fundPool.times][oldRank] = address(0);
            }
            userFundRank[fundPool.times][msg.sender] = fundPool.orderNum;
            fundRankUser[fundPool.times][fundPool.orderNum] = msg.sender;
        }

        // 更新系统信息
        helpBalance = helpBalance.add(amount);
        // 余额触发
        _balActived();
        if(isFreezeReward){
            // 奖励控制
            _setFreezeReward();
        }

        emit StartHelp(msg.sender, amount);
    }

    function recHelp() external {
        // 分发激励奖
        _distributeFundPool();

        RewardInfo storage userReward = userRewardInfo[msg.sender];
        // 静态
        uint256 withdrawable = _getStaticRewards(msg.sender);
        // 动态
        withdrawable = withdrawable.add(_getReferRewards(msg.sender));
        
        // 额外奖励
        if(userReward.extra > 0){
            withdrawable = withdrawable.add(userReward.extra);
        }

        if(helpBalance >= withdrawable){
            userReward.direct = 0;
            userReward.leader = 0;
            userReward.managerRelease = 0;
            userReward.extra = 0;
            if(helpBalance > withdrawable){
                helpBalance = helpBalance.sub(withdrawable);
            }else{
                helpBalance = 0;
            }
        }else{
            withdrawable = 0;
            if(fundPool.status == 0){
                fundPool.status = 1;
                fundPool.start = block.timestamp;
            }
        }

        // 激励奖
        if(userReward.fund > 0){
            withdrawable = withdrawable.add(userReward.fund);
            userReward.fund = 0;
        }

        userReward.withdrawn = userReward.withdrawn.add(withdrawable);

        // 更新上次提现
        userInfo[msg.sender].lastWithdraw = block.timestamp;

        // 转账
        usdt.safeTransfer(msg.sender, withdrawable);

        // 奖励控制
        _setFreezeReward();

        emit RecHelp(msg.sender, withdrawable);
    }

    function withdrawCapital() external {
        // 分发激励奖
        _distributeFundPool();

        UserInfo storage user = userInfo[msg.sender];
        uint256 withdrawable; // 可提金额
        for(uint256 i = 0; i < user.orders.length; i++){
            OrderInfo storage order = user.orders[i];
            if(order.unfreeze == 1 && order.withdrawn == 0){
                order.withdrawn = 1;
                withdrawable = withdrawable.add(order.amount);
                if(order.extra > 0){
                    userRewardInfo[msg.sender].extra = userRewardInfo[msg.sender].extra.add(order.extra);
                }

                // 释放经理人奖励
                _releaseManagerRewards(msg.sender, order.amount);
            }
        }

        if(helpBalance >= withdrawable){
            if(helpBalance > withdrawable){
                helpBalance = helpBalance.sub(withdrawable);
            }else{
                helpBalance = 0;
            }
            user.capitalLeft = user.capitalLeft.sub(withdrawable);
            usdt.safeTransfer(msg.sender, withdrawable);
        }else{
            withdrawable = 0;
            if(fundPool.status == 0){
                fundPool.status = 1;
                fundPool.start = block.timestamp;
            }
        }
        
        // 奖励控制
        _setFreezeReward();

        emit WithdrawCapital(msg.sender, withdrawable);
    }

    function distributeFundPool() external {
        _distributeFundPool();
    }

    function getMaxFreezing(address _user) public view returns(uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 maxFreezing;
        for(uint256 i = user.orders.length; i > 0; i--){
            OrderInfo storage order = user.orders[i - 1];
            if(order.finish > block.timestamp){// 冻结中
                if(order.amount > maxFreezing){
                    maxFreezing = order.amount;
                }
            }else{
                break;
            }
        }
        return maxFreezing;
    }

    function getCapitalInfo(address _user) public view returns(uint256, uint256, uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 freezing; // 未到期，冻结中
        uint256 unfreezed; // 解冻未排单
        uint256 withdrawable; // 可提金额
        for(uint256 i = 0; i < user.orders.length; i++){
            OrderInfo storage order = user.orders[i];
            if(order.finish > block.timestamp){// 未到期
                freezing = freezing.add(order.amount);
            }else{
                if(order.unfreeze == 0){// 解冻未排单
                    unfreezed = unfreezed.add(order.amount);
                }else{
                    if(order.withdrawn == 0){// 可提现
                        withdrawable = withdrawable.add(order.amount);
                    }
                }
            }
        }
        return (freezing, unfreezed, withdrawable);
    }

    function getStaticRewards(address _user) external view returns(uint256) {
        return _getStaticRewards(_user);
    }

    function getReferRewards(address _user) external view returns(uint256) {
        return _getReferRewards(_user);
    }

    function getUserCurRate(address _user) public view returns(uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 curRate;
        uint256 orderRate = user.orders.length.mul(10);
        if(orderRate < maxPerDayReward){
            curRate = maxPerDayReward.sub(orderRate);
        }
        if(curRate < minPerDayReward){
            curRate = minPerDayReward;
        }
        return curRate;
    }

    function getUserReferrer(address _user) external view returns(address) {
        return userInfo[_user].referrer;
    }

    function getUserInfo(address _user) external view returns(uint256[13] memory) {
        UserInfo storage user = userInfo[_user];
        uint256[13] memory infos = [
            user.level,
            user.curCycle,
            user.curCycleStart,
            user.maxInvest,
            user.totalInvest,
            user.capitalLeft,
            user.ticketBal,
            user.ticketUsed,
            user.directNum,
            user.teamNum,
            user.lastWithdraw,
            _user.balance, // trx bal
            usdt.balanceOf(_user) // usdt bal
        ];
        return infos;
    }

    function getUserRewardInfo(address _user) external view returns(uint256[10] memory) {
        RewardInfo storage reward = userRewardInfo[_user];
        uint256[10] memory infos = [
            reward.direct,
            reward.totalDirect,
            reward.leader,
            reward.managerLeft,
            reward.managerFreezed,
            reward.managerRelease,
            reward.team,
            reward.fund,
            reward.extra,
            reward.withdrawn
        ];
        return infos;
    }

    function getOrderLength(address _user) external view returns(uint256) {
        return userInfo[_user].orders.length;
    }

    function getUserOrder(address _user, uint256 _index) external view returns(uint256[7] memory) {
        OrderInfo storage order = userInfo[_user].orders[_index];
        uint256[7] memory infos = [
            order.rate, 
            order.amount, 
            order.extra, 
            order.start, 
            order.finish, 
            order.unfreeze, 
            order.withdrawn
        ];
        return infos;
    }

    function getFundPool() external view returns(uint256[8] memory) {
        uint256[8] memory infos = [
            fundPool.times, 
            fundPool.left,
            fundPool.total,
            fundPool.start,
            fundPool.orderNum,
            fundPool.amount,
            fundPool.curWithdrawn,
            fundPool.status
        ];
        return infos;
    }

    function getSysInfo() external view returns(uint256[9] memory) {
        uint256[9] memory infos = [
            startTime,
            helpBalance,
            usdt.balanceOf(address(this)),
            totalUser,
            totalLeader,
            totalManager,
            bonusLeft,
            totalSupply,
            totalDestory
        ];
        return infos;
    }

    function getFundTimeLeft() public view returns(uint256) {
        uint256 totalTime = fundPool.start.add(fundPool.amount.div(fundPerValue).mul(fundPerTime)).add(fundInitTime);
        if(block.timestamp < totalTime){
            return totalTime.sub(block.timestamp);
        }
    }

    function getBalStatus() external view returns(uint256, uint256, uint256) {
        for(uint256 i = balDown.length; i > 0; i--){
            if(balStatus[balDown[i - 1]] == 1){
                uint256 maxDown = balDown[i - 1].mul(balDownRate[i - 1]).div(baseDivider);
                return (balDown[i - 1], balDown[i - 1].sub(maxDown), balRecover[i - 1]);
            }
        }
    }

    // 判断有无资格排此类单
    function isOptionOk(address _user, uint256 _option) external view returns(bool) {
        return _isOptionOk(_user, _option);
    }

    function _isOptionOk(address _user, uint256 _option) private view returns(bool) {
        if(_option >= helpOptions.length){
            return false;
        }
        UserInfo storage user = userInfo[_user];
        if(user.maxInvest == 0 ){
            if(_option >= helpOptions.length.sub(1)){
                return false;
            }
        }else{
            if(helpOptions[_option] < user.maxInvest){
                return false;
            }else{
                if(user.maxInvest < helpOptions[helpOptions.length.sub(2)]){
                    if(_option >= helpOptions.length.sub(1)){
                        return false;
                    }
                }
            }
        }
        return true;
    }

    function _getStaticRewards(address _user) private view returns(uint256) {
        uint256 withdrawable;
        // 静态
        // 已触发静态奖励冻结
        UserInfo storage user = userInfo[_user];
        (uint256 freezing, uint256 unfreezed, ) = getCapitalInfo(_user);
        uint256 capitalLeft = freezing.add(unfreezed);
        uint256 staticReward = _staticRewards(_user, user.lastWithdraw);
        uint256 referReward = _getReferRewards(_user);
        uint256 totalWithNow = staticReward.add(referReward).add(userRewardInfo[_user].withdrawn);
        if(isFreezeReward){
            if(capitalLeft > userRewardInfo[_user].withdrawn){
                if(capitalLeft >= totalWithNow){
                    withdrawable = staticReward;
                }else{
                    if(capitalLeft > userRewardInfo[_user].withdrawn.add(referReward)){
                        withdrawable = capitalLeft.sub(userRewardInfo[_user].withdrawn.add(referReward));
                    }
                }
            }
        }else{
            withdrawable = staticReward;
            if(recoverTime > freezeRewardTime && totalWithNow > capitalLeft && recoverTime > user.lastWithdraw){
                withdrawable = _staticRewards(_user, recoverTime);
            }
        }
        return withdrawable;
    }

    function _getReferRewards(address _user) private view returns(uint256) {
        RewardInfo storage userRewards = userRewardInfo[_user];
        // 直推
        uint256 withdrawable = userRewards.direct;
        // 领导人
        withdrawable = withdrawable.add(userRewards.leader);
        // 经理人
        withdrawable = withdrawable.add(userRewards.managerRelease);
        return withdrawable;
    }

    function _staticRewards(address _user, uint256 _lastWithdraw) private view returns(uint256 withdrawable) {
        UserInfo storage user = userInfo[_user];
        for(uint256 i = 0; i < user.orders.length; i++){
            OrderInfo storage order = user.orders[i];
            uint256 from = order.start > _lastWithdraw ? order.start : _lastWithdraw;
            uint256 to = block.timestamp > order.finish ? order.finish : block.timestamp;
            if(from < to){
                uint256 nowReward = order.amount.mul(order.rate).mul(to.sub(from)).div(timeStep).div(baseDivider);
                withdrawable = withdrawable.add(nowReward);
            }
        }
    }

    function _releaseManagerRewards(address _user, uint256 _amount) private {
        UserInfo storage user = userInfo[_user];
        address upline = user.referrer;
        for(uint256 i = 0; i < referDepth; i++){
            if(upline != address(0)){
                if(userInfo[upline].level >= 2){
                    uint256 newAmount = _amount;
                    if(upline != defaultRefer){
                        uint256 maxFreezing = getMaxFreezing(upline);
                        if(maxFreezing < _amount){
                            newAmount = maxFreezing;
                        }
                    }
                    uint256 managerReward;
                    if(i > 4 && i <= 10){
                        managerReward = newAmount.mul(managerRates0[i - 5]).div(baseDivider);
                    }else if(i > 10 && i <= 20){
                        managerReward = newAmount.mul(managerRate1).div(baseDivider);
                    }else if(i > 20){
                        managerReward = newAmount.mul(managerRate2).div(baseDivider);
                    }

                    if(userRewardInfo[upline].managerLeft < managerReward){
                        managerReward = userRewardInfo[upline].managerLeft;
                    }
                    userRewardInfo[upline].managerFreezed = userRewardInfo[upline].managerFreezed.add(managerReward); 
                    userRewardInfo[upline].managerLeft = userRewardInfo[upline].managerLeft.sub(managerReward);
                }
            }else{
                break;
            }
            upline = userInfo[upline].referrer;
        }

    }

    function _distributeFundPool() private {
        if(fundPool.status == 1 && getFundTimeLeft() == 0){
            for(uint256 i = fundPool.orderNum; i > 0; i--){
                address userAddr = fundRankUser[fundPool.times][i];
                if(userAddr != address(0)){
                    RewardInfo storage userReward = userRewardInfo[userAddr];
                    uint256 investCount = userInfo[userAddr].orders.length;
                    uint256 amount = userInfo[userAddr].orders[investCount.sub(1)].amount;
                    uint256 reward;
                    if(i == fundPool.orderNum){
                        reward = amount.mul(5);
                    }else{
                        reward = amount.mul(3);
                    }

                    if(reward < fundPool.left){
                        userReward.fund = userReward.fund.add(reward);
                        fundPool.left = fundPool.left.sub(reward);
                    }else{
                        userReward.fund = userReward.fund.add(fundPool.left);
                        fundPool.left = 0;
                    }
                }
            }

            _resetFundPool();
        }
    }

    function _resetFundPool() private {
        fundPool.times++;
        fundPool.left = 0;
        fundPool.start = 0;
        fundPool.orderNum = 0;
        fundPool.amount = 0;
        fundPool.curWithdrawn = 0;
        fundPool.status = 0;
    }

    function _updateLevel(address _user) private {
        UserInfo storage user = userInfo[_user];
        if(user.referrer != address(0)){
            address upline = user.referrer;
            userInfo[upline].directNum = userInfo[upline].directNum.add(1);
            for(uint256 i = 0; i < referDepth; i++){
                if(upline != address(0)){
                    userInfo[upline].teamNum = userInfo[upline].teamNum.add(1);
                    uint256 levelNow = _calcLevel(userInfo[upline].directNum, userInfo[upline].teamNum);
                    if(levelNow > userInfo[upline].level){
                        userInfo[upline].level = levelNow;
                        if(userInfo[upline].level == 1){
                            totalLeader = totalLeader.add(1);
                        }else if(userInfo[upline].level == 2){
                            totalLeader = totalLeader.sub(1);
                            totalManager = totalManager.add(1);
                        }
                    }
                    upline = userInfo[upline].referrer;
                }else{
                    break;
                }
            }
        }
    }

    function _calcLevel(
        uint256 _directNum, 
        uint256 _teamNum
    ) 
        private 
        pure 
        returns(
            uint256 levelNow
        ) 
    {
        if(_directNum >= 5 && _teamNum >= 50){
            levelNow = 1;
        }
        if(_directNum >= 10 && _teamNum >= 200){
            levelNow = 2;
        }
    }

    function _updateReward(address _user, uint256 _amount) private {
        UserInfo storage user = userInfo[_user];
        // 直推 + 领导人奖励 + 经理人奖励
        address upline = user.referrer;
        for(uint256 i = 0; i < referDepth; i++){
            if(upline != address(0)){
                uint256 newAmount = _amount;
                if(upline != defaultRefer){
                    uint256 maxFreezing = getMaxFreezing(upline);
                    if(maxFreezing < _amount){
                        newAmount = maxFreezing;
                    }
                }
                
                RewardInfo storage upRewards = userRewardInfo[upline];
                uint256 reward;
                if(i == 0){
                    // 直推奖励
                    reward = newAmount.mul(directRate).div(baseDivider);
                    upRewards.direct = upRewards.direct.add(reward);
                    upRewards.totalDirect = upRewards.totalDirect.add(reward);
                }else if(i <= 4 && userInfo[upline].level > 0){
                    // 领导奖
                    reward = newAmount.mul(leaderRates[i - 1]).div(baseDivider);
                    upRewards.leader = upRewards.leader.add(reward);
                }else{
                    // 经理奖
                    if(i > 4 && i <= 10 && userInfo[upline].level > 1){
                        reward = newAmount.mul(managerRates0[i - 5]).div(baseDivider);
                    }
                    if(i > 10 && i <= 20 && userInfo[upline].level > 1){
                        reward = newAmount.mul(managerRate1).div(baseDivider);
                    }
                    if(i > 20 && userInfo[upline].level > 1) {
                        reward = newAmount.mul(managerRate2).div(baseDivider);
                    }
                    upRewards.managerLeft = upRewards.managerLeft.add(reward);
                }
                upRewards.team = upRewards.team.add(reward);
            }else{
                break;
            }
            upline = userInfo[upline].referrer;
        }
    }

    function _mintTicket(address _user, uint256 _amount) private {
        totalSupply = totalSupply.add(_amount);
        UserInfo storage user = userInfo[_user];
        user.ticketBal = user.ticketBal.add(_amount);
    }

    function _burnTicket(address _user, uint256 _amount) private {
        totalDestory = totalDestory.add(_amount);
        UserInfo storage user = userInfo[_user];
        user.ticketBal = user.ticketBal.sub(_amount);
        user.ticketUsed = user.ticketUsed.add(_amount);
    }

    function _distributeHelp(uint256 _amount) private {
        uint256 fee = _amount.mul(feePercent).div(baseDivider);
        usdt.safeTransfer(feeReceivers[0], fee.div(3));
        usdt.safeTransfer(feeReceivers[1], fee.mul(2).div(3));
        uint256 fund = _amount.mul(fundPercent).div(baseDivider);
        fundPool.left = fundPool.left.add(fund);
        fundPool.total = fundPool.total.add(fund);
    }

    function _balActived() private {
        for(uint256 i = balDown.length; i > 0; i--){
            if(helpBalance >= balDown[i - 1]){
                balStatus[balDown[i - 1]] = 1;
                break;
            }
        }
    }

    // 奖励控制
    function _setFreezeReward() private {
        for(uint256 i = balDown.length; i > 0; i--){
            if(balStatus[balDown[i - 1]] == 1){
                uint256 maxDown = balDown[i - 1].mul(balDownRate[i - 1]).div(baseDivider);
                if(helpBalance < balDown[i - 1].sub(maxDown)){
                    isFreezeReward = true;
                    freezeRewardTime = block.timestamp;
                }else if(isFreezeReward && helpBalance >= balRecover[i - 1]){
                    isFreezeReward = false;
                    recoverTime = block.timestamp;
                }
                break;
            }
        }
    }
 
}

