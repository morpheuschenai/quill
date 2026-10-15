import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";
import Redis from "ioredis";
import { BILLING_COMMIT_SCRIPT, CHECKOUT_RELEASE_SCRIPT } from "./server.ts";

// Opt in only to an explicitly supplied local, isolated Redis socket.
const socket = process.env.REDIS_TEST_SOCKET;
const options = { skip: !socket && "REDIS_TEST_SOCKET is required", timeout: 10_000 };

async function fixture(run: (redis: Redis, keys: string[]) => Promise<void>) {
  const redis = new Redis({ path: socket!, lazyConnect: true, retryStrategy: () => null });
  const prefix = `quill:billing-test:${randomUUID()}`;
  const keys = ["subscription", "index", "receipts", "purchases"].map((name) => `${prefix}:${name}`);
  try {
    await redis.connect();
    await run(redis, keys);
  } finally {
    try {
      if (redis.status === "ready") await redis.del(...keys);
    } finally {
      redis.disconnect();
    }
  }
}

function commit(redis: Redis, keys: string[], value: string, receipt: string, previous = "") {
  return redis.eval(
    BILLING_COMMIT_SCRIPT, 4, ...keys,
    value, "fixed-owner", receipt, previous, 3600, `purchase:${receipt}`,
  );
}

test("billing reverse owner cannot be reassigned and release cannot erase a newer checkout", options, async () => {
  await fixture(async (redis, keys) => {
    await redis.set(keys[1], "another-owner");
    assert.equal(await commit(redis, keys, "active", "receipt"), -1);
    assert.equal(await redis.get(keys[0]), null);
    assert.equal(await redis.get(keys[1]), "another-owner");
    await redis.set(keys[0], "new-order");
    assert.equal(await redis.eval(CHECKOUT_RELEASE_SCRIPT, 1, keys[0], "old-order"), 0);
    assert.equal(await redis.get(keys[0]), "new-order");
    assert.equal(await redis.eval(CHECKOUT_RELEASE_SCRIPT, 1, keys[0], "new-order"), 1);
  });
});

async function snapshot(redis: Redis, keys: string[]) {
  return Promise.all(keys.map(async (key) => ({
    type: await redis.type(key),
    value: (await redis.dumpBuffer(key))?.toString("hex") ?? null,
  })));
}

test("billing commit writes all four keys and expires both sets", options, async () => {
  await fixture(async (redis, keys) => {
    assert.equal(await commit(redis, keys, "active", "delivery-1"), 1);
    assert.equal(await redis.get(keys[0]), "active");
    assert.equal(await redis.get(keys[1]), "fixed-owner");
    assert.deepEqual(await redis.smembers(keys[2]), ["delivery-1"]);
    assert.deepEqual(await redis.smembers(keys[3]), ["purchase:delivery-1"]);
    for (const key of keys.slice(2)) {
      const ttl = await redis.ttl(key);
      assert.ok(ttl > 0 && ttl <= 3600);
    }
  });
});

test("duplicate billing receipt does not overwrite any key", options, async () => {
  await fixture(async (redis, keys) => {
    assert.equal(await commit(redis, keys, "active", "delivery-1"), 1);
    const before = await snapshot(redis, keys);
    assert.equal(await commit(redis, keys, "cancelled", "delivery-1", "active"), 0);
    assert.deepEqual(await snapshot(redis, keys), before);
  });
});

test("concurrent billing CAS admits one writer and the losing receipt can retry", options, async () => {
  await fixture(async (redis, keys) => {
    await redis.set(keys[0], "original");
    const other = redis.duplicate({ lazyConnect: true });
    try {
      await other.connect();
      const results = await Promise.all([
        commit(redis, keys, "first", "delivery-first", "original"),
        commit(other, keys, "second", "delivery-second", "original"),
      ]);
      assert.deepEqual([...results].sort(), [-1, 1]);
      const winner = results[0] === 1 ? "first" : "second";
      const loser = winner === "first" ? "second" : "first";
      assert.equal(await redis.get(keys[0]), winner);
      assert.equal(await redis.get(keys[1]), "fixed-owner");
      assert.deepEqual(await redis.smembers(keys[2]), [`delivery-${winner}`]);
      assert.deepEqual(await redis.smembers(keys[3]), [`purchase:delivery-${winner}`]);
      assert.equal(await redis.sismember(keys[2], `delivery-${loser}`), 0);
      assert.equal(await commit(other, keys, loser, `delivery-${loser}`, winner), 1);
      assert.equal(await redis.get(keys[0]), loser);
      assert.equal(await redis.get(keys[1]), "fixed-owner");
      assert.deepEqual((await redis.smembers(keys[2])).sort(), ["delivery-first", "delivery-second"]);
      assert.deepEqual((await redis.smembers(keys[3])).sort(), ["purchase:delivery-first", "purchase:delivery-second"]);
    } finally {
      other.disconnect();
    }
  });
});

for (let invalidIndex = 0; invalidIndex < 4; invalidIndex++) {
  test(`WRONGTYPE in billing key ${invalidIndex + 1} rejects without partial changes`, options, async () => {
    await fixture(async (redis, keys) => {
      await redis.set(keys[0], "original");
      await redis.set(keys[1], "original-index");
      await redis.sadd(keys[2], "existing-receipt");
      await redis.sadd(keys[3], "existing-purchase");
      await redis.del(keys[invalidIndex]);
      await redis.rpush(keys[invalidIndex], "wrong-type-sentinel");
      const before = await snapshot(redis, keys);
      await assert.rejects(commit(redis, keys, "updated", "new-receipt", "original"), /Invalid billing key type|WRONGTYPE/);
      assert.deepEqual(await snapshot(redis, keys), before);
      for (const key of keys) assert.equal(await redis.ttl(key), -1);
    });
  });
}
