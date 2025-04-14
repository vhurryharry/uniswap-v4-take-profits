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
        TakeProfitsStub stub = new TakeProfitsStub(poolManager, hook);

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
        (key, ) = initPool(
            tokenOne,
            tokenTwo,
            hook,
            3000,
            SQRT_RATIO_1_1,
            ZERO_BYTES
        );

        // Add initial liquidity to the pool

        // Some liquidity from -60 to +60 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether
            }),
            ZERO_BYTES
        );
        // Some liquidity from -120 to +120 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether
            }),
            ZERO_BYTES
        );
        // some liquidity for full range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether
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
}
