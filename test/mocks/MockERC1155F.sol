// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC1155} from "./MockERC1155.sol";

contract MockERC1155F is MockERC1155 {
    mapping(uint256 tokenId => address owner) private _owners;

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId, 1, "");
        _owners[tokenId] = to;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "nonexistent token");
        return owner;
    }

    function transferOwner(address from, address to, uint256 tokenId) external {
        require(_owners[tokenId] == from, "not owner");
        safeTransferFrom(from, to, tokenId, 1, "");
        _owners[tokenId] = to;
    }
}
