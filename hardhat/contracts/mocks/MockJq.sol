// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * Stand-in for the jq precompile at 0x0803.
 *
 * jq is synchronous and the contract reaches it with `staticcall`, so this mock may
 * read storage but must never write it. The fallback below only reads, which is why
 * a staticcall into it succeeds even though `fallback` cannot be declared `view`.
 *
 * The real precompile answers a wrong outputType with ok = true and a zero-length
 * result rather than a revert, so `emptyResult` reproduces exactly that, and the
 * length check on the caller's side is what has to catch it.
 */
contract MockJq {
    uint256 public value;
    bool public emptyResult;

    function setValue(uint256 value_) external {
        value = value_;
        emptyResult = false;
    }

    function setEmptyResult(bool value_) external {
        emptyResult = value_;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        if (emptyResult) return bytes("");
        return abi.encode(value);
    }
}
