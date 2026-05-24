// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC6909} from "./MockERC6909.sol";

contract MockERC6909F is MockERC6909 {
    mapping(uint256 tokenId => address owner) private _owners;

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId, 1);
        _owners[tokenId] = to;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "nonexistent token");
        return owner;
    }

    function transferOwner(address from, address to, uint256 tokenId) external {
        require(_owners[tokenId] == from, "not owner");
        transferFrom(from, to, tokenId, 1);
        _owners[tokenId] = to;
    }
}
