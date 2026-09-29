// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {AdapterImplementation} from "../src/AdapterImplementation.sol";
import {IERC8217} from "../src/interfaces/IERC8217.sol";
import {IERC8004AdapterAttestation} from "../src/interfaces/IERC8004AdapterAttestation.sol";
interface IRemoteDelegate {
    function delegateAll(address to, bytes32 rights, bool enable) external payable returns (bytes32);
}
/// @dev Run only as remote eth_call contract creation. All changes are discarded by the RPC.
/// Takes the frozen init code as arguments; no vm cheatcodes or state overrides are used.
contract RobinhoodRemoteProbe {
    constructor(bytes memory implInit, bytes memory proxyInit, bytes32 salt) {
        require(block.chainid == 4663, "chain");
        address factory = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        address impl = 0x3d74ff0c1E0A78C5a291fA91F82f15bd54335231;
        address registry = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
        require(keccak256(implInit) == 0x5b3785cf0fbcd80f67ead4953f7a775604ad6f9bbbba55040810e25f1aef1558, "impl input");
        require(keccak256(proxyInit) == 0xbb43a76de1130e845b39e4d6ff11934b8ccf9b4aae11084e955d7f7219cc9953, "proxy input");
        (bool ok, bytes memory result) = factory.call(abi.encodePacked(bytes32(0), implInit));
        require(ok && keccak256(result) == keccak256(abi.encodePacked(impl)), "impl create");
        require(impl.codehash == 0x89df8d1ddb712742b9d7bdfa4048cbcdb651e5abc204b8e1714f8a431c5dad90, "impl runtime");
        address proxy = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, keccak256(proxyInit))))));
        (ok,result) = factory.call(abi.encodePacked(salt, proxyInit));
        require(ok && keccak256(result) == keccak256(abi.encodePacked(proxy)), "proxy create");
        AdapterImplementation adapter = AdapterImplementation(proxy);
        require(adapter.owner() == 0x03302Df40186D9B85faEA4fbb6cC5da028B23149, "owner");
        require(address(adapter.identityRegistry()) == registry, "registry");
        uint256 id = adapter.register(IERC8217.Standard.ACCOUNT, address(this), 0, "ipfs://remote-probe");
        require(adapter.ownerOf(id) == proxy, "registry owner");
        require(adapter.getAgentWallet(id) == address(0), "wallet cleanup");
        require(keccak256(adapter.getMetadata(id,"agent-binding")) == keccak256(abi.encodePacked(proxy)), "binding metadata");
        adapter.setAgentURI(id,"ipfs://remote-updated");
        require(keccak256(bytes(adapter.tokenURI(id))) == keccak256("ipfs://remote-updated"), "URI");
        adapter.setMetadata(id,"remote",hex"1234");
        require(keccak256(adapter.getMetadata(id,"remote")) == keccak256(hex"1234"), "metadata");
        IRemoteDelegate delegates = IRemoteDelegate(adapter.DELEGATE_REGISTRY());
        delegates.delegateAll(address(0xb0b),adapter.DELEGATE_RIGHTS(),true);
        require(adapter.isController(id,address(0xb0b)), "delegate grant");
        delegates.delegateAll(address(0xb0b),adapter.DELEGATE_RIGHTS(),false);
        require(!adapter.isController(id,address(0xb0b)), "delegate revoke");
        bytes32 ubid = adapter.counterfactualRegister(IERC8217.Standard.ACCOUNT,address(this),0,"ipfs://counterfactual");
        require(ubid == adapter.bindingHashOf(id), "UBID");
        require(adapter.setWalletUBID(IERC8217.Standard.ACCOUNT,address(this),0) == ubid, "wallet UBID");
        adapter.clearWalletUBID();
        adapter.attest(IERC8004AdapterAttestation.AttestationType.STAR,ubid,bytes32(0),hex"01");
        adapter.confirmAdditionalAccount(ubid);
        bytes memory evidence = abi.encode(impl,proxy,id,ubid,impl.codehash);
        assembly { return(add(evidence,32),mload(evidence)) }
    }
}
