// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PredictBase} from "./PredictBase.t.sol";
import {RitualPredict} from "../RitualPredict.sol";

/// Staking, the close block, and the read-only views.
contract BettingTest is PredictBase {
    function test_bet_accumulatesPerSideAndPerAccount() public {
        uint256 id = _create();

        _bet(id, ALICE, true, 3 ether);
        _bet(id, BOB, true, 1 ether);
        _bet(id, BOB, false, 2 ether);

        RitualPredict.Market memory m = predict.getMarket(id);
        assertEq(m.totalYes, 4 ether);
        assertEq(m.totalNo, 2 ether);

        assertEq(predict.yesStake(id, ALICE), 3 ether);
        assertEq(predict.yesStake(id, BOB), 1 ether);
        assertEq(predict.noStake(id, BOB), 2 ether);
        assertEq(predict.noStake(id, ALICE), 0);
    }

    function test_bet_holdsTheStakeInTheContract() public {
        uint256 id = _create();
        _bet(id, ALICE, true, 5 ether);
        assertEq(address(predict).balance, 5 ether);
    }

    function test_bet_rejectsAZeroStake() public {
        uint256 id = _create();
        vm.prank(ALICE);
        vm.expectRevert(RitualPredict.ZeroStake.selector);
        predict.bet{value: 0}(id, true);
    }

    function test_bet_rejectsAnUnknownMarket() public {
        vm.prank(ALICE);
        vm.expectRevert(RitualPredict.UnknownMarket.selector);
        predict.bet{value: 1 ether}(99, true);
    }

    function test_bet_isAllowedOnTheBlockBeforeClose() public {
        uint256 id = _create();
        vm.roll(predict.getMarket(id).closeBlock - 1);

        _bet(id, ALICE, true, 1 ether);
        assertEq(predict.getMarket(id).totalYes, 1 ether);
    }

    function test_bet_stopsExactlyAtTheCloseBlock() public {
        uint256 id = _create();
        vm.roll(predict.getMarket(id).closeBlock);

        vm.prank(ALICE);
        vm.expectRevert(RitualPredict.BettingClosed.selector);
        predict.bet{value: 1 ether}(id, true);
    }

    // ─────────────────────────────── views ────────────────────────────────

    function test_getMarket_revertsForAnUnknownId() public {
        vm.expectRevert(RitualPredict.UnknownMarket.selector);
        predict.getMarket(1);
    }

    function test_getMarket_reportsClosedOnceTheBlockArrives() public {
        uint256 id = _create();
        assertEq(uint8(_state(id)), uint8(RitualPredict.MarketState.Open));

        // No transaction flips Open to Closed, so the view has to do it.
        vm.roll(predict.getMarket(id).closeBlock);
        assertEq(uint8(_state(id)), uint8(RitualPredict.MarketState.Closed));
    }

    function test_getMarkets_listsNewestFirst() public {
        uint256 first = _create();
        uint256 second = _create();
        uint256 third = _create();

        RitualPredict.Market[] memory all = predict.getMarkets();
        assertEq(all.length, 3);
        assertEq(all[0].id, third);
        assertEq(all[1].id, second);
        assertEq(all[2].id, first);
    }

    function test_getMarkets_isEmptyBeforeAnyMarketExists() public view {
        assertEq(predict.getMarkets().length, 0);
    }

    function test_stakesOf_reportsBothSidesAndNoClaimYet() public {
        uint256 id = _create();
        _bet(id, ALICE, true, 2 ether);
        _bet(id, ALICE, false, 1 ether);

        (uint256 yes, uint256 no, bool alreadySettled, uint256 claimable) = predict
            .stakesOf(id, ALICE);

        assertEq(yes, 2 ether);
        assertEq(no, 1 ether);
        assertFalse(alreadySettled);
        // Nothing is claimable while the market is still open.
        assertEq(claimable, 0);
    }
}
