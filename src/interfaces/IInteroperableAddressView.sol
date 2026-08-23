// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Read-only ERC-7930 encoding for the chain this contract is deployed on. Neither function
/// carries any binding, counterfactual or attestation meaning: they expose the envelope that other
/// surfaces embed in the identifiers they derive. They are separated so a consumer that needs the
/// encoding does not have to import an identity interface, and so an identity interface does not
/// have to carry an encoding concern.
///
/// The values are what every identifier this contract issues is built on, so they are effectively
/// frozen. `interoperableAddress(address(this))` is the first component of every UBI and of
/// every attestation identifier, which means a change to this encoding
/// re-keys both. The production implementation delegates to OpenZeppelin's `draft-` prefixed
/// `InteroperableAddress`, which owes no encoding stability across releases; the exact bytes are
/// pinned against three independent oracles in `test/Adapter8004.erc7930-frozen.t.sol`.
interface IInteroperableAddressView {
    /// @notice Local ERC-7930 v1 Chain Identifier using CAIP-350 `eip155`: version 1, ChainType 0,
    /// shortest non-empty big-endian `block.chainid`, and zero AddressLength.
    function chainIdentifier() external view returns (bytes memory);

    /// @notice Full local ERC-7930 v1 Interoperable Address for an EVM account: the same chain
    /// envelope as `chainIdentifier()`, followed by AddressLength 20 and the raw address bytes.
    function interoperableAddress(address account) external view returns (bytes memory);
}
