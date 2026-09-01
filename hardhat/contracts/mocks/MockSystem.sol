// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * Stand-ins for the three Ritual system contracts the market talks to.
 *
 * They are grouped in one file because they are always etched together: a test that
 * needs one of them needs all three. The two precompiles live in their own files
 * instead, because their request envelopes carry the real complexity.
 *
 * All three are etched, so no constructor ever runs and every field starts at zero.
 */

/// Scheduler at 0x56e7…D58B.
contract MockScheduler {
    struct Booking {
        address target;
        bytes data;
        uint32 gas;
        uint32 startBlock;
        uint32 numCalls;
        uint32 frequency;
        uint32 ttl;
        uint256 maxFeePerGas;
        address payer;
        bool cancelled;
    }

    uint256 public lastCallId;
    mapping(uint256 => Booking) private _bookings;

    mapping(address => bool) public approved;

    /// Make `schedule` revert, so a test can prove that a market which cannot book
    /// its own resolution is never created in the first place.
    bool public rejectSchedule;

    /// Make `cancel` revert, to prove a settled market survives a Scheduler that
    /// refuses to release the attempts it no longer needs.
    bool public rejectCancel;

    uint256 public cancelCount;

    function setRejectSchedule(bool value) external {
        rejectSchedule = value;
    }

    function setRejectCancel(bool value) external {
        rejectCancel = value;
    }

    function approveScheduler(address schedulerContract) external {
        approved[schedulerContract] = true;
    }

    function schedule(
        bytes calldata data,
        uint32 gas,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256,
        uint256,
        address payer
    ) external returns (uint256 callId) {
        require(!rejectSchedule, "MockScheduler: booking refused");

        callId = ++lastCallId;
        Booking storage b = _bookings[callId];
        b.target = msg.sender;
        b.data = data;
        b.gas = gas;
        b.startBlock = startBlock;
        b.numCalls = numCalls;
        b.frequency = frequency;
        b.ttl = ttl;
        b.maxFeePerGas = maxFeePerGas;
        b.payer = payer;
    }

    function cancel(uint256 callId) external {
        require(!rejectCancel, "MockScheduler: cancel refused");
        _bookings[callId].cancelled = true;
        cancelCount += 1;
    }

    function getCallState(uint256 callId) external view returns (uint8) {
        return _bookings[callId].cancelled ? 2 : 1;
    }

    function booking(uint256 callId) external view returns (Booking memory) {
        return _bookings[callId];
    }

    /**
     * Run one booked execution.
     *
     * Mirrors the real Scheduler in the two ways that matter to the contract under
     * test: bytes 4..35 of the stored calldata are overwritten with the execution
     * index, and a callback that reverts is swallowed rather than propagated, so a
     * single broken market cannot block the queue.
     */
    function fire(
        uint256 callId,
        uint256 executionIndex
    ) external returns (bool ok) {
        Booking storage b = _bookings[callId];
        require(b.target != address(0), "MockScheduler: no such booking");
        require(!b.cancelled, "MockScheduler: booking cancelled");

        bytes memory data = b.data;
        assembly {
            // 0x20 skips the length word, 4 more skips the selector.
            mstore(add(data, 0x24), executionIndex)
        }

        (ok, ) = b.target.call(data);
    }
}

/// RitualWallet at 0x532F…3948.
contract MockRitualWallet {
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _lockUntil;

    function deposit(uint256 lockDuration) external payable {
        _balances[msg.sender] += msg.value;
        _lockUntil[msg.sender] = block.number + lockDuration;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function lockUntil(address account) external view returns (uint256) {
        return _lockUntil[account];
    }
}

/// TEEServiceRegistry at 0x9644…F47F.
contract MockTeeRegistry {
    address[] private _executors;

    /// Reproduce a registry that is reachable but has nothing attested to offer.
    bool public alwaysMiss;

    /// Reproduce a registry that is not reachable at all.
    bool public revertOnPick;

    function setExecutors(address[] calldata executors) external {
        delete _executors;
        for (uint256 i = 0; i < executors.length; i++)
            _executors.push(executors[i]);
    }

    function setAlwaysMiss(bool value) external {
        alwaysMiss = value;
    }

    function setRevertOnPick(bool value) external {
        revertOnPick = value;
    }

    function executorCount() external view returns (uint256) {
        return _executors.length;
    }

    function pickServiceByCapability(
        uint8,
        bool,
        uint256 seed,
        uint256
    ) external view returns (address teeAddress, bool found) {
        require(!revertOnPick, "MockTeeRegistry: unreachable");
        if (alwaysMiss || _executors.length == 0) return (address(0), false);
        return (_executors[seed % _executors.length], true);
    }
}
