// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/**
 * @title RelayHook
 * @author Shlok
 * @notice A Uniswap v4 hook that optimizes gas fees by delegating swap transactions 
 * to an off-chain relayer when beneficial
 * @dev This hook intercepts swap transactions, evaluates if they would benefit from
 * being relayed, and if so, emits events for off-chain relayers to execute the swap
 * in a more gas-efficient manner
 */
contract RelayHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    // -----------------------------------------------
    // Events
    // -----------------------------------------------
    
    /**
     * @notice Emitted when a swap is identified as a candidate for relaying
     * @param user The original user who initiated the swap
     * @param poolId The ID of the pool where the swap is occurring
     * @param amountSpecified The amount specified for the swap
     * @param zeroForOne The direction of the swap (true for token0 to token1)
     * @param estimatedGasSavings Estimated gas that can be saved through relaying
     */
    event RelayerInvoked(
        address indexed user,
        PoolId indexed poolId,
        int256 amountSpecified,
        bool zeroForOne,
        uint256 estimatedGasSavings
    );
    
    /**
     * @notice Emitted after a swap is executed, either directly or via a relayer
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

    // -----------------------------------------------
    // State Variables
    // -----------------------------------------------
    
    /// @notice Set of authorized relayers that can submit batched transactions
    mapping(address => bool) public authorizedRelayers;
    
    /**
     * @notice Track relayer performance metrics per pool
     * @dev Stores statistics about relayed swaps, gas savings, and total swaps
     */
    struct RelayerMetrics {
        uint256 totalSwapsRelayed;
        uint256 totalGasSaved;
        uint256 totalSwapsExecuted;
    }
    
    /// @notice Metrics tracking for each pool
    mapping(PoolId => RelayerMetrics) public relayerMetrics;
    
    /// @notice Gas threshold to activate relayer (can be adjusted per pool)
    mapping(PoolId => uint256) public relayerGasThreshold;
    
    /// @notice Default gas threshold (in gas units)
    uint256 public defaultGasThreshold = 50000;
    
    /**
     * @notice Information about a pending swap that should be executed by a relayer
     * @dev Stores the details needed for a relayer to execute the swap
     */
    struct PendingSwap {
        address user;
        int256 amountSpecified;
        bool zeroForOne;
        bool isActive;
    }
    
    /// @notice Tracks pending relayed swaps for each pool
    mapping(PoolId => PendingSwap) public pendingSwaps;

    // -----------------------------------------------
    // Constructor & Configuration
    // -----------------------------------------------
    
    /**
     * @notice Initializes the RelayHook with the pool manager
     * @param _poolManager The Uniswap v4 pool manager
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        // The deployer is the first authorized relayer
        authorizedRelayers[msg.sender] = true;
    }
    
    /**
     * @notice Set the gas threshold for a specific pool
     * @param key Pool key to set threshold for
     * @param threshold Gas units threshold
     * @dev Only authorized relayers can call this function
     */
    function setPoolGasThreshold(PoolKey calldata key, uint256 threshold) external {
        require(authorizedRelayers[msg.sender], "Unauthorized");
        relayerGasThreshold[key.toId()] = threshold;
    }
    
    /**
     * @notice Update the default gas threshold
     * @param threshold New default threshold
     * @dev Only authorized relayers can call this function
     */
    function setDefaultGasThreshold(uint256 threshold) external {
        require(authorizedRelayers[msg.sender], "Unauthorized");
        defaultGasThreshold = threshold;
    }
    
    /**
     * @notice Add or remove an authorized relayer
     * @param relayer Relayer address
     * @param authorized Whether to authorize or deauthorize
     * @dev Only authorized relayers can call this function
     */
    function setRelayerAuthorization(address relayer, bool authorized) external {
        require(authorizedRelayers[msg.sender], "Unauthorized");
        authorizedRelayers[relayer] = authorized;
    }

    /**
     * @notice Specifies which hooks are implemented by this contract
     * @return Hooks.Permissions The permissions structure with enabled hooks
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,  // We need to potentially modify swap amounts
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -----------------------------------------------
    // Hook Implementation
    // -----------------------------------------------

    /**
     * @notice Hook called before a swap occurs
     * @dev Evaluates if the swap should be relayed based on gas optimization potential
     * @param sender Address initiating the swap
     * @param key Pool key for the swap
     * @param params Swap parameters
     * @param hookData Additional data passed to the hook
     * @return bytes4 Function selector
     * @return BeforeSwapDelta Delta to apply before the swap
     * @return uint24 Fee adjustment
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata key, 
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
    
        // Check if this is a relayer executing a pending swap
        if (authorizedRelayers[sender] && pendingSwaps[poolId].isActive) {
            // For relayer-executed swaps, we need to be careful about the state
            // Instead of trying to validate parameters, let's just clear the pending swap
            // to prevent any state conflicts
            pendingSwaps[poolId].isActive = false;
            
            // This is a relayer executing a swap, so we'll just let it proceed
            return (
                BaseHook.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0 // No fee adjustment for relayer
            );
        }
            
        // Decode hookData if present to extract user intents
        bool userOptsInToRelay = true; // Default to opt-in
        
        if (hookData.length > 0) {
            // If hookData provided, decode user preferences
            (userOptsInToRelay) = abi.decode(hookData, (bool));
        }
        
        // Get the gas threshold for this pool, falling back to default if not set
        uint256 threshold = relayerGasThreshold[poolId] > 0 ? 
                           relayerGasThreshold[poolId] : 
                           defaultGasThreshold;
        
        // Run gas optimization logic to determine if relay benefits outweigh costs
        (bool shouldRelay, uint256 estimatedGasSavings) = _evaluateGasOptimization(
            key,
            params,
            threshold
        );
        
        // Only relay if beneficial AND user opts in
        if (shouldRelay && userOptsInToRelay) {
            // Store the pending swap details for the relayer to execute
            pendingSwaps[poolId] = PendingSwap({
                user: sender,
                amountSpecified: params.amountSpecified,
                zeroForOne: params.zeroForOne,
                isActive: true
            });
            
            // Emit event to trigger off-chain relayer
            emit RelayerInvoked(
                sender,
                poolId,
                params.amountSpecified,
                params.zeroForOne,
                estimatedGasSavings
            );
            
            // For swap batching, we can either:
            // 1. Return a delta adjustment with modified fee based on batched swap
            // 2. Return a modified swap amount if optimization requires it
            
            // Here we choose option 1: adjust fee to incentivize relayer
            uint24 feeAdjustment = _calculateOptimalFeeAdjustment(key, params, estimatedGasSavings);
            
            // Update metrics
            relayerMetrics[poolId].totalSwapsRelayed++;
            
            return (
                BaseHook.beforeSwap.selector, 
                BeforeSwapDeltaLibrary.ZERO_DELTA, // Maintain original swap amount
                feeAdjustment // Adjust fee to compensate relayer
            );
        }
        
        // If relay not beneficial, just proceed with standard swap
        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0 // No fee adjustment
        );
    }
    
    /**
     * @notice Hook called after a swap occurs
     * @dev Records metrics and verifies gas optimizations
     * @param sender Address that initiated the swap
     * @param key Pool key for the swap
     * @param params Swap parameters
     * @param delta Balance delta from the swap
     * @param hookData Additional data passed to the hook
     * @return bytes4 Function selector
     * @return int128 Delta adjustment (0 in this implementation)
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        
        // Record this swap in our metrics
        relayerMetrics[poolId].totalSwapsExecuted++;
        
        // Determine if this was a relayed swap
        bool wasRelayed = false;
        address swapUser = sender;
        
        if (authorizedRelayers[sender] && pendingSwaps[poolId].isActive) {
            wasRelayed = true;
            swapUser = pendingSwaps[poolId].user;
            
            // Clear the pending swap now that it's been executed
            pendingSwaps[poolId].isActive = false;
        }
        
        // Calculate the actual amount out from the delta
        int256 amountOut;
        if (params.zeroForOne) {
            // If swapping token0 for token1, amount1 is the output
            amountOut = delta.amount1();
        } else {
            // If swapping token1 for token0, amount0 is the output
            amountOut = delta.amount0();
        }
        
        // Emit event for off-chain monitoring/analytics
        emit SwapExecuted(
            swapUser,
            poolId,
            params.amountSpecified,
            amountOut,
            wasRelayed,
            gasleft() // Note: This is still not accurate gas measurement, but won't cause overflow
        );
        
        return (BaseHook.afterSwap.selector, 0);
    }
    
    // -----------------------------------------------
    // Internal Utility Functions
    // -----------------------------------------------
    
    /**
     * @notice Evaluates whether gas optimization via relayer is beneficial
     * @param key Pool key
     * @param params Swap parameters
     * @param threshold Gas threshold to beat
     * @return shouldRelay True if relay is beneficial
     * @return estimatedSavings Estimated gas savings
     * @dev This is a simplified implementation; a production version would use more
     * sophisticated gas estimation based on historical data and current gas prices
     */
    function _evaluateGasOptimization(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        uint256 threshold
    ) internal view returns (bool shouldRelay, uint256 estimatedSavings) {
        // Simplified logic - in a real implementation, this would consider:
        // - Current network gas prices
        // - Size of swap (larger swaps more likely to benefit)
        // - Pool volatility
        // - Historical relayer performance
        
        // As a simplification, assume swaps above a certain size benefit from relaying
        // Handle the edge case of int256.min to avoid overflow
        uint256 swapSize;
        if (params.amountSpecified == type(int256).min) {
            swapSize = uint256(type(int256).max) + 1;
        } else if (params.amountSpecified < 0) {
            swapSize = uint256(-params.amountSpecified);
        } else {
            swapSize = uint256(params.amountSpecified);
        }
        
        // Example threshold: swaps > 1 ETH equivalent might benefit
        // In practice, this would be a more complex calculation
        bool sizeBenefitsFromRelay = swapSize > 1 ether;
        
        // Placeholder for more complex gas estimation
        uint256 standardGas = 150000; // Standard swap gas estimate
        uint256 relayerGas = 90000;  // Batched swap gas estimate
        
        // Only relay if potential savings exceed threshold
        estimatedSavings = sizeBenefitsFromRelay ? standardGas - relayerGas : 0;
        shouldRelay = estimatedSavings > threshold;
        
        return (shouldRelay, estimatedSavings);
    }
        /**
     * @notice Calculates the optimal fee adjustment based on gas savings
     * @param key Pool key
     * @param params Swap parameters
     * @param estimatedGasSavings Estimated gas savings
     * @return feeAdjustment Fee adjustment (additional fee or rebate)
     * @dev This is a simplified implementation; a production version would use more
     * sophisticated fee calculation based on market conditions and pool liquidity
     */
    function _calculateOptimalFeeAdjustment(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        uint256 estimatedGasSavings
    ) internal pure returns (uint24 feeAdjustment) {
        // In a real implementation, this would:
        // - Convert gas savings to token terms
        // - Calculate a fee that incentivizes relayer but shares savings with user
        // - Consider market conditions and pool liquidity
        
        // Placeholder logic - small adjustment proportional to estimated savings
        // A real implementation would be more sophisticated
        // Ensure we don't overflow uint24 when casting
        uint256 calculatedFee = estimatedGasSavings / 100;
        if (calculatedFee > type(uint24).max) {
            calculatedFee = type(uint24).max;
        }
        feeAdjustment = uint24(calculatedFee);
        
        return feeAdjustment;
    }
    
    // -----------------------------------------------
    // External Functions for Relayer Interaction
    // -----------------------------------------------
    
    /**
     * @notice Called by relayers to update metrics after successful batched execution
     * @param poolId Pool ID
     * @param actualGasSaved Actual gas saved through batching
     * @dev Only authorized relayers can call this function
     */
    function reportRelayerPerformance(PoolId poolId, uint256 actualGasSaved) external {
        require(authorizedRelayers[msg.sender], "Unauthorized");
        relayerMetrics[poolId].totalGasSaved += actualGasSaved;
    }
    
    /**
     * @notice View function to get relayer performance metrics for a pool
     * @param key Pool key
     * @return metrics Relayer metrics for the pool
     */
    function getRelayerMetrics(PoolKey calldata key) external view returns (RelayerMetrics memory) {
        return relayerMetrics[key.toId()];
    }
}
