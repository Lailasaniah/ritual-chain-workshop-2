// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {RitualPredict} from "../RitualPredict.sol";
import {RitualChain} from "../ritual/RitualChain.sol";
import {MockHttp} from "../mocks/MockHttp.sol";
import {MockJq} from "../mocks/MockJq.sol";
import {MockScheduler, MockRitualWallet, MockTeeRegistry} from "../mocks/MockSystem.sol";

/**
 * Shared rig for every test in this folder.
 *
 * Two ordering rules matter and both are easy to get wrong:
 *
 * 1. The Scheduler must be etched before RitualPredict is deployed, because the
 *    constructor calls approveScheduler on it. Deploying first gives a revert with
 *    no message, since a high-level call into an address holding no code fails the
 *    extcodesize check before it ever runs.
 *
 * 2. vm.etch copies runtime code but not storage, and it never runs a constructor,
 *    so every mock lands fully zeroed. Nothing here is configured implicitly; each
 *    test states the world it depends on.
 *
 * No contract in this file has a test function, so it is a base, not a suite.
 */
abstract contract PredictBase is Test {
    RitualPredict internal predict;

    MockHttp internal http;
    MockJq internal jq;
    MockScheduler internal scheduler;
    MockRitualWallet internal wallet;
    MockTeeRegistry internal registry;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant EXECUTOR_A = address(0xE0A);
    address internal constant EXECUTOR_B = address(0xE0B);

    /// Ritual ran about this fast when the workshop was written.
    uint256 internal constant BLOCK_TIME_MS = 195;

    uint256 internal constant BETTING_SECONDS = 60;
    uint256 internal constant RESOLVE_DELAY_SECONDS = 30;

    string internal constant ORACLE_URL = "https://oracle.example/eth";
    string internal constant JSON_PATH = ".price";
    bytes internal constant ORACLE_BODY = bytes('{"price":4200}');

    function setUp() public virtual {
        _etchRitualSystem();

        predict = new RitualPredict(BLOCK_TIME_MS);

        // A world where everything works. Individual tests break one piece of it.
        address[] memory executors = new address[](1);
        executors[0] = EXECUTOR_A;
        registry.setExecutors(executors);

        http.setResponse(200, ORACLE_BODY);
        jq.setValue(4200);

        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);
        vm.deal(CAROL, 100 ether);
    }

    function _etchRitualSystem() private {
        vm.etch(RitualChain.SCHEDULER, address(new MockScheduler()).code);
        vm.etch(RitualChain.RITUAL_WALLET, address(new MockRitualWallet()).code);
        vm.etch(
            RitualChain.TEE_SERVICE_REGISTRY,
            address(new MockTeeRegistry()).code
        );
        vm.etch(RitualChain.HTTP_PRECOMPILE, address(new MockHttp()).code);
        vm.etch(RitualChain.JQ_PRECOMPILE, address(new MockJq()).code);

        scheduler = MockScheduler(RitualChain.SCHEDULER);
        wallet = MockRitualWallet(RitualChain.RITUAL_WALLET);
        registry = MockTeeRegistry(RitualChain.TEE_SERVICE_REGISTRY);
        http = MockHttp(RitualChain.HTTP_PRECOMPILE);
        jq = MockJq(RitualChain.JQ_PRECOMPILE);
    }

    // ───────────────────────────── conveniences ──────────────────────────────

    function _newMarketParams()
        internal
        pure
        returns (RitualPredict.NewMarket memory p)
    {
        p = RitualPredict.NewMarket({
            question: "Will ETH be at least 4000 dollars?",
            oracleUrl: ORACLE_URL,
            jsonPath: JSON_PATH,
            target: 4000,
            comparator: RitualPredict.Comparator.GTE,
            bettingSeconds: BETTING_SECONDS,
            resolveDelaySeconds: RESOLVE_DELAY_SECONDS
        });
    }

    function _create() internal returns (uint256 marketId) {
        vm.prank(ALICE);
        marketId = predict.createMarket(_newMarketParams());
    }

    function _createWith(
        uint256 target,
        RitualPredict.Comparator comparator
    ) internal returns (uint256 marketId) {
        RitualPredict.NewMarket memory p = _newMarketParams();
        p.target = target;
        p.comparator = comparator;

        vm.prank(ALICE);
        marketId = predict.createMarket(p);
    }

    function _bet(
        uint256 marketId,
        address who,
        bool isYes,
        uint256 amount
    ) internal {
        vm.prank(who);
        predict.bet{value: amount}(marketId, isYes);
    }

    /// Move past the betting window so a scheduled wake-up is allowed to act.
    function _closeBetting(uint256 marketId) internal {
        vm.roll(predict.getMarket(marketId).closeBlock);
    }

    /// Run one booked execution the way the Scheduler would.
    function _fire(uint256 marketId, uint256 executionIndex) internal {
        uint256 callId = predict.getMarket(marketId).scheduleId;
        scheduler.fire(callId, executionIndex);
    }

    /// Close betting and run the first attempt.
    function _closeAndFire(uint256 marketId) internal {
        _closeBetting(marketId);
        _fire(marketId, 0);
    }

    /// A wake-up straight from the Scheduler address, with no booking behind it.
    ///
    /// Needed because a settled market cancels its own booking, and the mock then
    /// rightly refuses to fire it. The contract still has to survive a callback
    /// that arrives anyway, which is a real race: an execution already in flight
    /// does not disappear because a cancellation landed after it.
    function _wakeDirectly(uint256 marketId, uint256 executionIndex) internal {
        vm.prank(RitualChain.SCHEDULER);
        predict.onScheduledResolve(executionIndex, marketId);
    }

    function _state(
        uint256 marketId
    ) internal view returns (RitualPredict.MarketState) {
        return predict.getMarket(marketId).state;
    }

    function _outcome(
        uint256 marketId
    ) internal view returns (RitualPredict.Outcome) {
        return predict.getMarket(marketId).outcome;
    }
}
