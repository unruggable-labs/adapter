// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal local view of the immutable delegate.xyz v2 registry. Only the read functions
/// `Adapter8004` consults are declared here. The write and enumeration functions are omitted
/// deliberately, so that this interface cannot be used to reach them. The canonical v2 deployment is
/// `0x00000000000000447e69651d841bD8D104Bed493` on Ethereum, Base and Sepolia.
/// See https://docs.delegate.xyz.
interface IDelegateRegistry {
    /// @notice Returns true when `to` holds a delegation from `from` covering the specific ERC-721
    /// token, the token's contract, or the whole wallet. A check for a nonzero `rights` value also
    /// accepts a blanket delegation that names no rights. Passing `rights == bytes32(0)` matches only
    /// blanket delegations.
    function checkDelegateForERC721(address to, address from, address contract_, uint256 tokenId, bytes32 rights)
        external
        view
        returns (bool);
}
