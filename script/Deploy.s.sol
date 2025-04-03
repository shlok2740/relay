// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {Constants} from "./base/Constants.sol";
import {RelayHook} from "../src/RelayHook.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

/// @notice Script to deploy RelayHook, PoolManager, and a swap router
contract DeployScript is Script, Constants {
    function setUp() public {}

    function run() public {
        // First deploy the PoolManager
        vm.startBroadcast();
        PoolManager poolManager = new PoolManager(msg.sender);
        console.log("PoolManager deployed at:", address(poolManager));
        

        // Deploy a swap router that uses the PoolManager
        // Using PoolSwapTest as a concrete implementation for testing
       
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        console.log("SwapRouter deployed at:", address(swapRouter));
        

        // Hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(address(poolManager));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(RelayHook).creationCode, constructorArgs);

        // Deploy the RelayHook using CREATE2
        
        // Deploy with the EOA as the sender
        RelayHook relayHook = new RelayHook{salt: salt}(IPoolManager(address(poolManager)));
        require(address(relayHook) == hookAddress, "DeployScript: hook address mismatch");
        console.log("RelayHook deployed at:", address(relayHook));
        
        // Now the EOA is authorized to call setDefaultGasThreshold
        
        
        // Add any additional authorized relayers if needed
        relayHook.setRelayerAuthorization(address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266), true);

        relayHook.setDefaultGasThreshold(5000000);
        
        vm.stopBroadcast();
        
        // Output deployment information for easy reference
        console.log("Deployment Summary:");
        console.log("-------------------");
        console.log("PoolManager: ", address(poolManager));
        console.log("SwapRouter: ", address(swapRouter));
        console.log("RelayHook: ", address(relayHook));
        console.log("-------------------");
        console.log("Next steps:");
        console.log("1. Create pools using the PoolManager");
        console.log("2. Add liquidity to the pools");
        console.log("3. Configure RelayHook gas thresholds for specific pools");
    }
}


// used anvil to get 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266