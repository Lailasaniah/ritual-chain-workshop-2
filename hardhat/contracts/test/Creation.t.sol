// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PredictBase} from "./PredictBase.t.sol";
import {RitualPredict} from "../RitualPredict.sol";
import {MockScheduler} from "../mocks/MockSystem.sol";

/// createMarket: validation, the block deadlines, and the Scheduler booking.
contract CreationTest is PredictBase {
    function test_constructor_rejectsAZeroBlockTime() public {
        vm.expectRevert(RitualPredict.BadDuration.selector);
        new RitualPredict(0);
    }

    function test_createMarket_numbersMarketsFromOne() public {
        assertEq(predict.marketCount(), 0);
        assertEq(_create(), 1);
        assertEq(_create(), 2);
        assertEq(predict.marketCount(), 2);
    }

    function test_createMarket_storesTheRuleVerbatim() public {
        uint256 id = _create();
        RitualPredict.Market memory m = predict.getMarket(id);

        assertEq(m.creator, ALICE);
        assertEq(m.oracleUrl, ORACLE_URL);
        assertEq(m.jsonPath, JSON_PATH);
        assertEq(m.target, 4000);
        assertEq(uint8(m.comparator), uint8(RitualPredict.Comparator.GTE));
        assertEq(uint8(m.state), uint8(RitualPredict.MarketState.Open));
        assertEq(uint8(m.outcome), uint8(RitualPredict.Outcome.Unresolved));
        assertEq(m.attempts, 0);
        assertEq(m.totalYes, 0);
        assertEq(m.totalNo, 0);
    }

    function test_createMarket_derivesBothDeadlinesFromBlockTime() public {
        uint256 start = block.number;
        uint256 id = _create();
        RitualPredict.Market memory m = predict.getMarket(id);

        // seconds * 1000 / blockTimeMs, truncated.
        uint256 bettingBlocks = (BETTING_SECONDS * 1000) / BLOCK_TIME_MS;
        uint256 resolveBlocks = (RESOLVE_DELAY_SECONDS * 1000) / BLOCK_TIME_MS;

        assertEq(m.closeBlock, start + bettingBlocks);
        assertEq(m.resolveBlock, m.closeBlock + resolveBlocks);
    }

    function test_createMarket_neverExistsWithoutItsBooking() public {
        scheduler.setRejectSchedule(true);

        vm.prank(ALICE);
        vm.expectRevert();
        predict.createMarket(_newMarketParams());

        // The counter was bumped before the booking was attempted, so this also
        // proves the whole creation unwound rather than leaving a hole.
        assertEq(predict.marketCount(), 0);
    }

    function test_createMarket_booksTheAttemptsItPromises() public {
        uint256 id = _create();
        RitualPredict.Market memory m = predict.getMarket(id);
        MockScheduler.Booking memory b = scheduler.booking(m.scheduleId);

        assertEq(b.target, address(predict));
        assertEq(b.payer, address(predict));
        assertEq(b.gas, predict.RESOLVE_GAS_LIMIT());
        assertEq(b.numCalls, predict.MAX_ATTEMPTS());
        assertEq(b.frequency, predict.RETRY_INTERVAL_BLOCKS());
        assertEq(b.ttl, predict.SCHEDULER_TTL_BLOCKS());
        assertEq(b.startBlock, m.resolveBlock);
        assertGe(b.maxFeePerGas, predict.MIN_MAX_FEE_PER_GAS());
    }

    function test_createMarket_leavesAZeroExecutionIndexPlaceholder() public {
        uint256 id = _create();
        bytes memory data = scheduler
            .booking(predict.getMarket(id).scheduleId)
            .data;

        // selector + two words
        assertEq(data.length, 68);

        bytes4 selector;
        uint256 placeholder;
        uint256 encodedMarketId;
        assembly {
            selector := mload(add(data, 0x20))
            placeholder := mload(add(data, 0x24))
            encodedMarketId := mload(add(data, 0x44))
        }

        assertEq(
            uint32(selector),
            uint32(predict.onScheduledResolve.selector),
            "callback selector"
        );
        // The Scheduler overwrites exactly these bytes at execution time.
        assertEq(placeholder, 0, "executionIndex placeholder");
        assertEq(encodedMarketId, id, "marketId argument");
    }

    function test_createMarket_approvedTheSchedulerAtDeployTime() public view {
        assertTrue(scheduler.approved(address(scheduler)));
    }

    // ───────────────────────────── validation ─────────────────────────────

    function test_createMarket_rejectsAnEmptyQuestion() public {
        RitualPredict.NewMarket memory p = _newMarketParams();
        p.question = "";
        _expectCreateRevert(p, RitualPredict.EmptyString.selector);
    }

    function test_createMarket_rejectsAnEmptyOracleUrl() public {
        RitualPredict.NewMarket memory p = _newMarketParams();
        p.oracleUrl = "";
        _expectCreateRevert(p, RitualPredict.EmptyString.selector);
    }

    function test_createMarket_rejectsAnEmptyJsonPath() public {
        RitualPredict.NewMarket memory p = _newMarketParams();
        p.jsonPath = "";
        _expectCreateRevert(p, RitualPredict.EmptyString.selector);
    }

    function test_createMarket_rejectsTooShortABettingWindow() public {
        RitualPredict.NewMarket memory p = _newMarketParams();
        p.bettingSeconds = predict.MIN_BETTING_SECONDS() - 1;
        _expectCreateRevert(p, RitualPredict.BadDuration.selector);
    }

    function test_createMarket_rejectsTooShortAResolveDelay() public {
        RitualPredict.NewMarket memory p = _newMarketParams();
        p.resolveDelaySeconds = predict.MIN_RESOLVE_DELAY_SECONDS() - 1;
        _expectCreateRevert(p, RitualPredict.BadDuration.selector);
    }

    function test_createMarket_rejectsAMarketLongerThanADay() public {
        RitualPredict.NewMarket memory p = _newMarketParams();
        p.bettingSeconds = predict.MAX_MARKET_SECONDS();
        p.resolveDelaySeconds = predict.MIN_RESOLVE_DELAY_SECONDS();
        _expectCreateRevert(p, RitualPredict.BadDuration.selector);
    }

    function test_createMarket_acceptsTheExactMinimums() public {
        RitualPredict.NewMarket memory p = _newMarketParams();
        p.bettingSeconds = predict.MIN_BETTING_SECONDS();
        p.resolveDelaySeconds = predict.MIN_RESOLVE_DELAY_SECONDS();

        vm.prank(ALICE);
        assertEq(predict.createMarket(p), 1);
    }

    function _expectCreateRevert(
        RitualPredict.NewMarket memory p,
        bytes4 expected
    ) private {
        vm.prank(ALICE);
        vm.expectRevert(expected);
        predict.createMarket(p);
    }
}
