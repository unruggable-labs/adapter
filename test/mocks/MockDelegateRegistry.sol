// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test double for the delegate.xyz v2 registry, covering only the read
/// surface `Adapter8004` consults plus configuration setters. `checkDelegateForERC721`
/// mirrors v2 semantics: it folds in token-level, contract-level, and all-wallet
/// delegations, and a nonzero `rights` check also accepts an empty/full delegation.
contract MockDelegateRegistry {
    // keccak256-keyed delegation flags, one mapping per delegation scope.
    mapping(bytes32 => bool) private _erc721;
    mapping(bytes32 => bool) private _contractLevel;
    mapping(bytes32 => bool) private _allLevel;

    function delegateERC721(address to, address from, address contract_, uint256 tokenId, bytes32 rights, bool enable)
        external
    {
        _erc721[keccak256(abi.encode(to, from, contract_, tokenId, rights))] = enable;
    }

    function delegateContract(address to, address from, address contract_, bytes32 rights, bool enable) external {
        _contractLevel[keccak256(abi.encode(to, from, contract_, rights))] = enable;
    }

    function delegateAll(address to, address from, bytes32 rights, bool enable) external {
        _allLevel[keccak256(abi.encode(to, from, rights))] = enable;
    }

    function checkDelegateForERC721(address to, address from, address contract_, uint256 tokenId, bytes32 rights)
        external
        view
        returns (bool)
    {
        // Empty/full delegations are honored regardless of the requested rights value.
        if (_matches(to, from, contract_, tokenId, bytes32(0))) {
            return true;
        }

        // A nonzero rights check additionally accepts a delegation scoped to exactly that rights value.
        if (rights != bytes32(0) && _matches(to, from, contract_, tokenId, rights)) {
            return true;
        }

        return false;
    }

    /// @notice Contract-scoped check. It folds in wallet-level delegations but deliberately ignores
    /// token-level ones, which is the difference that makes it correct for a contract binding.
    function checkDelegateForContract(address to, address from, address contract_, bytes32 rights)
        external
        view
        returns (bool)
    {
        if (_matchesContract(to, from, contract_, bytes32(0))) {
            return true;
        }

        if (rights != bytes32(0) && _matchesContract(to, from, contract_, rights)) {
            return true;
        }

        return false;
    }

    /// @notice ALL-type delegations only, matching v2: a contract- or token-scoped grant does not
    /// satisfy this check.
    function checkDelegateForAll(address to, address from, bytes32 rights) external view returns (bool) {
        if (_allLevel[keccak256(abi.encode(to, from, bytes32(0)))]) {
            return true;
        }
        return rights != bytes32(0) && _allLevel[keccak256(abi.encode(to, from, rights))];
    }

    function _matchesContract(address to, address from, address contract_, bytes32 rights)
        private
        view
        returns (bool)
    {
        return _contractLevel[keccak256(abi.encode(to, from, contract_, rights))]
            || _allLevel[keccak256(abi.encode(to, from, rights))];
    }

    function _matches(address to, address from, address contract_, uint256 tokenId, bytes32 rights)
        private
        view
        returns (bool)
    {
        return _erc721[keccak256(abi.encode(to, from, contract_, tokenId, rights))]
            || _contractLevel[keccak256(abi.encode(to, from, contract_, rights))]
            || _allLevel[keccak256(abi.encode(to, from, rights))];
    }
}
