//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;
import "hardhat/console.sol";

// ----------------------INTERFACE------------------------------

// Aave
// https://docs.aave.com/developers/the-core-protocol/lendingpool/ilendingpool

interface ILendingPool {
    /**
     * Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of theliquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /**
     * Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// UniswapV2

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IERC20.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/Pair-ERC-20
interface IERC20 {
    // Returns the account balance of another account with address _owner.
    function balanceOf(address owner) external view returns (uint256);

    /**
     * Allows _spender to withdraw from your account multiple times, up to the _value amount.
     * If this function is called again it overwrites the current allowance with _value.
     * Lets msg.sender set their allowance for a spender.
     **/
    function approve(address spender, uint256 value) external; // return type is deleted to be compatible with USDT

    /**
     * Transfers _value amount of tokens to address _to, and MUST fire the Transfer event.
     * The function SHOULD throw if the message caller’s account balance does not have enough tokens to spend.
     * Lets msg.sender send pool tokens to an address.
     **/
    function transfer(address to, uint256 value) external returns (bool);
}

// https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IWETH.sol
interface IWETH is IERC20 {
    // Convert the wrapped token back to Ether.
    function withdraw(uint256) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Callee.sol
// The flash loan liquidator we plan to implement this time should be a UniswapV2 Callee
interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/factory
interface IUniswapV2Factory {
    // Returns the address of the pair for tokenA and tokenB, if it has been created, else address(0).
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/pair
interface IUniswapV2Pair {
    /**
     * Swaps tokens. For regular swaps, data.length must be 0.
     * Also see [Flash Swaps](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/flash-swaps).
     **/
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /**
     * Returns the reserves of token0 and token1 used to price trades and distribute liquidity.
     * See Pricing[https://docs.uniswap.org/protocol/V2/concepts/advanced-topics/pricing].
     * Also returns the block.timestamp (mod 2**32) of the last block during which an interaction occured for the pair.
     **/
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
        
    // Add these two functions to the interface
    function token0() external view returns (address);
    function token1() external view returns (address);
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;

    // TODO: define constants used in the contract including ERC-20 tokens, Uniswap Pairs, Aave lending pools, etc. */
    // Tokens
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // Uniswap
    address public constant UNISWAP_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address public constant WBTC_USDT_PAIR = 0x0DE0Fa91b6DbaB8c8503aAA2D1DFa91a192cB149; // WBTC/USDT pair

    // Aave
    address public constant AAVE_LENDING_POOL = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;

    // Target user to liquidate (from the README)
    address public constant TARGET_USER = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;

    // Token0 and Token1 in the WBTC/USDT pair
    address public constant TOKEN0 = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; // WBTC
    address public constant TOKEN1 = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // USDT
    // END TODO

    // some helper function, it is totally fine if you can finish the lab without using these function
    // https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2Library.sol
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // some helper function, it is totally fine if you can finish the lab without using these function
    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    constructor() {
        // TODO: (optional) initialize your contract
        //   *** Your code here ***
        // END TODO
    }

    // TODO: add a `receive` function so that you can withdraw your WETH
    receive() external payable {}
    // END TODO

