// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {IERC8004IdentityRegistry} from "../../src/interfaces/IERC8004IdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// A registry that seeds a FOREIGN (non-adapter) agent wallet at register time, to prove the
/// adapter's unconditional `unsetAgentWallet` (:167-168) clears whatever the registry set, rather
/// than assuming the value is the adapter's own address.
contract ForeignWalletRegistry is IERC8004IdentityRegistry {
    uint256 public lastId;
    address public foreignWallet;
    mapping(uint256 => mapping(string => bytes)) private _meta;

    constructor(address foreign) {
        foreignWallet = foreign;
    }

    function _reg(string memory uri) internal returns (uint256 id) {
        id = lastId++;
        _meta[id]["agentWallet"] = abi.encodePacked(foreignWallet);
        if (bytes(uri).length != 0) {
            _meta[id]["__uri"] = bytes(uri);
        }
    }

    function register(string memory uri, MetadataEntry[] memory md) external returns (uint256 id) {
        id = _reg(uri);
        for (uint256 i; i < md.length; ++i) {
            _meta[id][md[i].metadataKey] = md[i].metadataValue;
        }
    }

    function register(string memory uri) external returns (uint256) {
        return _reg(uri);
    }

    function register() external returns (uint256) {
        return _reg("");
    }

    function setMetadata(uint256 id, string memory k, bytes memory v) external {
        _meta[id][k] = v;
    }

    function setAgentURI(uint256 id, string calldata uri) external {
        _meta[id]["__uri"] = bytes(uri);
    }

    function setAgentWallet(uint256 id, address w, uint256, bytes calldata) external {
        _meta[id]["agentWallet"] = abi.encodePacked(w);
    }

    function unsetAgentWallet(uint256 id) external {
        _meta[id]["agentWallet"] = "";
    }

    function getMetadata(uint256 id, string memory k) external view returns (bytes memory) {
        return _meta[id][k];
    }

    function getAgentWallet(uint256 id) external view returns (address) {
        bytes memory w = _meta[id]["agentWallet"];
        if (w.length < 20) return address(0);
        return address(bytes20(w));
    }

    function ownerOf(uint256) external pure returns (address) {
        return address(0);
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        return string(_meta[id]["__uri"]);
    }
}

/// SdR3 #19 — AgentWalletDefaultCleared. The adapter does not trust what the registry set the agent
/// wallet to; step 7 unconditionally calls `unsetAgentWallet`. Even a registry that seeds a foreign
/// wallet ends at `address(0)` after `register`. NOT one of the prior 40: R2 #19 checked the unset
/// happens on the metadata overload; none tests a registry that seeds a NON-adapter default wallet.
/// Defended: the adapter zeroes the default regardless of its value.
contract SdR3_19_AgentWalletDefaultCleared is Test {
    ForeignWalletRegistry internal registry;
    Adapter8004 internal adapter;
    MockERC721 internal token;

    address internal admin = makeAddr("admin");
    address internal owner = makeAddr("owner");
    address internal foreign = makeAddr("foreignWallet");
    uint256 internal constant TID = 1;

    function setUp() external {
        registry = new ForeignWalletRegistry(foreign);
        Adapter8004 impl = new Adapter8004(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Adapter8004.initialize, (admin)));
        adapter = Adapter8004(address(proxy));
        token = new MockERC721();
        token.mint(owner, TID);
    }

    /// Success condition (defense): after register, the seeded foreign wallet has been cleared to zero.
    function test_adapterClearsForeignDefaultWallet() external {
        vm.prank(owner);
        uint256 agentId = adapter.register(IERC8217.Standard.ERC721, address(token), TID, "ipfs://a");

        assertEq(adapter.getAgentWallet(agentId), address(0), "adapter cleared the registry's foreign default wallet");
        assertEq(adapter.getMetadata(agentId, "agent-binding"), abi.encodePacked(address(adapter)), "binding record written");
    }
}
