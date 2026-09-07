// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AdapterImplementation} from "../../src/AdapterImplementation.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockDelegateRegistry} from "../mocks/MockDelegateRegistry.sol";

contract SimpleOwnable2 {
    address public owner;

    constructor(address o) {
        owner = o;
    }
}

/// SdR3 #2 — OwnableWalletWideDelegate. CONTRACT_OWNABLE consults `checkDelegateForContract`
/// (`_isOwnerDelegate`, :872-879), which by delegate.xyz v2 semantics folds in a whole-WALLET (ALL)
/// grant. So an owner's unrelated wallet-wide delegation confers CONTRACT_OWNABLE control.
/// NOT one of the prior 40: R1 #6 is the ACCOUNT route via `checkDelegateForAll`; this is the
/// distinct CONTRACT_OWNABLE route via `checkDelegateForContract` folding an ALL grant, and the
/// control leg proves a token-scoped grant does NOT confer contract authority.
contract SdR3_2_OwnableWalletWideDelegate is Test {
    MockIdentityRegistry internal registry;
    AdapterImplementation internal adapter;
    MockDelegateRegistry internal delegateRegistry;
    SimpleOwnable2 internal boundContract;

    address internal admin = makeAddr("admin");
    address internal contractOwner = makeAddr("contractOwner");
    address internal delegate = makeAddr("delegate");

    function setUp() external {
        registry = new MockIdentityRegistry();
        AdapterImplementation impl = new AdapterImplementation(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(AdapterImplementation.initialize, (admin)));
        adapter = AdapterImplementation(address(proxy));

        MockDelegateRegistry mockImpl = new MockDelegateRegistry();
        vm.etch(adapter.DELEGATE_REGISTRY(), address(mockImpl).code);
        delegateRegistry = MockDelegateRegistry(adapter.DELEGATE_REGISTRY());

        boundContract = new SimpleOwnable2(contractOwner);
    }

    /// Success condition: a wallet-wide `delegateAll(rights=0)` from the owner grants CONTRACT_OWNABLE
    /// control, while a token-scoped grant does not.
    function test_walletWideGrantConfersContractOwnableControl() external {
        vm.prank(contractOwner);
        uint256 agentId = adapter.register(IERC8217.Standard.CONTRACT_OWNABLE, address(boundContract), 0, "ipfs://a");

        delegateRegistry.delegateAll(delegate, contractOwner, bytes32(0), true);
        assertTrue(adapter.isController(agentId, delegate), "wallet-wide ALL grant folds into the contract check");

        // Control: a token-scoped grant is ignored by checkDelegateForContract.
        address tokenDelegate = makeAddr("tokenDelegate");
        delegateRegistry.delegateERC721(tokenDelegate, contractOwner, address(boundContract), 0, bytes32(0), true);
        assertFalse(adapter.isController(agentId, tokenDelegate), "token-scoped grant is not contract authority");
    }
}
