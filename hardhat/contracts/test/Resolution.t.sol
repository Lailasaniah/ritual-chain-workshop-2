// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PredictBase} from "./PredictBase.t.sol";
import {RitualPredict} from "../RitualPredict.sol";
import {RitualChain} from "../ritual/RitualChain.sol";

/// The scheduled wake-up: authorisation, the oracle read, and every way it can fail.
contract ResolutionTest is PredictBase {
    function test_resolve_onlyTheSchedulerMayCall() public {
        uint256 id = _create();
        _closeBetting(id);

        vm.prank(ALICE);
        vm.expectRevert(RitualPredict.OnlyScheduler.selector);
        predict.onScheduledResolve(0, id);
    }

    function test_resolve_ignoresAnUnknownMarketWithoutReverting() public {
        vm.prank(RitualChain.SCHEDULER);
        predict.onScheduledResolve(0, 404);
        assertEq(http.callCount(), 0);
    }

    function test_resolve_ignoresAWakeUpBeforeBettingCloses() public {
        uint256 id = _create();
        _bet(id, ALICE, true, 1 ether);

        _fire(id, 0); // still inside the betting window

        assertEq(http.callCount(), 0, "must not read the oracle yet");
        assertEq(uint8(_state(id)), uint8(RitualPredict.MarketState.Open));
        assertEq(predict.getMarket(id).attempts, 0);
    }

    // ───────────────────────────── happy path ─────────────────────────────

    function test_resolve_settlesYesWhenTheRuleHolds() public {
        uint256 id = _createWith(4000, RitualPredict.Comparator.GTE);
        _bet(id, ALICE, true, 1 ether);
        jq.setValue(4200);

        _closeAndFire(id);

        assertEq(uint8(_state(id)), uint8(RitualPredict.MarketState.Resolved));
        assertEq(uint8(_outcome(id)), uint8(RitualPredict.Outcome.Yes));
        assertEq(predict.getMarket(id).observedValue, 4200);
    }

    function test_resolve_settlesNoWhenTheRuleDoesNot() public {
        uint256 id = _createWith(4000, RitualPredict.Comparator.GTE);
        _bet(id, BOB, false, 1 ether);
        jq.setValue(3900);

        _closeAndFire(id);

        assertEq(uint8(_state(id)), uint8(RitualPredict.MarketState.Resolved));
        assertEq(uint8(_outcome(id)), uint8(RitualPredict.Outcome.No));
    }

    function test_resolve_honoursEveryComparator() public {
        _assertComparator(RitualPredict.Comparator.GT, 100, 101, true);
        _assertComparator(RitualPredict.Comparator.GT, 100, 100, false);
        _assertComparator(RitualPredict.Comparator.GTE, 100, 100, true);
        _assertComparator(RitualPredict.Comparator.GTE, 100, 99, false);
        _assertComparator(RitualPredict.Comparator.LT, 100, 99, true);
        _assertComparator(RitualPredict.Comparator.LT, 100, 100, false);
        _assertComparator(RitualPredict.Comparator.LTE, 100, 100, true);
        _assertComparator(RitualPredict.Comparator.LTE, 100, 101, false);
    }

    /// The request the contract actually built, read back off the precompile mock.
    /// Asserting this is the difference between "a number came back" and "we asked
    /// the right question".
    function test_resolve_sendsTheExecutorTtlAndUrlItPromised() public {
        uint256 id = _create();
        _bet(id, ALICE, true, 1 ether);

        _closeAndFire(id);

        assertEq(http.callCount(), 1, "the precompile was never reached");
        assertEq(http.requestedExecutor(), EXECUTOR_A);
        assertEq(http.requestedTtl(), predict.HTTP_TTL_BLOCKS());
        assertEq(http.requestedUrl(), ORACLE_URL);
        assertEq(http.requestedMethod(), RitualChain.HTTP_GET);
    }

    function test_resolve_cancelsTheAttemptsItNoLongerNeeds() public {
        uint256 id = _create();
        _bet(id, ALICE, true, 1 ether);

        _closeAndFire(id);

        assertEq(scheduler.cancelCount(), 1);
    }

    function test_resolve_survivesASchedulerThatRefusesToCancel() public {
        uint256 id = _create();
        _bet(id, ALICE, true, 1 ether);
        scheduler.setRejectCancel(true);

        _closeAndFire(id);

        // A refused cleanup must never undo a settled market.
        assertEq(uint8(_state(id)), uint8(RitualPredict.MarketState.Resolved));
        assertEq(scheduler.cancelCount(), 0);
    }

    function test_resolve_isIgnoredOnceTheMarketIsFinal() public {
        uint256 id = _create();
        _bet(id, ALICE, true, 1 ether);
        _closeAndFire(id);

        uint256 callsAfterSettlement = http.callCount();
        _wakeDirectly(id, 1);

        assertEq(http.callCount(), callsAfterSettlement, "read twice");
        assertEq(predict.getMarket(id).attempts, 1);
    }

    function test_resolve_refundsWhenTheWinningSideHasNoStake() public {
        uint256 id = _createWith(4000, RitualPredict.Comparator.GTE);
        _bet(id, BOB, false, 3 ether); // nobody backed YES
        jq.setValue(4200); // and YES is what wins

        _closeAndFire(id);

        // Paying a pari-mutuel pool with an empty winning side has no answer, so
        // the market refunds rather than inventing one.
        assertEq(uint8(_state(id)), uint8(RitualPredict.MarketState.Invalid));
        assertEq(uint8(_outcome(id)), uint8(RitualPredict.Outcome.Unresolved));
    }

    // ──────────────────────────── failure paths ───────────────────────────

    function test_resolve_failsWhenNothingIsAttested() public {
        registry.setAlwaysMiss(true);
        _assertAttemptFailed(_openMarket());
        assertEq(http.callCount(), 0, "must not call without an executor");
    }

    function test_resolve_failsWhenTheRegistryIsUnreachable() public {
        registry.setRevertOnPick(true);
        _assertAttemptFailed(_openMarket());
    }

    function test_resolve_failsWhenTheHttpCallIsRejected() public {
        http.setRejectCall(true);
        _assertAttemptFailed(_openMarket());
    }

    function test_resolve_failsOnANonSuccessStatus() public {
        http.setResponse(503, ORACLE_BODY);
        _assertAttemptFailed(_openMarket());
    }

    function test_resolve_failsOnAnEmptyBody() public {
        http.setResponse(200, bytes(""));
        _assertAttemptFailed(_openMarket());
    }

    function test_resolve_failsWhileTheResponseIsStillUnsettled() public {
        http.setUnsettled(true);
        _assertAttemptFailed(_openMarket());
    }

    function test_resolve_failsWhenTheExecutorReportsAnError() public {
        http.setErrorMessage("dns lookup failed");
        _assertAttemptFailed(_openMarket());
    }

    function test_resolve_failsWhenJsonPathYieldsNothing() public {
        jq.setEmptyResult(true);
        _assertAttemptFailed(_openMarket());
    }

    /// The property the whole design rests on: an unreadable oracle is never a NO.
    function test_resolve_neverReadsAFailureAsAnOutcome() public {
        uint256 id = _openMarket();
        http.setResponse(500, ORACLE_BODY);

        _closeAndFire(id);

        assertEq(uint8(_outcome(id)), uint8(RitualPredict.Outcome.Unresolved));
        assertTrue(_state(id) != RitualPredict.MarketState.Resolved);
    }

    function test_resolve_becomesInvalidOnlyAfterTheLastAttempt() public {
        uint256 id = _openMarket();
        http.setResponse(500, ORACLE_BODY);
        _closeBetting(id);

        uint8 maxAttempts = uint8(predict.MAX_ATTEMPTS());
        for (uint8 i = 0; i < maxAttempts - 1; i++) {
            _fire(id, i);
            assertEq(
                uint8(_state(id)),
                uint8(RitualPredict.MarketState.Resolving),
                "gave up too early"
            );
        }

        _fire(id, maxAttempts - 1);
        assertEq(uint8(_state(id)), uint8(RitualPredict.MarketState.Invalid));
        assertEq(predict.getMarket(id).attempts, maxAttempts);
    }

    function test_resolve_canStillSucceedOnALaterAttempt() public {
        uint256 id = _openMarket();
        http.setResponse(500, ORACLE_BODY);
        _closeBetting(id);

        _fire(id, 0);
        assertEq(uint8(_state(id)), uint8(RitualPredict.MarketState.Resolving));

        http.setResponse(200, ORACLE_BODY);
        jq.setValue(4200);
        _fire(id, 1);

        assertEq(uint8(_state(id)), uint8(RitualPredict.MarketState.Resolved));
        assertEq(uint8(_outcome(id)), uint8(RitualPredict.Outcome.Yes));
    }

    function test_resolve_alwaysDrawsFromTheAttestedSet() public {
        address[] memory executors = new address[](2);
        executors[0] = EXECUTOR_A;
        executors[1] = EXECUTOR_B;
        registry.setExecutors(executors);

        uint256 id = _openMarket();
        http.setResponse(500, ORACLE_BODY);
        _closeBetting(id);

        // The seed folds in the execution index, so each attempt draws again.
        for (uint8 i = 0; i < 3; i++) {
            _fire(id, i);
            address used = http.requestedExecutor();
            assertTrue(
                used == EXECUTOR_A || used == EXECUTOR_B,
                "executor came from outside the registry"
            );
        }
    }

    // ────────────────────────────── helpers ───────────────────────────────

    function _openMarket() private returns (uint256 id) {
        id = _create();
        _bet(id, ALICE, true, 1 ether);
        _bet(id, BOB, false, 1 ether);
    }

    function _assertAttemptFailed(uint256 id) private {
        _closeAndFire(id);

        assertEq(
            uint8(_state(id)),
            uint8(RitualPredict.MarketState.Resolving),
            "a failed read must leave the market unresolved"
        );
        assertEq(uint8(_outcome(id)), uint8(RitualPredict.Outcome.Unresolved));
        assertEq(predict.getMarket(id).attempts, 1);
    }

    function _assertComparator(
        RitualPredict.Comparator comparator,
        uint256 target,
        uint256 observed,
        bool expectYes
    ) private {
        uint256 id = _createWith(target, comparator);
        _bet(id, ALICE, true, 1 ether);
        _bet(id, BOB, false, 1 ether);
        jq.setValue(observed);

        _closeAndFire(id);

        assertEq(
            uint8(_outcome(id)),
            uint8(
                expectYes ? RitualPredict.Outcome.Yes : RitualPredict.Outcome.No
            ),
            "comparator disagreed"
        );
    }
}
