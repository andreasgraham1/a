// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./../../VariableRewardsStrategy.sol";
import "./interfaces/IJoeChef.sol";
import "./../yak/interfaces/IgAvax.sol";
import "./../yak/interfaces/ISwap.sol";

contract YYAvaxJoeStrategy is VariableRewardsStrategy {
    uint256 public immutable PID;
    IJoeChef public immutable joeChef;
    ISwap public immutable withdrawalPool;
    address public immutable swapPairWavaxOther;

    address public constant JOE = 0x6e84a6216eA6dACC71eE8E6b0a5B7322EEbC0fDd;
    address public constant yyAVAX = 0xF7D9281e8e363584973F946201b82ba72C965D27;
    address public constant gAvax = 0x6026a85e11BD895c934Af02647E8C7b4Ea2D9808;

    constructor(
        address _stakingContract,
        uint256 _pid,
        address _swapPairWavaxOther,
        address _withdrawalPool,
        VariableRewardsStrategySettings memory _settings,
        StrategySettings memory _strategySettings
    ) VariableRewardsStrategy(_settings, _strategySettings) {
        joeChef = IJoeChef(_stakingContract);
        PID = _pid;
        swapPairWavaxOther = _swapPairWavaxOther;
        withdrawalPool = ISwap(_withdrawalPool);
        IgAVAX(gAvax).setApprovalForAll(address(withdrawalPool), true);
    }

    receive() external payable {
        require(msg.sender == address(withdrawalPool) || msg.sender == address(WAVAX), "not allowed");
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public virtual returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function setAllowances() public onlyDev {
        IgAVAX(gAvax).setApprovalForAll(address(withdrawalPool), true);
    }

    function revokeAllowance() public onlyDev {
        IgAVAX(gAvax).setApprovalForAll(address(withdrawalPool), false);
    }

    function _depositToStakingContract(uint256 _amount, uint256) internal override {
        depositToken.approve(address(joeChef), _amount);
        joeChef.deposit(PID, _amount);
    }

    function _withdrawFromStakingContract(uint256 _amount) internal override returns (uint256 withdrawAmount) {
        joeChef.withdraw(PID, _amount);
        return _amount;
    }

    function _pendingRewards() internal view override returns (Reward[] memory) {
        (uint256 pendingJoe, , , uint256 pendingBonusToken) = joeChef.pendingTokens(PID, address(this));

        Reward[] memory pendingRewards = new Reward[](2);
        pendingRewards[0] = Reward({reward: address(JOE), amount: pendingJoe});
        pendingRewards[1] = Reward({
            reward: address(WAVAX),
            amount: pendingBonusToken > 0 ? withdrawalPool.calculateSwap(1, 0, pendingBonusToken) : 0
        });

        return pendingRewards;
    }

    function _getRewards() internal override {
        joeChef.deposit(PID, 0);
        uint256 yyAVAXBalance = IERC20(yyAVAX).balanceOf(address(this));
        if (yyAVAXBalance > 0) {
            withdrawalPool.swap{value: 0}(1, 0, yyAVAXBalance, 0, type(uint256).max);
        }
    }

    function _convertRewardTokenToDepositToken(uint256 _fromAmount) internal override returns (uint256 toAmount) {
        uint256 amountIn = _fromAmount / 2;

        address token0 = IPair(address(depositToken)).token0();
        address token1 = IPair(address(depositToken)).token1();

        uint256 amountOutToken0 = amountIn;
        if (address(WAVAX) != token0) {
            amountOutToken0 = token0 == yyAVAX
                ? _swapThroughWithdrawalPool(amountIn)
                : _swapThroughPair(amountIn, token0);
        }

        uint256 amountOutToken1 = amountIn;
        if (address(WAVAX) != token1) {
            amountOutToken1 = token1 == yyAVAX
                ? _swapThroughWithdrawalPool(amountIn)
                : _swapThroughPair(amountIn, token1);
        }

        return DexLibrary.addLiquidity(address(depositToken), amountOutToken0, amountOutToken1);
    }

    function _swapThroughWithdrawalPool(uint256 _amountIn) internal returns (uint256) {
        WAVAX.withdraw(_amountIn);
        return withdrawalPool.swap{value: _amountIn}(0, 1, _amountIn, 0, type(uint256).max);
    }

    function _swapThroughPair(uint256 _amountIn, address _toToken) internal returns (uint256) {
        return DexLibrary.swap(_amountIn, address(WAVAX), _toToken, IPair(swapPairWavaxOther));
    }

    function totalDeposits() public view override returns (uint256 amount) {
        (amount, ) = joeChef.userInfo(PID, address(this));
    }

    function _emergencyWithdraw() internal override {
        depositToken.approve(address(joeChef), 0);
        joeChef.emergencyWithdraw(PID);
    }
}
