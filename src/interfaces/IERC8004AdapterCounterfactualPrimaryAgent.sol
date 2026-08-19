// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERCAgentBindings} from "./IERCAgentBindings.sol";

/// @notice Counterfactual reverse resolution. Values are always derived by the adapter from the
/// standard and token coordinates using its canonical ERC-7930 registration hash. These account
/// assertions remain separate from full ERC-8004 primaries and require reciprocal wallet-event
/// verification.
interface IERC8004AdapterCounterfactualPrimaryAgent {
    function PRIMARY_COUNTERFACTUAL_AGENT_UNSET() external pure returns (bytes32);

    /// @notice `extraData` is the discriminator folded into `registrationHash`, and `standard` is the
    /// `TokenStandard` folded into it. Both are carried here because `(boundAddress, tokenId)` alone
    /// is not unique, so a reader can recompute the hash from this one log line. See
    /// `IERC8004AdapterCounterfactual`.
    event PrimaryCounterfactualAgentSet(
        address indexed account,
        bytes32 indexed registrationHash,
        address boundAddress,
        uint256 tokenId,
        bytes32 extraData,
        IERCAgentBindings.TokenStandard standard,
        address indexed setBy
    );
    event PrimaryCounterfactualAgentCleared(address indexed account, address indexed clearedBy);

    /// @notice Record the caller's own primary counterfactual agent, named by standard and token
    /// coordinates. The adapter derives the `registrationHash` itself, so a caller cannot assert a
    /// hash it did not compute from a real triple. `standard` selects which identity is named: the
    /// same `(boundAddress, tokenId)` under two standards resolves to two different hashes. This is a
    /// self-assertion and is not proof: nothing here checks that the caller holds the token or would
    /// pass that standard's authority probe, so a consumer must verify the claim reciprocally before
    /// treating it as identity. Emits `PrimaryCounterfactualAgentSet` and returns the derived hash.
    function setPrimaryCounterfactualAgent(
        IERCAgentBindings.TokenStandard standard,
        address boundAddress,
        uint256 tokenId
    ) external returns (bytes32 registrationHash);

    /// @notice Record `account`'s primary counterfactual agent on its behalf. Authorized when the
    /// caller is the account itself, its `owner()` or `getOwner()`, or a holder of its
    /// `DEFAULT_ADMIN_ROLE`, and reverts `NotAccountController` otherwise. An account that misreports
    /// its controller can only affect its own entry.
    function setPrimaryCounterfactualAgentFor(
        address account,
        IERCAgentBindings.TokenStandard standard,
        address boundAddress,
        uint256 tokenId
    ) external returns (bytes32 registrationHash);

    /// @notice Clear the caller's own primary counterfactual agent. Idempotent, and clearing an
    /// account that never set one still emits `PrimaryCounterfactualAgentCleared`.
    function clearPrimaryCounterfactualAgent() external;

    /// @notice Clear `account`'s primary counterfactual agent, under the same authorization rules as
    /// `setPrimaryCounterfactualAgentFor`.
    function clearPrimaryCounterfactualAgentFor(address account) external;

    /// @notice Reverse-resolve an address to the registration hash it claims. Returns
    /// `PRIMARY_COUNTERFACTUAL_AGENT_UNSET` when the account has never set one or has cleared it.
    /// @dev Anyone reading the mapping directly rather than through this getter needs two facts. The
    /// stored word is the bitwise complement of the hash, not the hash, so that an unwritten slot and
    /// a real value can never be confused. An all-ones hash is rejected on write for the same reason,
    /// since its complement is zero.
    function primaryCounterfactualAgentOf(address account) external view returns (bytes32 registrationHash);
}
