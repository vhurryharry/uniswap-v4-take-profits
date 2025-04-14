// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

using FixedPointMathLib for uint256;

contract TakeProfitsHook is BaseHook, ERC1155 {
    // Use the PoolIdLibrary for PoolKey to add the `.toId()` function on a PoolKey
    // which hashes the PoolKey struct into a bytes32 value
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Create a mapping to store the last known tickLower value for a given Pool
    mapping(PoolId poolId => int24 tickLower) public tickLowerLasts;

    // Create a nested mapping to store the take-profit orders placed by users
    // The mapping is PoolId => tickLower => zeroForOne => amount
    // PoolId => (...) specifies the ID of the pool the order is for
    // tickLower => (...) specifies the tickLower value of the order i.e. sell when price is greater than or equal to this tick
    // zeroForOne => (...) specifies whether the order is swapping Token 0 for Token 1 (true), or vice versa (false)
    // amount specifies the amount of the token being sold
    mapping(PoolId poolId => mapping(int24 tick => mapping(bool zeroForOne => int256 amount)))
        public takeProfitPositions;

    // tokenIdExists is a mapping to store whether a given tokenId (i.e. a take-profit order) exists given a token id
    mapping(uint256 tokenId => bool exists) public tokenIdExists;
    // tokenIdClaimable is a mapping that stores how many swapped tokens are claimable for a given tokenId
    mapping(uint256 tokenId => uint256 claimable) public tokenIdClaimable;
    // tokenIdTotalSupply is a mapping that stores how many tokens need to be sold to execute the take-profit order
    mapping(uint256 tokenId => uint256 supply) public tokenIdTotalSupply;
    // tokenIdData is a mapping that stores the PoolKey, tickLower, and zeroForOne values for a given tokenId
    mapping(uint256 tokenId => TokenData) public tokenIdData;

    struct TokenData {
        PoolKey poolKey;
        int24 tick;
        bool zeroForOne;
    }

    // Initialize BaseHook and ERC1155 parent contracts in the constructor
    constructor(
        IPoolManager _poolManager,
        string memory _uri
    ) BaseHook(_poolManager) ERC1155(_uri) {}

    // Required override function for BaseHook to let the PoolManager know which hooks are implemented
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // Utilities
    function _setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function _getTickLower(
        int24 actualTick,
        int24 tickSpacing
    ) private pure returns (int24) {
        int24 intervals = actualTick / tickSpacing;
        if (actualTick < 0 && actualTick % tickSpacing != 0) intervals--; // round towards negative infinity
        return intervals * tickSpacing;
    }

    // Hooks
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick,
        // Add bytes calldata after tick
        bytes calldata
    ) external override onlyPoolManager returns (bytes4) {
        _setTickLowerLast(key.toId(), _getTickLower(tick, key.tickSpacing));
        return TakeProfitsHook.afterInitialize.selector;
    }

    function getTokenId(
        PoolKey calldata key,
        int24 tickLower,
        bool zeroForOne
    ) public pure returns (uint256) {
        return
            uint256(
                keccak256(abi.encodePacked(key.toId(), tickLower, zeroForOne))
            );
    }

    function placeOrder(
        PoolKey calldata key,
        int24 tick,
        uint256 amountIn,
        bool zeroForOne
    ) external returns (int24) {
        int24 tickLower = _getTickLower(tick, key.tickSpacing);
        takeProfitPositions[key.toId()][tickLower][zeroForOne] += int256(
            amountIn
        );

        uint256 tokenId = getTokenId(key, tickLower, zeroForOne);
        // If token id doesn't already exist, add it to the mapping
        // Not every order creates a new token id, as it's possible for users to add more tokens to a pre-existing order
        if (!tokenIdExists[tokenId]) {
            tokenIdExists[tokenId] = true;
            tokenIdData[tokenId] = TokenData(key, tickLower, zeroForOne);
        }

        // Mint ERC-1155 tokens to the user
        _mint(msg.sender, tokenId, amountIn, "");
        tokenIdTotalSupply[tokenId] += amountIn;

        // Extract the address of the token the user wants to sell
        address tokenToBeSoldContract = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);

        // Move the tokens to be sold from the user to this contract
        IERC20(tokenToBeSoldContract).transferFrom(
            msg.sender,
            address(this),
            amountIn
        );

        return tickLower;
    }

    function cancelOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) external {
        int24 tickLower = _getTickLower(tick, key.tickSpacing);
        uint256 tokenId = getTokenId(key, tickLower, zeroForOne);

        // Get the amount of tokens the user's ERC-1155 tokens represent
        uint256 amountIn = balanceOf(msg.sender, tokenId);
        require(amountIn > 0, "TakeProfitsHook: No orders to cancel");

        takeProfitPositions[key.toId()][tickLower][zeroForOne] -= int256(
            amountIn
        );
        tokenIdTotalSupply[tokenId] -= amountIn;
        _burn(msg.sender, tokenId, amountIn);

        // Extract the address of the token the user wanted to sell
        Currency tokenToBeSold = zeroForOne ? key.currency0 : key.currency1;
        // Move the tokens to be sold from this contract back to the user
        tokenToBeSold.transfer(msg.sender, amountIn);
    }

    function _handleSwap(
        PoolKey calldata key,
        IPoolManager.SwapParams memory params
    ) internal returns (BalanceDelta) {
        // delta is the BalanceDelta struct that stores the delta balance changes
        // i.e. Change in Token 0 balance and change in Token 1 balance

        BalanceDelta delta = poolManager.swap(key, params, "");

        // If this swap was a swap for Token 0 to Token 1
        if (params.zeroForOne) {
            // If we owe Uniswap Token 0, we need to send them the required amount
            // NOTE: This will be a negative value, as it is a negative balance change from the user's perspective
            if (delta.amount0() < 0) {
                IERC20(Currency.unwrap(key.currency0)).transfer(
                    address(poolManager),
                    // We flip the sign of the amount to make it positive when sending it to the pool manager
                    uint128(-delta.amount0())
                );

                poolManager.sync(key.currency0);
                poolManager.settle();
            }

            // If we are owed Token 1, we need to `take` it from the Pool Manager
            if (delta.amount1() > 0) {
                poolManager.take(
                    key.currency1,
                    address(this),
                    uint128(delta.amount1())
                );
            }
        }
        // Else if this swap was a swap for Token 1 to Token 0
        else {
            // Same as above
            // If we owe Uniswap Token 1, we need to send them the required amount
            if (delta.amount1() < 0) {
                IERC20(Currency.unwrap(key.currency1)).transfer(
                    address(poolManager),
                    uint128(-delta.amount1())
                );

                poolManager.sync(key.currency1);
                poolManager.settle();
            }

            // If we are owed Token 0, we take it from the Pool Manager
            if (delta.amount0() > 0) {
                poolManager.take(
                    key.currency0,
                    address(this),
                    uint128(delta.amount0())
                );
            }
        }

        return delta;
    }

    function fillOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        int256 amountIn
    ) internal {
        // Setup the swapping parameters
        IPoolManager.SwapParams memory swapParaps = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -amountIn,
            // Set the price limit to be the least possible if swapping from Token 0 to Token 1
            // or the maximum possible if swapping from Token 1 to Token 0
            // i.e. infinite slippage allowed
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = _handleSwap(key, swapParaps);

        // Update mapping to reflect that `amountIn` worth of tokens have been swapped from this order
        takeProfitPositions[key.toId()][tick][zeroForOne] -= amountIn;

        uint256 tokenId = getTokenId(key, tick, zeroForOne);

        // Tokens we were owed by Uniswap are represented as a positive delta change
        uint256 amountOfTokensReceivedFromSwap = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));

        // Update the amount of tokens claimable for this order
        tokenIdClaimable[tokenId] += amountOfTokensReceivedFromSwap;
    }

    function _tryFulfillingOrders(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) internal returns (bool, int24) {
        // Get the exact current tick and use it to calculate the currentTickLower
        (, int24 currentTick, ) = poolManager.getSlot0(key.toId());
        int24 currentTickLower = _getTickLower(currentTick, key.tickSpacing);
        int24 lastTickLower = tickLowerLasts[key.toId()];

        // We execute orders in the opposite direction
        // i.e. if someone does a zeroForOne swap to increase price of Token 1, we execute
        // all orders that are oneForZero
        // and vice versa
        bool swapZeroForOne = !params.zeroForOne;
        int256 swapAmountIn;

        // If tick has increased since last tick (i.e. zeroForOne swaps happened)
        if (lastTickLower < currentTickLower) {
            // Loop through all ticks between the lastTickLower and currentTickLower
            // and execute all orders that are oneForZero
            for (int24 tick = lastTickLower; tick < currentTickLower; ) {
                swapAmountIn = takeProfitPositions[key.toId()][tick][
                    swapZeroForOne
                ];
                if (swapAmountIn > 0) {
                    fillOrder(key, tick, swapZeroForOne, swapAmountIn);

                    // The fulfillment of the above order has changed the current tick
                    // Refetch the current tick value, and return it
                    // Also, return `true`, as we may have orders available to fulfill in the new tick range
                    (, currentTick, , ) = poolManager.getSlot0(key.toId());
                    currentTickLower = _getTickLower(
                        currentTick,
                        key.tickSpacing
                    );
                    return (true, currentTickLower);
                }
                tick += key.tickSpacing;
            }
        }
        // Else if tick has decreased (i.e. oneForZero swaps happened)
        else {
            // Loop through all ticks between the lastTickLower and currentTickLower
            // and execute all orders that are zeroForOne
            for (int24 tick = lastTickLower; currentTickLower < tick; ) {
                swapAmountIn = takeProfitPositions[key.toId()][tick][
                    swapZeroForOne
                ];
                if (swapAmountIn > 0) {
                    fillOrder(key, tick, swapZeroForOne, swapAmountIn);

                    // The fulfillment of the above order has changed the current tick
                    // Refetch the current tick value, and return it
                    // Also, return `true`, as we may have orders available to fulfill in the new tick range
                    (, currentTick, , ) = poolManager.getSlot0(key.toId());
                    currentTickLower = _getTickLower(
                        currentTick,
                        key.tickSpacing
                    );
                    return (true, currentTickLower);
                }
                tick -= key.tickSpacing;
            }
        }

        // If we did not return by now, there are no orders possibly left to fulfill within the range
        // Return `false` and the currentTickLower value
        return (false, currentTickLower);
    }

    function afterSwap(
        address addr,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4) {
        // Every time we fulfill an order, we do a swap
        // So it creates an `afterSwap` call back to ourselves
        // This opens us up for re-entrancy attacks
        // So if we detect we are calling ourselves, we return early and don't try to fulfill any orders
        if (addr == address(this)) {
            return TakeProfitsHook.afterSwap.selector;
        }

        bool attemptToFillMoreOrders = true;
        int24 currentTickLower;

        // While we have any possibility of having orders left to fulfill
        while (attemptToFillMoreOrders) {
            // Try fulfilling orders
            (attemptToFillMoreOrders, currentTickLower) = _tryFulfillingOrders(
                key,
                params
            );
            // Update `tickLowerLasts` to have the value of `currentTickLower` after the last iteration
            tickLowerLasts[key.toId()] = currentTickLower;
        }

        return TakeProfitsHook.afterSwap.selector;
    }

    function redeem(
        uint256 tokenId,
        uint256 amountIn,
        address destination
    ) external {
        // Make sure there is something to claim
        require(
            tokenIdClaimable[tokenId] > 0,
            "TakeProfitsHook: No tokens to redeem"
        );

        // Make sure user has enough ERC-1155 tokens to redeem the amount they're requesting
        uint256 balance = balanceOf(msg.sender, tokenId);
        require(
            balance >= amountIn,
            "TakeProfitsHook: Not enough ERC-1155 tokens to redeem requested amount"
        );

        TokenData memory data = tokenIdData[tokenId];
        Currency tokenToSend = data.zeroForOne
            ? data.poolKey.currency1
            : data.poolKey.currency0;

        // multiple people could have added tokens to the same order, so we need to calculate the amount to send
        // total supply = total amount of tokens that were part of the order to be sold
        // therefore, user's share = (amountIn / total supply)
        // therefore, amount to send to user = (user's share * total claimable)

        // amountToSend = amountIn * (total claimable / total supply)
        // We use FixedPointMathLib.mulDivDown to avoid rounding errors
        uint256 amountToSend = amountIn.mulDivDown(
            tokenIdClaimable[tokenId],
            tokenIdTotalSupply[tokenId]
        );

        tokenIdClaimable[tokenId] -= amountToSend;
        tokenIdTotalSupply[tokenId] -= amountIn;
        _burn(msg.sender, tokenId, amountIn);

        tokenToSend.transfer(destination, amountToSend);
    }
}
