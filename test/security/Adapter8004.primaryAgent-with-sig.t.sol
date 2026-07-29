// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../../src/Adapter8004.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

contract PrimarySig1271 is IERC1271 {
    mapping(bytes32 => bool) internal approved;

    function approve(bytes32 digest) external {
        approved[digest] = true;
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return approved[digest] ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}

contract PrimaryAgentWithSigTest is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant SET_FULL_TYPEHASH =
        keccak256("SetPrimary8004Agent(address account,uint256 agentId,uint256 nonce,uint256 deadline)");
    bytes32 internal constant CLEAR_FULL_TYPEHASH =
        keccak256("ClearPrimary8004Agent(address account,uint256 nonce,uint256 deadline)");
    Adapter8004 internal adapter;
    MockERC721 internal token;
    uint256 internal alicePk = 0xA11CE;
    address internal alice;
    address internal relayer = makeAddr("relayer");

    function setUp() external {
        alice = vm.addr(alicePk);
        MockIdentityRegistry registry = new MockIdentityRegistry();
        Adapter8004 implementation = new Adapter8004();
        adapter = Adapter8004(
            address(
                new ERC1967Proxy(
                    address(implementation), abi.encodeCall(Adapter8004.initialize, (address(registry), address(this)))
                )
            )
        );
        token = new MockERC721();
        token.mint(alice, 1);
    }

    function testFullNonceZeroSignatureExecutes() external {
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory fullSig = _sign(alicePk, _digest(keccak256(abi.encode(SET_FULL_TYPEHASH, alice, 42, 0, deadline))));

        vm.prank(relayer);
        adapter.setPrimaryAgentWithSig(alice, 42, deadline, fullSig);

        assertEq(adapter.primaryAgentOf(alice), 42);
        assertEq(adapter.primaryAgentNonces(alice), 1);
    }

    function testSetAndClearShareFullSystemNonce() external {
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory setSig = _sign(alicePk, _digest(keccak256(abi.encode(SET_FULL_TYPEHASH, alice, 42, 0, deadline))));
        bytes memory clearSameNonce =
            _sign(alicePk, _digest(keccak256(abi.encode(CLEAR_FULL_TYPEHASH, alice, 0, deadline))));
        adapter.setPrimaryAgentWithSig(alice, 42, deadline, setSig);
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.clearPrimaryAgentWithSig(alice, deadline, clearSameNonce);
        assertEq(adapter.primaryAgentNonces(alice), 1);
    }

    function testERC1271WorksForFullSystem() external {
        PrimarySig1271 account = new PrimarySig1271();
        uint256 deadline = block.timestamp + 5 minutes;
        account.approve(_digest(keccak256(abi.encode(SET_FULL_TYPEHASH, address(account), 7, 0, deadline))));
        adapter.setPrimaryAgentWithSig(address(account), 7, deadline, hex"01");
        assertEq(adapter.primaryAgentOf(address(account)), 7);
    }

    function testLegacyFullTypeSignatureFailsAndConsumesNoNonce() external {
        uint256 deadline = block.timestamp + 5 minutes;
        bytes32 oldType = keccak256("SetPrimaryAgent(address account,bytes32 agentId,uint256 nonce,uint256 deadline)");
        bytes memory signature =
            _sign(alicePk, _digest(keccak256(abi.encode(oldType, alice, bytes32(uint256(42)), 0, deadline))));
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.setPrimaryAgentWithSig(alice, 42, deadline, signature);
        assertEq(adapter.primaryAgentNonces(alice), 0);
    }

    function testDeadlineBoundsRemainInclusive() external {
        bytes memory signature =
            _sign(alicePk, _digest(keccak256(abi.encode(SET_FULL_TYPEHASH, alice, 1, 0, block.timestamp))));
        adapter.setPrimaryAgentWithSig(alice, 1, block.timestamp, signature);
        uint256 tooFar = block.timestamp + 30 minutes + 1;
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.SignatureDeadlineTooFar.selector, tooFar));
        adapter.clearPrimaryAgentWithSig(alice, tooFar, hex"");
    }

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return _digestFor(address(adapter), structHash);
    }

    function _digestFor(address verifyingContract, bytes32 structHash) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("Adapter8004"), keccak256("1"), block.chainid, verifyingContract)
        );
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
    }

    function _sign(uint256 privateKey, bytes32 digest) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
