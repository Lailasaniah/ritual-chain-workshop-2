// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PredictBase} from "./PredictBase.t.sol";
import {RitualPredict} from "../RitualPredict.sol";

/// Payouts, refunds, and the prepaid execution balance.
contract SettlementTest is PredictBase {
    function test_claimWinnings_paysTheProportionalShare() public {
        uint256 id = _createWith(4000, RitualPredict.Comparator.GTE);
        _bet(id, ALICE, true, 3 ether);
        _bet(id, BOB, true, 1 ether);
        _bet(id, CAROL, false, 4 ether);
        _settleYes(id);

        // Pool is 8, winning side holds 4, so YES pays two for one.
        uint256 before = ALICE.balance;
        vm.prank(ALICE);
        predict.claimWinnings(id);
        assertEq(ALICE.balance - before, 6 ether);

        before = BOB.balance;
        vm.prank(BOB);
        predict.claimWinnings(id);
        assertEq(BOB.balance - before, 2 ether);

        // The pool is exactly emptied.
        assertEq(address(predict).balance, 0);
    }

    function test_claimWinnings_givesASoleWinnerTheWholePool() public {
        uint256 id = _createWith(4000, RitualPredict.Comparator.GTE);
        _bet(id, ALICE, true, 1 ether);
        _bet(id, BOB, false, 9 ether);
        _settleYes(id);

        uint256 before = ALICE.balance;
        vm.prank(ALICE);
        predict.claimWinnings(id);
        assertEq(ALICE.balance - before, 10 ether);
    }

    function test_claimWinnings_rejectsTheLosingSide() public {
        uint256 id = _createWith(4000, RitualPredict.Comparator.GTE);
        _bet(id, ALICE, true, 1 ether);
        _bet(id, BOB, false, 1 ether);
        _settleYes(id);

        vm.prank(BOB);
        vm.expectRevert(RitualPredict.NothingToClaim.selector);
        predict.claimWinnings(id);
    }

    function test_claimWinnings_rejectsADoubleClaim() public {
        uint256 id = _createWith(4000, RitualPredict.Comparator.GTE);
        _bet(id, ALICE, true, 1 ether);
        _bet(id, BOB, false, 1 ether);
        _settleYes(id);

        vm.prank(ALICE);
        predict.claimWinnings(id);

        vm.prank(ALICE);
        vm.expectRevert(RitualPredict.AlreadySettled.selector);
        predict.claimWinnings(id);
    }

    function test_claimWinnings_rejectsAMarketThatIsNotResolved() public {
        uint256 id = _create();
        _bet(id, ALICE, true, 1 ether);

        vm.prank(ALICE);
        vm.expectRevert(RitualPredict.NotResolved.selector);
        predict.claimWinnings(id);
    }

    function test_stakesOf_reportsWhatIsClaimable() public {
        uint256 id = _createWith(4000, RitualPredict.Comparator.GTE);
        _bet(id, ALICE, true, 1 ether);
        _bet(id, BOB, false, 3 ether);
        _settleYes(id);

        (, , bool alreadySettled, uint256 claimable) = predict.stakesOf(
            id,
            ALICE
        );
        assertFalse(alreadySettled);
        assertEq(claimable, 4 ether);

        vm.prank(ALICE);
        predict.claimWinnings(id);

        (, , alreadySettled, claimable) = predict.stakesOf(id, ALICE);
        assertTrue(alreadySettled);
        assertEq(claimable, 0);
    }

    // ────────────────────────────── refunds ───────────────────────────────

    function test_claimRefund_returnsEveryStakeFromAnInvalidMarket() public {
        uint256 id = _invalidMarket();

        uint256 before = BOB.balance;
        vm.prank(BOB);
        predict.claimRefund(id);
        assertEq(BOB.balance - before, 2 ether);
    }

    function test_claimRefund_rejectsAResolvedMarket() public {
        uint256 id = _createWith(4000, RitualPredict.Comparator.GTE);
        _bet(id, ALICE, true, 1 ether);
        _settleYes(id);

        vm.prank(ALICE);
        vm.expectRevert(RitualPredict.NotInvalid.selector);
        predict.claimRefund(id);
    }

    function test_claimRefund_rejectsADoubleRefund() public {
        uint256 id = _invalidMarket();

        vm.prank(BOB);
        predict.claimRefund(id);

        vm.prank(BOB);
        vm.expectRevert(RitualPredict.AlreadySettled.selector);
        predict.claimRefund(id);
    }

    function test_claimRefund_rejectsSomeoneWhoNeverStaked() public {
        uint256 id = _invalidMarket();

        vm.prank(CAROL);
        vm.expectRevert(RitualPredict.NothingToClaim.selector);
        predict.claimRefund(id);
    }

    // ───────────────────────── execution funding ──────────────────────────

    function test_fundExecution_depositsIntoTheContractsWalletBalance() public {
        assertEq(predict.executionBalance(), 0);

        vm.prank(ALICE);
        predict.fundExecution{value: 2 ether}(5000);

        assertEq(predict.executionBalance(), 2 ether);
        assertEq(wallet.lockUntil(address(predict)), block.number + 5000);
    }

    function test_fundExecution_rejectsAZeroDeposit() public {
        vm.prank(ALICE);
        vm.expectRevert(RitualPredict.ZeroStake.selector);
        predict.fundExecution{value: 0}(5000);
    }

    function test_fundExecution_acceptsTopUpsFromAnyone() public {
        vm.prank(ALICE);
        predict.fundExecution{value: 1 ether}(100);
        vm.prank(BOB);
        predict.fundExecution{value: 1 ether}(100);

        assertEq(predict.executionBalance(), 2 ether);
    }

    // ─────────────────────────────── fuzz ─────────────────────────────────

    function testFuzz_payoutsNeverExceedThePool(
        uint96 yesA,
        uint96 yesB,
        uint96 no
    ) public {
        uint256 a = bound(yesA, 1, 1e24);
        uint256 b = bound(yesB, 1, 1e24);
        uint256 c = bound(no, 1, 1e24);

        vm.deal(ALICE, a);
        vm.deal(BOB, b);
        vm.deal(CAROL, c);

        uint256 id = _createWith(4000, RitualPredict.Comparator.GTE);
        _bet(id, ALICE, true, a);
        _bet(id, BOB, true, b);
        _bet(id, CAROL, false, c);
        _settleYes(id);

        uint256 pool = a + b + c;

        vm.prank(ALICE);
        predict.claimWinnings(id);
        vm.prank(BOB);
        predict.claimWinnings(id);

        uint256 paid = pool - address(predict).balance;
        assertLe(paid, pool, "paid out more than was staked");
        // Integer division can only ever leave dust behind, never overdraw.
        assertLe(pool - paid, 2, "unexpected remainder");
    }

    function testFuzz_refundsReturnExactlyWhatWasStaked(
        uint96 first,
        uint96 second
    ) public {
        uint256 a = bound(first, 1, 1e24);
        uint256 b = bound(second, 1, 1e24);

        vm.deal(ALICE, a);
        vm.deal(BOB, b);

        // Nobody backs YES, and YES is what the oracle says wins.
        uint256 id = _createWith(4000, RitualPredict.Comparator.GTE);
        _bet(id, ALICE, false, a);
        _bet(id, BOB, false, b);
        jq.setValue(4200);
        _closeAndFire(id);

        assertEq(uint8(_state(id)), uint8(RitualPredict.MarketState.Invalid));

        vm.prank(ALICE);
        predict.claimRefund(id);
        vm.prank(BOB);
        predict.claimRefund(id);

        assertEq(ALICE.balance, a);
        assertEq(BOB.balance, b);
        assertEq(address(predict).balance, 0);
    }

    // ────────────────────────────── helpers ───────────────────────────────

    /// Drive a market all the way to Resolved with YES winning.
    function _settleYes(uint256 id) private {
        jq.setValue(4200);
        _closeAndFire(id);
        assertEq(
            uint8(_state(id)),
            uint8(RitualPredict.MarketState.Resolved),
            "setup failed to resolve"
        );
    }

    /// A market that ends up refundable, via the empty winning side path.
    function _invalidMarket() private returns (uint256 id) {
        id = _createWith(4000, RitualPredict.Comparator.GTE);
        _bet(id, BOB, false, 2 ether);
        jq.setValue(4200);
        _closeAndFire(id);
        assertEq(uint8(_state(id)), uint8(RitualPredict.MarketState.Invalid));
    }
}
