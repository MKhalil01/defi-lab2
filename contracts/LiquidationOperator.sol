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
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;

    // Constants defined
    address public owner;
    

    ILendingPool AAVE_LENDING_POOL = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    //Sushiswap
    IUniswapV2Factory UNISWAP_V2_FACTORY = IUniswapV2Factory(0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac);

    //Tokens
    IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    IERC20 constant USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    
    //Using Sushi pools
    IUniswapV2Pair WETH_USDT_UNI = IUniswapV2Pair(UNISWAP_V2_FACTORY.getPair(address(WETH), address(USDT)));
    IUniswapV2Pair WBTC_WETH_UNI = IUniswapV2Pair(UNISWAP_V2_FACTORY.getPair(address(WBTC), address(WETH)));
    // IUniswapV2Pair WBTC_USDT_UNI = IUniswapV2Pair(UNISWAP_V2_FACTORY.getPair(address(WBTC), address(USDT)));
    
    // USDT Owed
    // uint256 USDT_OWED = 5000 * 1e6;
    uint256 USDT_OWED = 2916358033172;

    address public constant TARGET_USER = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;


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
    // Set owner to the deployer address
    owner = msg.sender;
    } 

    receive() external payable {
        // Receive function to allow the contract to receive ETH
    }

    // required by the testing script, entry for your liquidation call
    function operate() external {
        // TODO: implement your liquidation logic

        // 0. security checks and initializing variables
        require(msg.sender == owner, "Only the owner can call this function"); // self explanatory

        // Check all Uni pairs exist
        require(address(WETH_USDT_UNI) != address(0), "WETH-USDT pair doesn't exist");
        require(address(WBTC_WETH_UNI) != address(0), "WBTC-WETH pair doesn't exist");
        
        // Get lending pool interface
        ILendingPool lendingPool = ILendingPool(AAVE_LENDING_POOL);

        // Check the actual reserves in all pools
        // WETH-USDT pool
        (uint112 wethUsdtReserve0, uint112 wethUsdtReserve1, ) = WETH_USDT_UNI.getReserves();
        console.log("WETH-USDT pool - WETH reserve: %s", wethUsdtReserve0);
        console.log("WETH-USDT pool - USDT reserve: %s", wethUsdtReserve1);
        
        // WBTC-WETH pool
        (uint112 wbtcWethReserve0, uint112 wbtcWethReserve1, ) = WBTC_WETH_UNI.getReserves();
        console.log("WBTC-WETH pool - WBTC reserve: %s", wbtcWethReserve0);
        console.log("WBTC-WETH pool - WETH reserve: %s", wbtcWethReserve1);

        // 1. get the target user account data & make sure it is liquidatable
        (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            ,
            ,
            ,
            uint256 healthFactor
        ) = lendingPool.getUserAccountData(TARGET_USER);
        
        // Health factor is scaled by 1e18, so 1e18 = 1.0
        require(healthFactor < 10**health_factor_decimals, "User is not liquidatable");
        
        console.log("Health Factor: %s", healthFactor);
        console.log("Total Collateral (ETH): %s", totalCollateralETH);
        console.log("Total Debt (ETH): %s", totalDebtETH);

        // 2. call flash swap to liquidate the target user
        // For liquidity and to avoid reentrancy issues we have adopted the following flow:
        // 1 Borrow USDT from WETH USDT pair
        // 3 Perform the liquidation to get back WBTC
        // 4 Swap WBTC for WETH to repay flashloan
        // 5 Swap remaining WBTC to WETH (or whatever currency) as profits $$$$


        // We need to borrow enough WETH to swap for USDT_OWED
        
        WETH_USDT_UNI.swap(0, USDT_OWED, address(this), "#");
        
        // 3. Convert the profit into ETH and send back to sender
        uint256 wethbalance = WETH.balanceOf(address(this));
        WETH.withdraw(wethbalance);
        payable(msg.sender).transfer(address(this).balance);

    }

    // required by the swap
    function uniswapV2Call(
        address ,
        uint256 ,
        uint256 amount1,
        bytes calldata
    ) external override {

        // 2.0. security checks and initializing variables
        require(msg.sender == address(WBTC_WETH_UNI)|| msg.sender == address(WETH_USDT_UNI), "Unauthorized callback");
        
        uint256 usdtbalance = amount1;
        console.log("USDT Balance: %s", usdtbalance);
        
        // Get reserves again 
        (uint112 wethUsdtReserve0, uint112 wethUsdtReserve1, ) = WETH_USDT_UNI.getReserves();
        (uint112 wbtcWethReserve0, uint112 wbtcWethReserve1, ) = WBTC_WETH_UNI.getReserves();


        // 2.1 liquidate the target user
        console.log("Liquidating");
        // Approve AAVE to use our USDT for liquidation
        USDT.approve(address(AAVE_LENDING_POOL), usdtbalance);

         // Liquidate the target user - we're repaying their USDT debt and receiving WBTC collateral
        AAVE_LENDING_POOL.liquidationCall(
            address(WBTC),    // collateral asset (WBTC)
            address(USDT),    // debt asset (USDT)
            TARGET_USER,      // user being liquidated
            usdtbalance,     // amount of debt to cover
            false             // receive the underlying collateral, not aTokens
        );

        // Get the amount of WBTC we received from liquidation
        uint256 wbtcReceived = WBTC.balanceOf(address(this));
        console.log("WBTC received from liquidation: %s", wbtcReceived);

        // Transfer WBTC to the WBTC-WETH pair
        WBTC.transfer(address(WBTC_WETH_UNI), wbtcReceived);

        // Swap WBTC for WETH
        uint256 weth_out = getAmountOut(
            wbtcReceived,
            wbtcWethReserve0,
            wbtcWethReserve1
        );
        
        
        WBTC_WETH_UNI.swap(0, weth_out, address(this), "");

        // Transfer WETH back to the pair to repay the flash loan
        // Make sure we have enough WETH to repay
        uint256 wethBalance = WETH.balanceOf(address(this));
                
        // Check remaining balances
        uint256 remainingWBTC = WBTC.balanceOf(address(this));
        console.log("WBTC remaining: %s", remainingWBTC);
        console.log("WETH : %s", wethBalance);
                
        // Repayment 
        uint256 repayment = getAmountIn(usdtbalance, wethUsdtReserve0, wethUsdtReserve1);
        WETH.transfer(address(WETH_USDT_UNI), repayment);

}
}
