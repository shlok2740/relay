// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {RelayHook} from "../src/RelayHook.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

/**
 * @title RelayHookTest
 * @author Shlok
 * @notice Test contract for the RelayHook implementation
 * @dev Tests the functionality of the RelayHook contract using Foundry's testing framework
 */
contract RelayHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /// @notice The RelayHook contract instance being tested
    RelayHook hook;
    
    /// @notice The ID of the test pool
    PoolId poolId;

    /// @notice Token ID for the liquidity position
    uint256 tokenId;
    
    /// @notice Lower tick boundary for the liquidity position
    int24 tickLower;
    
    /// @notice Upper tick boundary for the liquidity position
    int24 tickUpper;

    // Test accounts
    /// @notice Deployer address (this contract)
    address public deployer = address(this);
    
    /// @notice Test user 1
    address public user1 = makeAddr("user1");
    
    /// @notice Test user 2
    address public user2 = makeAddr("user2");
    
    /// @notice Test relayer 1
    address public relayer1 = makeAddr("relayer1");
    
    /// @notice Test relayer 2
    address public relayer2 = makeAddr("relayer2");

    // Test constants
    /// @notice Amount for large swaps (10 ETH)
    uint256 constant LARGE_SWAP_AMOUNT = 10 ether;
    
    /// @notice Amount for small swaps (0.1 ETH)
    uint256 constant SMALL_SWAP_AMOUNT = 0.1 ether;

    /**
     * @notice Event emitted when a relayer is invoked
     * @param user The original user who initiated the swap
     * @param poolId The ID of the pool where the swap is occurring
     * @param amountSpecified The amount specified for the swap
     * @param zeroForOne The direction of the swap
     * @param estimatedGasSavings Estimated gas savings
     */
    event RelayerInvoked(
        address indexed user,
        PoolId indexed poolId,
        int256 amountSpecified,
        bool zeroForOne,
        uint256 estimatedGasSavings
    );
    
    /**
     * @notice Event emitted after a swap is executed
     * @param user The original user who initiated the swap
     * @param poolId The ID of the pool where the swap occurred
     * @param amountSpecified The amount specified for the swap
     * @param amountOut The amount received from the swap
     * @param wasRelayed Whether the swap was executed by a relayer
     * @param actualGasUsed The actual gas used for the swap execution
     */
    event SwapExecuted(
        address indexed user,
        PoolId indexed poolId,
        int256 amountSpecified,
        int256 amountOut,
        bool wasRelayed,
        uint256 actualGasUsed
    );

    /**
     * @notice Set up the test environment
     * @dev Creates a pool manager, deploys the hook, initializes a pool, and adds liquidity
     */
    function setUp() public {
        // Creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        deployAndApprovePosm(manager);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4445 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(manager);
        deployCodeTo("RelayHook.sol:RelayHook", constructorArgs, flags);
        hook = RelayHook(flags);

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint128 liquidityAmount = 1000e18; // Add substantial liquidity

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId,) = posm.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );

        // Fund test accounts
        deal(Currency.unwrap(currency0), user1, 100 ether);
        deal(Currency.unwrap(currency1), user1, 100 ether);
        vm.startPrank(user1);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);

        vm.stopPrank();

        deal(Currency.unwrap(currency0), user2, 100 ether);
        deal(Currency.unwrap(currency1), user2, 100 ether);
        vm.startPrank(user2);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Authorize a relayer
        hook.setRelayerAuthorization(relayer1, true);
    }

    /**
     * @notice Test that the hook permissions are set correctly
     * @dev Verifies that only the necessary hook flags are enabled
     */
    function testHookPermissions() public {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        
        // Verify hook permissions
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertTrue(permissions.beforeSwapReturnDelta);
        
        // Verify other flags are not set
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
    }

    /**
     * @notice Test setting the default gas threshold
     * @dev Verifies that an authorized user can update the default gas threshold
     */
    function testSetDefaultGasThreshold() public {
        uint256 newThreshold = 75000;
        
        // Initial value check
        assertEq(hook.defaultGasThreshold(), 50000); // Default value
        
        // Update threshold
        hook.setDefaultGasThreshold(newThreshold);
        
        // Verify updated value
        assertEq(hook.defaultGasThreshold(), newThreshold);
    }

    /**
     * @notice Test that unauthorized users cannot set the default gas threshold
     * @dev Verifies that the function reverts when called by an unauthorized user
     */
    function testSetDefaultGasThresholdUnauthorized() public {
        uint256 newThreshold = 75000;
        
        // Attempt to update as unauthorized user
        vm.startPrank(user1);
        vm.expectRevert("Unauthorized");
        hook.setDefaultGasThreshold(newThreshold);
        vm.stopPrank();
        
        // Verify value unchanged
        assertEq(hook.defaultGasThreshold(), 50000);
    }

    /**
     * @notice Test setting a pool-specific gas threshold
     * @dev Verifies that an authorized user can set a threshold for a specific pool
     */
    function testSetPoolGasThreshold() public {
        uint256 newThreshold = 60000;
        
        // Initial value check (should be 0/unset)
        assertEq(hook.relayerGasThreshold(poolId), 0);
        
        // Update pool-specific threshold
        hook.setPoolGasThreshold(key, newThreshold);
        
        // Verify updated value
        assertEq(hook.relayerGasThreshold(poolId), newThreshold);
    }
    
    /**
     * @notice Test relayer authorization functionality
     * @dev Verifies that relayers can be authorized and deauthorized
     */
    function testRelayerAuthorization() public {
        // Verify initial authorization state
        assertTrue(hook.authorizedRelayers(address(this)));
        assertTrue(hook.authorizedRelayers(relayer1));
        assertFalse(hook.authorizedRelayers(relayer2));
        
        // Authorize relayer2
        hook.setRelayerAuthorization(relayer2, true);
        assertTrue(hook.authorizedRelayers(relayer2));
        
        // Deauthorize relayer1
        hook.setRelayerAuthorization(relayer1, false);
        assertFalse(hook.authorizedRelayers(relayer1));
    }
    
    /**
     * @notice Test that unauthorized users cannot authorize relayers
     * @dev Verifies that the function reverts when called by an unauthorized user
     */
    function testRelayerAuthorizationUnauthorized() public {
        vm.startPrank(user1);
        vm.expectRevert("Unauthorized");
        hook.setRelayerAuthorization(user2, true);
        vm.stopPrank();
    }

