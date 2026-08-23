// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERCAgentBindings} from "./IERCAgentBindings.sol";

/// @notice The counterfactual identity a wallet picks for itself, the counterfactual counterpart of
/// `IERC8004AdapterWalletAgentID`. Values are always derived by the adapter from the standard and
/// token coordinates using its canonical ERC-7930 UBI. These assertions stay separate
/// from wallet agent ids and require reciprocal wallet-event
/// verification.
interface IERC8004AdapterWalletCounterfactualID {
    function WALLET_COUNTERFACTUAL_ID_UNSET() external pure returns (bytes32);

    /// @notice `standard` is the `TokenStandard` folded into the UBI. It is carried here
    /// because `(boundAddress, tokenId)` alone does not name an identity, so a reader can recompute
    /// the hash from this one log line. See `IERC8004AdapterCounterfactual`.
    event WalletCounterfactualIDSet(
        address indexed account,
        bytes32 indexed ubi,
        address boundAddress,
        uint256 tokenId,
        IERCAgentBindings.TokenStandard standard,
        address indexed setBy
    );
    event WalletCounterfactualIDCleared(address indexed account, address indexed clearedBy);

    /// @notice Record the caller's own wallet counterfactual id, named by standard and token
    /// coordinates. The adapter derives the UBI itself, so a caller cannot assert a
    /// hash it did not compute from a real triple. `standard` selects which identity is named: the
    /// same `(boundAddress, tokenId)` under two standards resolves to two different hashes. This is a
    /// self-assertion and is not proof: nothing here checks that the caller holds the token or would
    /// pass that standard's authority probe, so a consumer must verify the claim reciprocally before
    /// treating it as identity. Emits `WalletCounterfactualIDSet` and returns the derived hash.
    function setWalletCounterfactualID(IERCAgentBindings.TokenStandard standard, address boundAddress, uint256 tokenId)
        external
        returns (bytes32 ubi);

    /// @notice Record `account`'s wallet counterfactual id on its behalf. Authorized when the
    /// caller is the account itself, its `owner()` or `getOwner()`, or a holder of its
    /// `DEFAULT_ADMIN_ROLE`, and reverts `NotAccountController` otherwise. An account that misreports
    /// its controller can only affect its own entry.
    function setWalletCounterfactualIDFor(
        address account,
        IERCAgentBindings.TokenStandard standard,
        address boundAddress,
        uint256 tokenId
    ) external returns (bytes32 ubi);

    /// @notice Clear the caller's own wallet counterfactual id. Idempotent, and clearing an
    /// account that never set one still emits `WalletCounterfactualIDCleared`.
    function clearWalletCounterfactualID() external;

    /// @notice Clear `account`'s wallet counterfactual id, under the same authorization rules as
    /// `setWalletCounterfactualIDFor`.
    function clearWalletCounterfactualIDFor(address account) external;

    /// @notice Reverse-resolve an address to the UBI it claims. Returns
    /// `WALLET_COUNTERFACTUAL_ID_UNSET` when the account has never set one or has cleared it.
    /// @dev Anyone reading the mapping directly rather than through this getter needs two facts. The
    /// stored word is the bitwise complement of the hash, not the hash, so that an unwritten slot and
    /// a real value can never be confused. An all-ones hash is rejected on write for the same reason,
    /// since its complement is zero.
    function walletCounterfactualIDOf(address account) external view returns (bytes32 ubi);
}
