// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../../src/Adapter8004.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";

/// R1 #13 hashed interoperableAddress of the adapter. This is chainIdentifier vs address(0) envelope.
contract GrokR2_20_ChainVsAddressEnvelope is Test {
    /// Success condition: chainIdentifier() equals interoperableAddress(address(0)), so a chain
    /// envelope can be substituted for an account envelope in a UBID preimage.
    function test_defense_chainIdentifierIsNotTheZeroAddressEnvelope() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        Adapter8004 adapter = Adapter8004(
            address(
                new ERC1967Proxy(
                    address(new Adapter8004(address(registry))),
                    abi.encodeCall(Adapter8004.initialize, (makeAddr("admin")))
                )
            )
        );
        bytes memory chain = adapter.chainIdentifier();
        bytes memory zeroAddr = adapter.interoperableAddress(address(0));
        bytes memory adapterAddr = adapter.interoperableAddress(address(adapter));
        assertTrue(keccak256(chain) != keccak256(zeroAddr), "address-length byte distinguishes the shapes");
        assertTrue(keccak256(chain) != keccak256(adapterAddr));
        assertTrue(keccak256(zeroAddr) != keccak256(adapterAddr));
        assertTrue(chain.length != zeroAddr.length);
    }
}
