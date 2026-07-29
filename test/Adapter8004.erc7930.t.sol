// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";

contract Adapter8004HashHarness is Adapter8004 {
    function chainIdentifierFor(uint256 chainId) external pure returns (bytes memory) {
        return _chainIdentifierFor(chainId);
    }

    function interoperableAddressFor(uint256 chainId, address account) external pure returns (bytes memory) {
        return _interoperableAddressFor(chainId, account);
    }

    function registrationHashFor(bytes memory adapterInteroperableAddress, address tokenContract, uint256 tokenId)
        external
        pure
        returns (bytes32)
    {
        return _registrationHashFor(adapterInteroperableAddress, tokenContract, tokenId);
    }
}

contract Adapter8004ERC7930Test is Test {
    Adapter8004 internal adapter;
    Adapter8004HashHarness internal harness;
    address internal constant VECTOR_ADAPTER = 0x1111111111111111111111111111111111111111;
    address internal constant VECTOR_TOKEN = 0x2222222222222222222222222222222222222222;

    function setUp() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        Adapter8004 implementation = new Adapter8004();
        adapter = Adapter8004(
            address(
                new ERC1967Proxy(
                    address(implementation), abi.encodeCall(Adapter8004.initialize, (address(registry), address(this)))
                )
            )
        );
        harness = new Adapter8004HashHarness();
    }

    function testPublishedCrossNamespaceVectors() external view {
        _assertVector(
            hex"000100000101141111111111111111111111111111111111111111",
            0x7f28a61447dba6ca306a9b3c0af2184fb625679ab3da0c8469cf04734670875e
        );
        _assertVector(
            hex"00010000022105141111111111111111111111111111111111111111",
            0xd4f7e7c3e75d4d9c011d61c33666c7ba460bcb0a5964112643a31802fbf0791f
        );
        _assertVector(
            hex"0001000003aa36a7141111111111111111111111111111111111111111",
            0xbd88f093e45b0adc6546b1363d8f876ac71cf52737abea2803edb5f938baeca5
        );
        _assertVector(
            hex"000100022045296998a6f8e2a784db5d9f95e18fc23f70441a1039446801089879b08c7ef0141111111111111111111111111111111111111111",
            0xa992e5d61c04f1741eccdd005ea76b2584ec995dd010df8c3303afc4270614cc
        );
    }

    function testLocalKnownChainIdentifiers() external {
        vm.chainId(1);
        assertEq(adapter.chainIdentifier(), hex"00010000010100");
        vm.chainId(8453);
        assertEq(adapter.chainIdentifier(), hex"0001000002210500");
        vm.chainId(11155111);
        assertEq(adapter.chainIdentifier(), hex"0001000003aa36a700");
    }

    function testLocalKnownInteroperableAddresses() external {
        vm.chainId(1);
        assertEq(
            adapter.interoperableAddress(VECTOR_ADAPTER), hex"000100000101141111111111111111111111111111111111111111"
        );
        vm.chainId(8453);
        assertEq(
            adapter.interoperableAddress(VECTOR_TOKEN), hex"00010000022105142222222222222222222222222222222222222222"
        );
    }

    function testFuzzMinimalBigEndianIdentifier(uint256 chainId) external {
        vm.assume(chainId != 0);
        bytes memory identifier = harness.chainIdentifierFor(chainId);
        uint256 referenceLength = identifier.length - 6;
        assertGe(referenceLength, 1);
        assertLe(referenceLength, 32);
        assertEq(uint8(identifier[0]), 0);
        assertEq(uint8(identifier[1]), 1);
        assertEq(uint8(identifier[2]), 0);
        assertEq(uint8(identifier[3]), 0);
        assertEq(uint8(identifier[4]), referenceLength);
        assertTrue(identifier[5] != 0);
        assertEq(uint8(identifier[identifier.length - 1]), 0);

        uint256 decoded;
        for (uint256 i; i < referenceLength; ++i) {
            decoded = (decoded << 8) | uint8(identifier[5 + i]);
        }
        assertEq(decoded, chainId);
    }

    function testFuzzInteroperableAddressAppendsLengthAndRawAddress(uint256 chainId, address account) external {
        vm.assume(chainId != 0);
        bytes memory identifier = harness.chainIdentifierFor(chainId);
        bytes memory interoperable = harness.interoperableAddressFor(chainId, account);
        assertEq(interoperable.length, identifier.length + 20);
        for (uint256 i; i < identifier.length - 1; ++i) {
            assertEq(uint8(interoperable[i]), uint8(identifier[i]));
        }
        assertEq(uint8(interoperable[identifier.length - 1]), 20);
        bytes20 rawAddress = bytes20(account);
        for (uint256 i; i < 20; ++i) {
            assertEq(uint8(interoperable[identifier.length + i]), uint8(rawAddress[i]));
        }
    }

    function testChainIdZeroRejected() external {
        vm.chainId(0);
        vm.expectRevert(Adapter8004.InvalidChainId.selector);
        adapter.chainIdentifier();
    }

    function testCanonicalFormulaAndNegativeEncodings() external view {
        address token = address(0xCAFE);
        uint256 tokenId = 99;
        bytes memory identifier = adapter.chainIdentifier();
        bytes memory adapterAddress = adapter.interoperableAddress(address(adapter));
        bytes memory tokenAddress = adapter.interoperableAddress(token);
        bytes32 actual = adapter.registrationHash(token, tokenId);
        assertEq(actual, keccak256(abi.encode(adapterAddress, token, tokenId)));
        assertTrue(actual != keccak256(abi.encode(block.chainid, address(adapter), token, tokenId)));
        assertTrue(actual != keccak256(abi.encode(identifier, address(adapter), token, tokenId)));
        assertTrue(actual != keccak256(abi.encode(adapterAddress, tokenAddress, tokenId)));
        assertTrue(actual != keccak256(abi.encode(address(adapter), token, tokenId)));
        assertTrue(actual != keccak256(abi.encodePacked(adapterAddress, token, tokenId)));
        assertTrue(actual != keccak256(abi.encode(keccak256(adapterAddress), token, tokenId)));
    }

    function testEachDomainCoordinateChangesHash() external view {
        bytes memory adapterAddress = hex"000100000101141111111111111111111111111111111111111111";
        bytes memory otherTypeAdapter = hex"000100010101141111111111111111111111111111111111111111";
        bytes memory otherReferenceAdapter = hex"000100000102141111111111111111111111111111111111111111";
        bytes memory otherAdapter = hex"000100000101143333333333333333333333333333333333333333";
        bytes32 base = harness.registrationHashFor(adapterAddress, VECTOR_TOKEN, 42);
        assertTrue(base != harness.registrationHashFor(otherTypeAdapter, VECTOR_TOKEN, 42));
        assertTrue(base != harness.registrationHashFor(otherReferenceAdapter, VECTOR_TOKEN, 42));
        assertTrue(base != harness.registrationHashFor(otherAdapter, VECTOR_TOKEN, 42));
        assertTrue(base != harness.registrationHashFor(adapterAddress, address(0x4444), 42));
        assertTrue(base != harness.registrationHashFor(adapterAddress, VECTOR_TOKEN, 43));
    }

    function _assertVector(bytes memory adapterAddress, bytes32 expected) internal view {
        assertEq(harness.registrationHashFor(adapterAddress, VECTOR_TOKEN, 42), expected);
    }
}
