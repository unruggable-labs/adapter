// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Emit-only attestations to counterfactual identities. An attestation is a public
/// statement about a counterfactual registration hash, recorded in the event log by the account
/// that makes it. The caller is always the attester, so the meaning of every statement rests on
/// who sent the transaction. The contract records the statement and derives its identifier, and
/// interpretation belongs to indexers: they resolve targets against counterfactual claims, apply
/// the published projection rules in log order, and enforce each type's payload and submitter
/// rules at read time. The full type registry, the projection rules, and the verification rules
/// live in `docs/specs/attestation-type-registry-v1.md`.
interface IERC8004AdapterAttestation {
    /// @notice Thrown when `attestationType` is zero. Zero is reserved as the uninitialized-input
    /// sentinel so a forgotten field fails instead of minting a statement in a nameless namespace.
    error AttestationTypeZero();
    /// @notice Thrown when `cfid` is zero on an attest path. Zero is reserved as the
    /// uninitialized-input sentinel so a forgotten target fails instead of attaching a statement
    /// to the zero identity. Every nonzero value is accepted, including one that matches no claim
    /// yet: attesting ahead of an identity's first counterfactual claim is a supported use.
    error AttestationTargetZero();

    /// @notice A statement was recorded. `attester` is the account that made it and is the caller
    /// of the recording transaction. `attestationId` is the statement's identifier, derived as
    /// `keccak256(abi.encode(interoperableAddress(adapter), attester, cfid, attestationType,
    /// block.number, variant, data))`, and is recomputable from this event plus its log context.
    /// The three indexed fields serve the three canonical query axes: reverse by attester, forward
    /// by target, and filter by type.
    event Attested(
        address indexed attester,
        bytes32 indexed attestationType,
        bytes32 indexed cfid,
        bytes32 attestationId,
        bytes32 variant,
        bytes data
    );

    /// @notice A revocation was recorded for `attestationId` by `revoker`, the caller. The
    /// identifier is indexed because it is the join key back to the `Attested` event. A revocation
    /// changes projected state exactly when `revoker` equals the attester of the statement bearing
    /// this identifier, which indexers verify against the log, since the contract stores nothing.
    event AttestationRevoked(bytes32 indexed attestationId, address indexed revoker);

    /// @notice Record a statement of `attestationType` about the counterfactual identity `cfid`,
    /// with `data` carrying the type's payload. The caller is the attester. `variant` separates
    /// otherwise byte-identical statements made within one block and is zero when a single
    /// statement per block is enough; across blocks, `block.number` in the identifier already
    /// keeps identical statements distinct. Emits `Attested` with the derived identifier. Reverts
    /// `AttestationTypeZero` or `AttestationTargetZero` on a zero type or target.
    function attest(bytes32 attestationType, bytes32 cfid, bytes32 variant, bytes calldata data) external;

    /// @notice Record that the caller is an additional account of the agent `cfid` identifies.
    /// Equivalent to `attest(CONFIRM_ACCOUNT(), cfid, 0, "")`. This is the reciprocal half of the
    /// ERC-8048 `account` metadata list: the confirmation verifies while the agent's current
    /// forward metadata names the caller, checked live by the reader. Reverts
    /// `AttestationTargetZero` on a zero target.
    function confirmAdditionalAccount(bytes32 cfid) external;

    /// @notice Record a revocation of the statement identified by `attestationId`. The caller is
    /// the revoker. The revocation withdraws the statement when the caller is its attester, and is
    /// recorded as inert history otherwise, projection rule four. Accepts every identifier,
    /// including one never attested and including zero: revoking a statement that was never made
    /// is a recorded no-op under projection rule three, so the identifier is passed through
    /// unchecked. Emits `AttestationRevoked`.
    function revoke(bytes32 attestationId) external;

    /// @notice Type of the additional-account confirmation,
    /// `keccak256(bytes("adapter8004.attest.v1.confirm-account"))`. State projection, empty
    /// payload.
    function CONFIRM_ACCOUNT() external pure returns (bytes32);

    /// @notice Type of the endorsement toggle, `keccak256(bytes("adapter8004.attest.v1.star"))`.
    /// State projection. Payload is one byte, `1` to star and `0` to unstar. Aggregates by
    /// counting attesters whose live value is `1`.
    function STAR() external pure returns (bytes32);

    /// @notice Type of the quality rating, `keccak256(bytes("adapter8004.attest.v1.rating"))`.
    /// State projection. Payload is one byte, `0` to `100`, on the ERC-8004 `starred` scale.
    /// Aggregates by averaging each attester's live value.
    function RATING() external pure returns (bytes32);

    /// @notice Type of the written review, `keccak256(bytes("adapter8004.attest.v1.review"))`.
    /// Stream projection. Payload is the UTF-8 review text, at least one byte.
    function REVIEW() external pure returns (bytes32);

    /// @notice Type of the interaction record,
    /// `keccak256(bytes("adapter8004.attest.v1.interaction"))`. Stream projection. Payload is at
    /// least 33 bytes: byte 0 is the outcome score, `0` to `100`; bytes 1 to 32 are a reference
    /// identifying the dealing, typically a transaction hash, zero when absent; bytes 33 onward
    /// are optional UTF-8 text.
    function INTERACTION() external pure returns (bytes32);
}