    // required by the testing script, entry for your liquidation call
    function operate() external {
        // TODO: implement your liquidation logic

        // 0. security checks and initializing variables
        ILendingPool lendingPool = ILendingPool(AAVE_LENDING_POOL);
        IUniswapV2Pair pair = IUniswapV2Pair(WBTC_USDT_PAIR);

        // 1. get the target user account data & make sure it is liquidatable
        (
            ,
            ,
            ,
            ,
            ,
            uint256 healthFactor
        ) = lendingPool.getUserAccountData(TARGET_USER);
        
        // Health factor is scaled by 1e18, if it's below 1e18 the position is liquidatable
        require(healthFactor < 10**health_factor_decimals, "Target user position is healthy");
        
        // 2. call flash swap to liquidate the target user
        // Based on the transaction in the README, we need to borrow USDT via flash swap
        // The amount to borrow is based on the debt we want to cover
        uint256 debtToCover = 2000000 * 10**6; // 2,000,000 USDT (USDT has 6 decimals)
        
        // Prepare data for the callback
        bytes memory data = abi.encode(TARGET_USER);
        
        // Initiate flash swap - borrow USDT (token1 in the pair)
        // amount0Out is 0 because we're not taking out any WBTC
        // amount1Out is the amount of USDT we want to borrow
        pair.swap(0, debtToCover, address(this), data);

        // 3. Convert the profit into ETH and send back to sender
        // After the flash swap callback completes, we should have WBTC profit
        uint256 wbtcBalance = IERC20(WBTC).balanceOf(address(this));
        if (wbtcBalance > 0) {
            // Find WBTC/WETH pair
            address wbtcWethPair = IUniswapV2Factory(UNISWAP_FACTORY).getPair(WBTC, WETH);
            
            // Approve WBTC transfer to the pair
            IERC20(WBTC).approve(wbtcWethPair, wbtcBalance);
            
            // Get reserves to calculate swap amount
            (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(wbtcWethPair).getReserves();
            
            // Make sure reserve0 is WBTC and reserve1 is WETH (or vice versa)
            uint256 wethOut;
            if (IUniswapV2Pair(wbtcWethPair).token0() == WBTC) {
                wethOut = getAmountOut(wbtcBalance, reserve0, reserve1);
                IUniswapV2Pair(wbtcWethPair).swap(0, wethOut, address(this), new bytes(0));
            } else {
                wethOut = getAmountOut(wbtcBalance, reserve1, reserve0);
                IUniswapV2Pair(wbtcWethPair).swap(wethOut, 0, address(this), new bytes(0));
            }
            
            // Unwrap WETH to ETH
            IWETH(WETH).withdraw(IERC20(WETH).balanceOf(address(this)));
            
            // Send ETH to the caller
            payable(msg.sender).transfer(address(this).balance);
        }
        // END TODO
    }

    // required by the swap
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override {
        // TODO: implement your liquidation logic

        // 2.0. security checks and initializing variables
        require(msg.sender == WBTC_USDT_PAIR, "Unauthorized callback");
        require(sender == address(this), "Unauthorized sender");
        
        // Decode the data passed from the operate function
        address targetUser = abi.decode(data, (address));
        
        // Get references to contracts
        ILendingPool lendingPool = ILendingPool(AAVE_LENDING_POOL);
        
        // 2.1 liquidate the target user
        // Approve USDT for the lending pool
        IERC20(USDT).approve(AAVE_LENDING_POOL, amount1);
        
        // Execute liquidation - we want to receive WBTC as collateral
        lendingPool.liquidationCall(
            WBTC,       // collateral asset (WBTC)
            USDT,       // debt asset (USDT)
            targetUser, // user to liquidate
            amount1,    // amount of debt to cover
            false       // receive the underlying collateral, not aTokens
        );
        
        // 2.2 swap WBTC for USDT to repay directly
        // Calculate how much USDT we need to repay (amount borrowed + 0.3% fee)
        uint256 repayAmount = amount1 * 1000 / 997 + 1; // Adding 1 to handle rounding
        
        // Get the WBTC balance we received from liquidation
        uint256 wbtcBalance = IERC20(WBTC).balanceOf(address(this));
        
        // Get reserves to calculate how much WBTC to swap for USDT
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(WBTC_USDT_PAIR).getReserves();
        
        // Calculate how much WBTC we need to swap to get enough USDT
        uint256 wbtcToSwap;
        if (TOKEN0 == WBTC) {
            wbtcToSwap = getAmountIn(repayAmount, reserve0, reserve1);
        } else {
            wbtcToSwap = getAmountIn(repayAmount, reserve1, reserve0);
        }
        
        // Ensure we have enough WBTC to repay
        require(wbtcBalance >= wbtcToSwap, "Not enough collateral received");
        
        // Approve WBTC transfer to the pair
        IERC20(WBTC).approve(WBTC_USDT_PAIR, wbtcToSwap);
        
        // 2.3 repay
        // Transfer USDT back to the pair
        IERC20(USDT).transfer(WBTC_USDT_PAIR, repayAmount);
        
        // END TODO
    }
}
