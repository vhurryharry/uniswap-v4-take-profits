// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Foundry libraries
import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

// Our contracts
import {TakeProfitsHook} from "../src/TakeProfitsHook.sol";
import {TakeProfitsStub} from "../src/TakeProfitsStub.sol";

contract TakeProfitsHookTest is Test, Deployers {
    // Use the libraries
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // The two currencies (tokens) from the pool
    Currency tokenOne;
    Currency tokenTwo;

    // Hardcode the address for our hook instead of deploying it
    // We will overwrite the storage to replace code at this address with code from the stub
    TakeProfitsHook hook =
        TakeProfitsHook(
            address(
                uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)
            )
        );

    function _stubValidateHookAddress() private {
        // Deploy the stub contract
        TakeProfitsStub stub = new TakeProfitsStub(manager, hook);

        // Fetch all the storage slot writes that have been done at the stub address
        // during deployment
        (, bytes32[] memory writes) = vm.accesses(address(stub));

        // Etch the code of the stub at the hardcoded hook address
        vm.etch(address(hook), address(stub).code);

        // Replay the storage slot writes at the hook address
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(hook), slot, vm.load(address(stub), slot));
            }
        }
    }

    function setUp() public {
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();

        // Deploy two test tokens
        (tokenOne, tokenTwo) = deployMintAndApprove2Currencies();

        // Approve our hook address to spend these tokens as well
        MockERC20(Currency.unwrap(tokenOne)).approve(
            address(hook),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(tokenTwo)).approve(
            address(hook),
            type(uint256).max
        );

        // Stub our hook and add code to our hardcoded address
        _stubValidateHookAddress();

        // Initialize a pool with these two tokens
        (key, ) = initPool(tokenOne, tokenTwo, hook, 3000, SQRT_PRICE_1_1);

        // Add initial liquidity to the pool

        // Some liquidity from -60 to +60 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: 0
            }),
            ZERO_BYTES
        );
        // Some liquidity from -120 to +120 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: 0
            }),
            ZERO_BYTES
        );
        // some liquidity for full range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: 0
            }),
            ZERO_BYTES
        );
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return
            bytes4(
                keccak256(
                    "onERC1155Received(address, address, uint256, uint256, bytes)"
                )
            );
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return
            bytes4(
                keccak256(
                    "onERC1155BatchReceived(address, address, uint256[], uint256[], bytes)"
                )
            );
    }

    function test_placeOrder() public {
        // Place a zeroForOne take-profit order
        // for 10e18 token0 tokens
        // at tick 100

        int24 tick = 100;
        uint256 amount = 10 ether;
        bool zeroForOne = true;

        // Note the original balance of token0 we have
        uint256 originalBalance = tokenOne.balanceOfSelf();

        // Place the order
        int24 tickLower = hook.placeOrder(key, tick, amount, zeroForOne);

        // Note the new balance of token0 we have
        uint256 newBalance = tokenOne.balanceOfSelf();

        // Since we deployed the pool contract with tick spacing = 60
        // i.e. the tick can only be a multiple of 60
        // and initially the tick is 0
        // the tickLower should be 60 since we placed an order at tick 100
        assertEq(tickLower, 60);

        // Ensure that our balance was reduced by `amount` tokens
        assertEq(originalBalance - newBalance, amount);

        // Check the balance of ERC-1155 tokens we received
        uint256 tokenId = hook.getTokenId(key, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), tokenId);

        // Ensure that we were, in fact, given ERC-1155 tokens for the order
        // equal to the `amount` of token0 tokens we placed the order for
        assertTrue(tokenId != 0);
        assertEq(tokenBalance, amount);
    }

    function test_cancelOrder() public {
        // Place an order similar as earlier, but cancel it later
        int24 tick = 100;
        uint256 amount = 10 ether;
        bool zeroForOne = true;

        uint256 originalBalance = tokenOne.balanceOfSelf();

        int24 tickLower = hook.placeOrder(key, tick, amount, zeroForOne);

        uint256 newBalance = tokenOne.balanceOfSelf();

        assertEq(tickLower, 60);
        assertEq(originalBalance - newBalance, amount);

        // Check the balance of ERC-1155 tokens we received
        uint256 tokenId = hook.getTokenId(key, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), tokenId);
        assertEq(tokenBalance, amount);

        // Cancel the order
        hook.cancelOrder(key, tickLower, zeroForOne);

        // Check that we received our token0 tokens back, and no longer own any ERC-1155 tokens
        uint256 finalBalance = tokenOne.balanceOfSelf();
        assertEq(finalBalance, originalBalance);

        tokenBalance = hook.balanceOf(address(this), tokenId);
        assertEq(tokenBalance, 0);
    }

    function test_orderExecute_zeroForOne() public {
        int24 tick = 100;
        uint256 amount = 10 ether;
        bool zeroForOne = true;

        // Place our order at tick 100 for 10e18 token0 tokens
        int24 tickLower = hook.placeOrder(key, tick, amount, zeroForOne);

        // Do a separate swap from oneForZero to make tick go up
        // Sell 1e18 token1 tokens for token0 tokens
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: true, settleUsingBurn: true});

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // Check that the order has been executed
        int256 tokensLeftToSell = hook.takeProfitPositions(
            key.toId(),
            tick,
            zeroForOne
        );
        assertEq(tokensLeftToSell, 0);

        // Check that the hook contract has the expected number of token1 tokens ready to redeem
        uint256 tokenId = hook.getTokenId(key, tickLower, zeroForOne);
        uint256 claimableTokens = hook.tokenIdClaimable(tokenId);
        uint256 hookContractToken1Balance = tokenTwo.balanceOf(address(hook));
        assertEq(claimableTokens, hookContractToken1Balance);

        // Ensure we can redeem the token1 tokens
        uint256 originalToken1Balance = tokenTwo.balanceOf(address(this));
        hook.redeem(tokenId, amount, address(this));
        uint256 newToken1Balance = tokenTwo.balanceOf(address(this));

        assertEq(newToken1Balance - originalToken1Balance, claimableTokens);
    }

    function test_orderExecute_oneForZero() public {
        int24 tick = -100;
        uint256 amount = 10 ether;
        bool zeroForOne = false;

        // Place our order at tick -100 for 10e18 token1 tokens
        int24 tickLower = hook.placeOrder(key, tick, amount, zeroForOne);

        // Do a separate swap from zeroForOne to make tick go down
        // Sell 1e18 token0 tokens for token1 tokens
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: true, settleUsingBurn: true});

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // Check that the order has been executed
        int256 tokensLeftToSell = hook.takeProfitPositions(
            key.toId(),
            tick,
            zeroForOne
        );
        assertEq(tokensLeftToSell, 0);

        // Check that the hook contract has the expected number of token0 tokens ready to redeem
        uint256 tokenId = hook.getTokenId(key, tickLower, zeroForOne);
        uint256 claimableTokens = hook.tokenIdClaimable(tokenId);
        uint256 hookContractToken0Balance = tokenOne.balanceOf(address(hook));
        assertEq(claimableTokens, hookContractToken0Balance);

        // Ensure we can redeem the token0 tokens
        uint256 originalToken0Balance = tokenOne.balanceOfSelf();
        hook.redeem(tokenId, amount, address(this));
        uint256 newToken0Balance = tokenOne.balanceOfSelf();

        assertEq(newToken0Balance - originalToken0Balance, claimableTokens);
    }

    function test_multiple_orderExecute_zeroForOne() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: true, settleUsingBurn: true});

        // Setup two zeroForOne orders at ticks 0 and 60
        uint256 amount = 1 ether;

        hook.placeOrder(key, 0, amount, true);
        hook.placeOrder(key, 60, amount, true);

        // Do a swap to make tick increase to 120
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -0.5 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // Only one order should have been executed
        // because the execution of that order would lower the tick
        // so even though tick increased to 120
        // the first order execution will lower it back down
        // so order at tick = 60 will not be executed
        int256 tokensLeftToSell = hook.takeProfitPositions(key.toId(), 0, true);
        assertEq(tokensLeftToSell, 0);

        // Order at Tick 60 should still be pending
        tokensLeftToSell = hook.takeProfitPositions(key.toId(), 60, true);
        assertEq(tokensLeftToSell, int(amount));
    }
}
