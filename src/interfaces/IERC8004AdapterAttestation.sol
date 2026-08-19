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
    /// @dev **APPEND ONLY. NEVER RENUMBER, NEVER REORDER, NEVER REMOVE A MEMBER.** These numbers are
    /// identity-critical for the same reason `IERCAgentBindings.TokenStandard`'s are: the `uint8` of
    /// this enum sits in the preimage of every `attestationId`, so renumbering a member re-keys every
    /// attestation ever emitted under it, and every revocation that names one. Nothing on chain
    /// records the old value, so that is unrecoverable. Add new types at the end.
    ///
    /// `UNSPECIFIED` holds zero and is never a real type. Solidity enums start at zero, so without it
    /// the first real type would be the value a default-initialized variable carries, which is
    /// exactly what `AttestationTypeZero` exists to reject.
    ///
    /// The set is closed: admitting a sixth type is an upgrade. That is deliberate. The upside is
    /// that the ABI decoder rejects an out-of-range value before any contract code runs, so a garbage
    /// type costs nothing to refuse and can never reach the log.
    enum AttestationType {
        /// Reserved sentinel. Never a real type; rejected by `AttestationTypeZero`.
        UNSPECIFIED,
        /// The attester is an additional account of the agent. State projection, empty payload.
        CONFIRM_ACCOUNT,
        /// Endorsement toggle. State projection. One byte, `1` stars and `0` unstars. Aggregates by
        /// counting the attesters whose live value is `1`.
        STAR,
        /// Quality rating. State projection. One byte, `0` to `100`, on the ERC-8004 `starred`
        /// scale. Aggregates by averaging each attester's live value.
        RATING,
        /// Written review. Stream projection. Payload is the UTF-8 text, at least one byte.
        REVIEW,
        /// Record of one dealing. Stream projection. Payload is at least 33 bytes: byte 0 is the
        /// outcome score, `0` to `100`; bytes 1 to 32 are a reference identifying the dealing,
        /// typically a transaction hash, zero when absent; bytes 33 onward are optional UTF-8 text.
        INTERACTION
    }

    /// @notice Thrown when `attestationType` is `UNSPECIFIED`. Zero is reserved as the
    /// uninitialized-input sentinel so a forgotten field fails instead of recording a statement of no
    /// stated type.
    error AttestationTypeZero();
    /// @notice Thrown when `cfid` is zero on an attest path. Zero is reserved as the
    /// uninitialized-input sentinel so a forgotten target fails instead of attaching a statement
    /// to the zero identity. Every nonzero value is accepted, including one that matches no claim
    /// yet: attesting ahead of an identity's first counterfactual claim is a supported use.
    error AttestationTargetZero();

    /// @notice A statement was recorded. `attester` is the account that made it and is the caller
    /// of the recording transaction. `attestationId` is the statement's identifier, derived as
    /// `keccak256(abi.encode(interoperableAddress(adapter), attester, cfid, attestationType,
    /// block.number, variant, data))` with `attestationType` encoded as the enum's `uint8`, and is
    /// recomputable from this event plus its log context. The three indexed fields serve the three
    /// canonical query axes: reverse by attester, forward by target, and filter by type.
    event Attested(
        address indexed attester,
        AttestationType indexed attestationType,
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
    /// `AttestationTypeZero` or `AttestationTargetZero` on an `UNSPECIFIED` type or a zero target.
    /// A value outside the enum never reaches this function: the ABI decoder rejects it first.
    function attest(AttestationType attestationType, bytes32 cfid, bytes32 variant, bytes calldata data) external;

    /// @notice Record that the caller is an additional account of the agent `cfid` identifies.
    /// Equivalent to `attest(AttestationType.CONFIRM_ACCOUNT, cfid, 0, "")`. This is the reciprocal half of the
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
}
