// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * Stand-in for the HTTP call precompile at 0x0801.
 *
 * The real precompile is reached with a plain `.call(bytes)` carrying no function
 * selector, so this mock answers from `fallback` and reads the whole of `msg.data`.
 *
 * Design note. The request is thirteen ABI values and decoding all of them in one
 * `abi.decode` does not compile: every decoded value wants its own stack slot and
 * the EVM can only reach sixteen of them. Rather than fight that, this mock stores
 * the request verbatim and decodes single fields lazily in view functions. Each
 * view keeps at most three values alive, so there is no stack pressure anywhere,
 * and a test can come back later and inspect any field it cares about.
 *
 * Etched with `vm.etch` / `hardhat_setCode`, which copies runtime code but never
 * runs a constructor, so every field below starts at zero on purpose. Configure it
 * explicitly in setUp; nothing here is implicitly "ready".
 */
contract MockHttp {
    /// The exact bytes the contract under test sent, kept for later inspection.
    bytes public lastRequest;

    /// Bumped on every invocation. A test that expects a call and finds zero here
    /// has been rolled back by a revert somewhere below it.
    uint256 public callCount;

    // ── configurable response ──
    uint16 public status;
    bytes public body;
    string public errorMessage;

    /// Return an envelope whose actualOutput is empty, i.e. the shape seen during
    /// simulation before a TEE executor has settled the request.
    bool public unsettled;

    /// Make the precompile call itself fail, rather than answer with an error.
    bool public rejectCall;

    function setResponse(uint16 status_, bytes calldata body_) external {
        status = status_;
        body = body_;
        errorMessage = "";
        unsettled = false;
        rejectCall = false;
    }

    function setErrorMessage(string calldata message) external {
        errorMessage = message;
    }

    function setUnsettled(bool value) external {
        unsettled = value;
    }

    function setRejectCall(bool value) external {
        rejectCall = value;
    }

    // ───────────────────────── request inspection ─────────────────────────
    // Field order in the envelope:
    //   0 executor        1 encryptedSecrets   2 ttl        3 secretSignatures
    //   4 userPublicKey   5 url                6 method     7 headerKeys
    //   8 headerValues    9 body              10 .. 12 trailing fields
    // Words 1, 3, 4, 5, 7, 8, 9 hold offsets because those types are dynamic.

    function requestedExecutor() external view returns (address) {
        return address(uint160(_word(lastRequest, 0)));
    }

    function requestedTtl() external view returns (uint256) {
        return _word(lastRequest, 2);
    }

    function requestedMethod() external view returns (uint8) {
        return uint8(_word(lastRequest, 6));
    }

    function requestedUrl() external view returns (string memory) {
        bytes memory raw = lastRequest;
        uint256 offset = _word(raw, 5); // word 5 points at the string
        uint256 length = _at(raw, offset); // first word there is its length

        bytes memory out = new bytes(length);
        for (uint256 i = 0; i < length; i++) out[i] = raw[offset + 32 + i];
        return string(out);
    }

    // ─────────────────────────────── answer ───────────────────────────────

    fallback(bytes calldata input) external returns (bytes memory) {
        require(!rejectCall, "MockHttp: request rejected");

        lastRequest = input;
        callCount += 1;

        bytes memory actualOutput = unsettled
            ? bytes("")
            : abi.encode(
                status,
                new string[](0),
                new string[](0),
                body,
                errorMessage
            );

        // The short-running async envelope: (simmedInput, actualOutput).
        return abi.encode(bytes(""), actualOutput);
    }

    // ────────────────────────────── internals ─────────────────────────────

    function _word(
        bytes memory raw,
        uint256 index
    ) private pure returns (uint256) {
        return _at(raw, index * 32);
    }

    function _at(
        bytes memory raw,
        uint256 byteOffset
    ) private pure returns (uint256 w) {
        require(raw.length >= byteOffset + 32, "MockHttp: request too short");
        assembly {
            w := mload(add(add(raw, 0x20), byteOffset))
        }
    }
}
