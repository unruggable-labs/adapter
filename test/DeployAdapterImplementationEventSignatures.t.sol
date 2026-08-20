// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployAdapterImplementationScript} from "../script/DeployAdapterImplementation.s.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IERC8004AdapterCounterfactual} from "../src/interfaces/IERC8004AdapterCounterfactual.sol";
import {IERC8004AdapterWalletAgentID} from "../src/interfaces/IERC8004AdapterWalletAgentID.sol";
import {IERC8004AdapterWalletCounterfactualID} from "../src/interfaces/IERC8004AdapterWalletCounterfactualID.sol";
import {IERCAgentBindings} from "../src/interfaces/IERCAgentBindings.sol";
import {IERC8004AdapterAttestation} from "../src/interfaces/IERC8004AdapterAttestation.sol";

/// @notice Holds the deploy script's printed event signatures against the contract they describe.
///
/// The script tells operators which topics to subscribe to after an upgrade. Those strings have gone
/// stale three separate times, each time because a field changed in the contract and nothing
/// connected the two. Correcting them again without a check only resets the clock.
///
/// The truth side of every assertion is `SomeEvent.selector`, which the compiler derives from the
/// event declaration itself. Nothing here restates a signature, so there is no second copy to drift.
/// Change a field in any of these events and this test fails until the script is updated to match.
contract DeployScriptEventSignaturesTest is Test, DeployAdapterImplementationScript {
    function _assertSig(string memory sig, bytes32 topic0, string memory name) internal pure {
        assertEq(keccak256(bytes(sig)), topic0, name);
    }

    function testPrintedCounterfactualSignaturesMatchTheContract() external pure {
        _assertSig(
            SIG_CF_REGISTERED,
            IERC8004AdapterCounterfactual.CounterfactualAgentRegistered.selector,
            "CounterfactualAgentRegistered"
        );
        _assertSig(
            SIG_CF_URI_SET,
            IERC8004AdapterCounterfactual.CounterfactualAgentURISet.selector,
            "CounterfactualAgentURISet"
        );
        _assertSig(
            SIG_CF_METADATA_SET,
            IERC8004AdapterCounterfactual.CounterfactualMetadataSet.selector,
            "CounterfactualMetadataSet"
        );
        _assertSig(
            SIG_CF_METADATA_BATCH_SET,
            IERC8004AdapterCounterfactual.CounterfactualMetadataBatchSet.selector,
            "CounterfactualMetadataBatchSet"
        );
        _assertSig(
            SIG_CF_WALLET_SET,
            IERC8004AdapterCounterfactual.CounterfactualAgentWalletSet.selector,
            "CounterfactualAgentWalletSet"
        );
        _assertSig(
            SIG_CF_WALLET_UNSET,
            IERC8004AdapterCounterfactual.CounterfactualAgentWalletUnset.selector,
            "CounterfactualAgentWalletUnset"
        );
    }

    function testPrintedPrimaryAgentSignaturesMatchTheContract() external pure {
        _assertSig(SIG_PRIMARY_AGENT_SET, IERC8004AdapterWalletAgentID.WalletAgentIDSet.selector, "WalletAgentIDSet");
        _assertSig(
            SIG_PRIMARY_COUNTERFACTUAL_AGENT_SET,
            IERC8004AdapterWalletCounterfactualID.WalletCounterfactualIDSet.selector,
            "WalletCounterfactualIDSet"
        );
    }

    function testPrintedAttestationSignaturesMatchTheContract() external pure {
        _assertSig(SIG_ATTESTED, IERC8004AdapterAttestation.Attested.selector, "Attested");
        _assertSig(
            SIG_ATTESTATION_REVOKED, IERC8004AdapterAttestation.AttestationRevoked.selector, "AttestationRevoked"
        );
    }

    function testPrintedAgentBoundSignatureMatchesTheContract() external pure {
        _assertSig(SIG_AGENT_BOUND, Adapter8004.AgentBound.selector, "AgentBound");
    }

    /// @dev The same defect in a different shape. The script prints a sample identity, and a preimage
    /// that omits a field is as misleading as a signature that names the wrong one. This compares the
    /// script's formula against the contract's, for inputs the script itself uses.
    function testPrintedSampleRegistrationHashMatchesTheContract() external {
        Adapter8004 adapter = new Adapter8004();
        bytes memory proxyInteroperableAddress = _interoperableAddress(block.chainid, address(adapter));

        assertEq(
            _sampleRegistrationHash(proxyInteroperableAddress, IERCAgentBindings.TokenStandard.ERC721, address(1), 0),
            adapter.registrationHash(IERCAgentBindings.TokenStandard.ERC721, address(1), 0),
            "sample preimage must match the contract's"
        );
    }
}