/**
     * @notice Test that large swaps trigger the relay mechanism
     * @dev Verifies that the RelayerInvoked event is emitted for large swaps
     */
    function testLargeSwapTriggersRelay() public {
        // Prepare to capture emitted events
        vm.recordLogs();
        
        // Perform a large swap (expecting relay)
        bool zeroForOne = true;
        int256 amountSpecified = -int256(LARGE_SWAP_AMOUNT); // Exact input swap
        
        // Execute the swap
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        
        // Check for RelayerInvoked event
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool foundRelayerInvokedEvent = false;
        
        for (uint i = 0; i < entries.length; i++) {
            // RelayerInvoked event has this specific topic0
            if (entries[i].topics[0] == keccak256("RelayerInvoked(address,bytes32,int256,bool,uint256)")) {
                foundRelayerInvokedEvent = true;
                break;
            }
        }
        
        assertTrue(foundRelayerInvokedEvent, "RelayerInvoked event should be emitted for large swaps");
    }

    function testSmallSwapDoesNotTriggerRelay() public {
        // Prepare to capture emitted events
        vm.recordLogs();
        
        // Perform a small swap (not expecting relay)
        bool zeroForOne = true;
        int256 amountSpecified = -int256(SMALL_SWAP_AMOUNT); // Exact input swap
        
        // Execute the swap
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        
        // Check for RelayerInvoked event
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool foundRelayerInvokedEvent = false;
        
        for (uint i = 0; i < entries.length; i++) {
            // RelayerInvoked event has this specific topic0
            if (entries[i].topics[0] == keccak256("RelayerInvoked(address,bytes32,int256,bool,uint256)")) {
                foundRelayerInvokedEvent = true;
                break;
            }
        }
        
        assertFalse(foundRelayerInvokedEvent, "RelayerInvoked event should not be emitted for small swaps");
    }

    function testSwapWithOptOutHookData() public {
        // Prepare to capture emitted events
        vm.recordLogs();
        
        // Perform a large swap but opt out of relay
        bool zeroForOne = true;
        int256 amountSpecified = -int256(LARGE_SWAP_AMOUNT); // Exact input swap
        bytes memory hookData = abi.encode(false); // Opt out of relay
        
        // Execute the swap
        swap(key, zeroForOne, amountSpecified, hookData);
        
        // Check for RelayerInvoked event
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool foundRelayerInvokedEvent = false;
        
        for (uint i = 0; i < entries.length; i++) {
            // RelayerInvoked event has this specific topic0
            if (entries[i].topics[0] == keccak256("RelayerInvoked(address,bytes32,int256,bool,uint256)")) {
                foundRelayerInvokedEvent = true;
                break;
            }
        }
        
        assertFalse(foundRelayerInvokedEvent, "RelayerInvoked event should not be emitted when user opts out");
    }

    function testAfterSwapEvent() public {
        // Prepare to capture emitted events
        vm.recordLogs();
        
        // Perform a swap
        bool zeroForOne = true;
        int256 amountSpecified = -int256(SMALL_SWAP_AMOUNT);
        
        // Execute the swap
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        
        // Check for SwapExecuted event
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool foundSwapExecutedEvent = false;
        
        for (uint i = 0; i < entries.length; i++) {
            // SwapExecuted event has this specific topic0
            if (entries[i].topics[0] == keccak256("SwapExecuted(address,bytes32,int256,int256,bool,uint256)")) {
                foundSwapExecutedEvent = true;
                break;
            }
        }
        
        assertTrue(foundSwapExecutedEvent, "SwapExecuted event should be emitted after swap");
    }

    /**
     * @notice Test that relayer metrics are properly tracked
     * @dev Verifies that metrics are updated after swaps and relayer reports
     */
    function testRelayerMetricsTracking() public {
        // Initial metrics should be zero
        (uint256 swapsRelayed, uint256 gasSaved, uint256 swapsExecuted) = getMetrics();
        assertEq(swapsRelayed, 0);
        assertEq(gasSaved, 0);
        assertEq(swapsExecuted, 0);
        
        // Perform a large swap (should trigger relay)
        bool zeroForOne = true;
        int256 amountSpecified = -int256(LARGE_SWAP_AMOUNT);
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        
        // Check metrics after swap
        (swapsRelayed, gasSaved, swapsExecuted) = getMetrics();
        assertEq(swapsRelayed, 1, "Swaps relayed should increment");
        assertEq(gasSaved, 0, "Gas saved not updated yet"); // Relayer hasn't reported yet
        assertEq(swapsExecuted, 1, "Swaps executed should increment");
        
        // Simulate relayer reporting performance
        uint256 reportedGasSavings = 75000;
        hook.reportRelayerPerformance(poolId, reportedGasSavings);
        
        // Verify updated metrics
        (swapsRelayed, gasSaved, swapsExecuted) = getMetrics();
        assertEq(gasSaved, reportedGasSavings, "Gas saved should be updated after relayer report");
    }

    /**
     * @notice Test that unauthorized users cannot report relayer performance
     * @dev Verifies that the function reverts when called by an unauthorized user
     */
    function testReportRelayerPerformanceUnauthorized() public {
        vm.startPrank(user1);
        vm.expectRevert("Unauthorized");
        hook.reportRelayerPerformance(poolId, 50000);
        vm.stopPrank();
    }

    /**
     * @notice Test metrics tracking across multiple swaps
     * @dev Verifies that metrics are correctly updated for different types of swaps
     */
    function testMultipleSwapsMetrics() public {
        // Perform multiple swaps of different sizes
        
        // Swap 1: Large (should trigger relay)
        swap(key, true, -int256(LARGE_SWAP_AMOUNT), ZERO_BYTES);
        
        // Swap 2: Small (should not trigger relay)
        swap(key, false, -int256(SMALL_SWAP_AMOUNT), ZERO_BYTES);
        
        // Swap 3: Large (should trigger relay)
        swap(key, true, -int256(LARGE_SWAP_AMOUNT), ZERO_BYTES);
        
        // Check final metrics
        (uint256 swapsRelayed, uint256 gasSaved, uint256 swapsExecuted) = getMetrics();
        assertEq(swapsRelayed, 2, "Should have 2 relayed swaps");
        assertEq(swapsExecuted, 3, "Should have 3 total swaps");
    }

    /**
     * @notice Test the full relay flow with a relayer executing a swap
     * @dev Simulates a user initiating a swap that gets relayed, and a relayer executing it
     */
    function testRelayerSwapExecution() public {
        // This test simulates the full relay flow
        
        // 1. First perform a large swap that triggers relay
        vm.recordLogs();
        bool zeroForOne = true;
        int256 amountSpecified = -int256(LARGE_SWAP_AMOUNT);
        
        // Execute the swap but expect it to be relayed (not actually executed)
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        
        // 2. Fund the relayer account before it tries to execute the swap
        deal(Currency.unwrap(currency0), relayer1, LARGE_SWAP_AMOUNT);
        deal(Currency.unwrap(currency1), relayer1, LARGE_SWAP_AMOUNT);
        
        // Approve the tokens for the swap router
        vm.startPrank(relayer1);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        
        // Now the relayer should have enough tokens to execute the swap
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        
        // Relayer reports gas savings
        uint256 reportedGasSavings = 60000;
        hook.reportRelayerPerformance(poolId, reportedGasSavings);
        
        vm.stopPrank();
        
        // 3. Check metrics reflect both swaps and reported gas savings
        (uint256 swapsRelayed, uint256 gasSaved, uint256 swapsExecuted) = getMetrics();
        assertEq(swapsRelayed, 2);
        assertEq(gasSaved, reportedGasSavings);
        assertEq(swapsExecuted, 2);
    }

    /**
     * @notice Helper function to extract metrics for easier reading
     * @return swapsRelayed Number of swaps that were relayed
     * @return gasSaved Total gas saved through relaying
     * @return swapsExecuted Total number of swaps executed
     */
    function getMetrics() internal view returns (uint256 swapsRelayed, uint256 gasSaved, uint256 swapsExecuted) {
        RelayHook.RelayerMetrics memory metrics = hook.getRelayerMetrics(key);
        return (metrics.totalSwapsRelayed, metrics.totalGasSaved, metrics.totalSwapsExecuted);
    }
}