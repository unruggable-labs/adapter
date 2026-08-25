// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal local view of the immutable delegate.xyz v2 registry.
/// Only the read functions `Adapter8004` consults are declared here; the full
/// registry surface (write functions, enumeration) is intentionally omitted.
/// Canonical v2 deployment: `0x00000000000000447e69651d841bD8D104Bed493` on
/// Ethereum, Base, and Sepolia. See https://docs.delegate.xyz.
interface IDelegateRegistry {
    /// @notice Returns true when `to` holds a delegation from `from` covering the specific ERC-721
    /// token, the token's contract, or the whole wallet. A check for a nonzero `rights` value also
    /// accepts a blanket delegation that names no rights. Passing `rights == bytes32(0)` matches only
    /// blanket delegations.
    function checkDelegateForERC721(address to, address from, address contract_, uint256 tokenId, bytes32 rights)
        external
        view
        returns (bool);

    /// @notice Returns true when `to` holds a wallet-wide delegation from `from`. It considers only
    /// ALL-type delegations, so it does not accept a contract-scoped or token-scoped grant. That is
    /// what makes it the right check for a binding that names an address acting as itself rather than
    /// assets the address holds inside some contract. The same blanket-delegation rule as below
    /// applies to `rights`.
    function checkDelegateForAll(address to, address from, bytes32 rights) external view returns (bool);

    /// @notice Returns true when `to` holds a delegation from `from` covering the whole contract, or
    /// the whole wallet. It does not consider token-scoped delegations, which is what makes it the
    /// right check for a binding that names a contract rather than a token within it. The same
    /// blanket-delegation rule as above applies to `rights`.
    function checkDelegateForContract(address to, address from, address contract_, bytes32 rights)
        external
        view
        returns (bool);
}
