import assert from "node:assert/strict";
import { before, describe, it } from "node:test";

import { network } from "hardhat";

/**
 * End to end, the way a user meets this contract: create a market, stake on both
 * sides, let the Scheduler wake the contract, and claim.
 *
 * The Solidity suite covers the branches. This file exists to prove the pieces fit
 * together through a real provider, with real transactions and real receipts.
 *
 * Canonical Ritual addresses, occupied here by mocks through hardhat_setCode.
 */
const HTTP = "0x0000000000000000000000000000000000000801";
const JQ = "0x0000000000000000000000000000000000000803";
const SCHEDULER = "0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B";
const RITUAL_WALLET = "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948";
const TEE_REGISTRY = "0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F";

const BLOCK_TIME_MS = 195n;
const ORACLE_URL = "https://oracle.example/eth";

/**
 * hardhat_setCode installs runtime code but no storage and runs no constructor, so
 * every mock below starts fully zeroed and is configured explicitly afterwards.
 */
async function etchRitualSystem(connection: any) {
  const { viem, provider } = connection;
  const publicClient = await viem.getPublicClient();

  const pairs: [string, string][] = [
    ["MockScheduler", SCHEDULER],
    ["MockRitualWallet", RITUAL_WALLET],
    ["MockTeeRegistry", TEE_REGISTRY],
    ["MockHttp", HTTP],
    ["MockJq", JQ],
  ];

  for (const [name, target] of pairs) {
    const impl = await viem.deployContract(name);
    const code = await publicClient.getCode({ address: impl.address });
    await provider.request({ method: "hardhat_setCode", params: [target, code] });
  }
}

describe("RitualPredict, end to end", async () => {
  const connection = await network.create();
  const { viem, networkHelpers, provider } = connection;

  let predict: any;
  let http: any;
  let jq: any;
  let scheduler: any;
  let registry: any;
  let alice: any;
  let bob: any;

  before(async () => {
    [alice, bob] = await viem.getWalletClients();

    await etchRitualSystem(connection);

    scheduler = await viem.getContractAt("MockScheduler", SCHEDULER);
    registry = await viem.getContractAt("MockTeeRegistry", TEE_REGISTRY);
    http = await viem.getContractAt("MockHttp", HTTP);
    jq = await viem.getContractAt("MockJq", JQ);

    // The Scheduler has to hold code before this line: the constructor calls
    // approveScheduler on it.
    predict = await viem.deployContract("RitualPredict", [BLOCK_TIME_MS]);

    await registry.write.setExecutors([[alice.account.address]]);
  });

  async function createMarket() {
    await predict.write.createMarket([
      {
        question: "Will ETH be at least 4000 dollars?",
        oracleUrl: ORACLE_URL,
        jsonPath: ".price",
        target: 4000n,
        comparator: 1, // GTE
        bettingSeconds: 60n,
        resolveDelaySeconds: 30n,
      },
    ]);
    return predict.read.marketCount();
  }

  /// Walk the chain forward until betting on this market is over.
  async function closeBetting(marketId: bigint) {
    const market = await predict.read.getMarket([marketId]);
    const publicClient = await viem.getPublicClient();
    const now = await publicClient.getBlockNumber();
    if (market.closeBlock > now) {
      await networkHelpers.mine(Number(market.closeBlock - now));
    }
  }

  /**
   * Run one booked execution.
   *
   * The gas limit is pinned deliberately. The mock Scheduler swallows a failed
   * callback exactly as the real one does, so an estimate taken from a simulation
   * where the inner call fails early is far too small to run the callback for real,
   * and the transaction then succeeds while doing nothing at all.
   */
  async function fire(marketId: bigint, executionIndex: bigint) {
    const market = await predict.read.getMarket([marketId]);
    await scheduler.write.fire([market.scheduleId, executionIndex], {
      gas: 3_000_000n,
    });
  }

  it("settles itself from the oracle and pays the winning side", async () => {
    await http.write.setResponse([200, "0x7b227072696365223a343230307d"]); // {"price":4200}
    await jq.write.setValue([4200n]);

    const marketId = await createMarket();

    await predict.write.bet([marketId, true], {
      value: 10n ** 18n,
      account: alice.account,
    });
    await predict.write.bet([marketId, false], {
      value: 3n * 10n ** 18n,
      account: bob.account,
    });

    await closeBetting(marketId);
    await fire(marketId, 0n);

    // The mock is the only witness that the request actually left the contract.
    assert.equal(await http.read.callCount(), 1n, "oracle was never read");
    assert.equal(await http.read.requestedUrl(), ORACLE_URL);

    const market = await predict.read.getMarket([marketId]);
    assert.equal(market.state, 3, "expected Resolved");
    assert.equal(market.outcome, 1, "expected YES");
    assert.equal(market.observedValue, 4200n);

    // Sole winner on the YES side takes the whole 4 RITUAL pool.
    const [, , , claimable] = await predict.read.stakesOf([
      marketId,
      alice.account.address,
    ]);
    assert.equal(claimable, 4n * 10n ** 18n);

    await predict.write.claimWinnings([marketId], { account: alice.account });

    const publicClient = await viem.getPublicClient();
    assert.equal(
      await publicClient.getBalance({ address: predict.address }),
      0n,
      "pool should be empty after the only winner claims",
    );
  });

  it("becomes refundable when the oracle never answers", async () => {
    await http.write.setResponse([503, "0x"]);

    const marketId = await createMarket();
    await predict.write.bet([marketId, true], {
      value: 10n ** 18n,
      account: alice.account,
    });
    await predict.write.bet([marketId, false], {
      value: 10n ** 18n,
      account: bob.account,
    });

    await closeBetting(marketId);

    const maxAttempts = await predict.read.MAX_ATTEMPTS();
    for (let i = 0n; i < maxAttempts; i++) {
      await fire(marketId, i);
    }

    const market = await predict.read.getMarket([marketId]);
    assert.equal(market.state, 4, "expected Invalid");
    assert.equal(market.outcome, 0, "a failed read must never become an outcome");
    assert.equal(market.attempts, Number(maxAttempts));

    await predict.write.claimRefund([marketId], { account: alice.account });
    await predict.write.claimRefund([marketId], { account: bob.account });

    const publicClient = await viem.getPublicClient();
    assert.equal(
      await publicClient.getBalance({ address: predict.address }),
      0n,
      "every stake should have gone back",
    );
  });
});
