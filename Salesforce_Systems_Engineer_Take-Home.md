# Salesforce Systems Engineer — Take-Home Assignment

**Candidate:** Vinay Manduva
**Date:** March 13, 2026
**Updated:** March 16, 2026 — Scale enhancements for high-volume production

---

## 1. System Architecture Flow

The following diagram illustrates the current trigger-based architecture for synchronizing Salesforce Orders to the ERP via the OrderSyncAPI middleware.

```
┌──────────────┐    trigger     ┌──────────────────┐    HTTP POST     ┌─────────────┐    transform     ┌─────┐
│  Order__c    │───────────────▶│ OrderSyncHandler │────────────────▶│ OrderSyncAPI │──────────────▶│ ERP │
│ (Salesforce) │  after update  │   (Apex class)   │    (sync call)   │ (Middleware) │               │     │
└──────────────┘                └──────────────────┘                  └─────────────┘                └─────┘
```

---

## 2. Debug & Explain — Defects Identified

After reviewing the original Apex trigger, handler class, sample payload, and the FinEng Slack transcript, I identified the following defects organized by symptom.

### 2.1 Missing Orders in ERP

| ID | Defect | Impact |
|----|--------|--------|
| **D1** | **Synchronous callout inside trigger context.** `OrderSyncHandler.syncOrder()` is invoked directly from `after update`. Apex prohibits HTTP callouts in trigger execution context, which will throw a `System.CalloutException` at runtime — the order is never posted. | **Critical** — all syncs silently fail. |
| **D2** | **No `Trigger.oldMap` guard.** The trigger fires on *every* update where `Status__c == 'Activated'`, not only when the status *transitions* to Activated. Any field edit on an already-activated order re-fires the sync, producing duplicate 409 responses in middleware and wasted governor limits. | **High** — duplicate POSTs, 409 conflicts. |
| **D7** | **Incomplete HTTP response handling.** 422 (Unprocessable Entity) and 5xx errors are not handled. A 422 from the middleware (e.g., `DISCOUNT_NULL`) falls through to the generic `else` and is silently swallowed by `System.debug`. 500s are likewise lost. | **High** — unrecoverable errors invisible to ops. |
| **D8** | **No 202 follow-up mechanism.** The handler logs "Accepted for async processing" but never polls for status or registers a callback. The middleware confirmed in Slack that it expects a poll or callback after 202 — neither exists. Orders accepted async are never finalized. | **High** — async-accepted orders permanently stuck. |
| **D9** | **Fire-and-forget error handling.** All failures are written to `System.debug`, which is ephemeral and unsearchable. There is no durable record (custom object, Platform Event, or alert) to trigger investigation or retry. | **High** — no audit trail for failures. |

### 2.2 Invoice Amount Mismatches

| ID | Defect | Impact |
|----|--------|--------|
| **D3** | **Null discount causes 422 rejection.** When `Discount__c` is null, it is sent as JSON `null`. The middleware rejects this with `422 DISCOUNT_NULL` ("discount must be provided or explicitly set to 0"). | **Critical** — all null-discount orders fail. |
| **D4** | **Uniform discount allocation produces wrong line amounts.** Discount is divided equally across lines: `o.Discount__c / o.OrderItems__r.size()`. This assigns the same dollar discount to a $7,500 line and a $2,000 line. For the sample payload: SUPPORT-PREM gets $500 off its $2,000 gross → $1,500, but the payload shows `"amount": 0.00`, proving further math errors or rounding compound the issue. | **Critical** — line amounts don't match ERP expectations. |
| **D5** | **Header `amount` is raw field value, not sum of lines.** The header sends `o.Amount__c` (10,000) while line amounts sum to a different number after discount allocation. The middleware (and ERP) expects `header amount == Σ line amounts`. Mismatch triggers validation failures. | **High** — header/line reconciliation fails. |
| **D6** | **Ignores CPQ-calculated `LineAmount__c`.** The `OrderItem__c` has a `LineAmount__c` field (likely the CPQ source of truth), but it is not used. Instead, line amounts are manually recalculated, diverging from what CPQ produced. | **Medium** — defeats CPQ as the pricing authority. |

### 2.3 Other Risks

| ID | Defect | Impact |
|----|--------|--------|
| **D10** | **No idempotency key.** The payload lacks a unique key the middleware can use for deduplication. Re-posts from retries or trigger re-fires produce genuinely different payloads (rounding drift), so the middleware can't safely deduplicate — it either rejects (409) or double-books. | **High** — fragile deduplication. |
| **D11** | **SOQL inside a loop.** The trigger iterates `Trigger.new` and calls `syncOrder(o.Id)` per record, each of which runs its own SOQL query. In bulk updates this will hit the 100-SOQL governor limit. | **Medium** — fails on bulk operations. |
| **D12** | **Hardcoded endpoint URL.** The endpoint is assembled from `URL.getSalesforceBaseUrl()`, which points back to the org itself, not an external middleware. This also bypasses Named Credentials, losing OAuth/auth management. | **Medium** — incorrect target + credential risk. |

---

## 3. Proposed Targeted Fixes

Each fix is scoped to the minimum change needed. Pseudocode and partial Apex are provided for clarity.

### Fix F1: Move Callout to Queueable with Chunked Chaining (→ D1, D11)

Convert the trigger to collect IDs and delegate to a `Queueable` job. This replaces `@future(callout=true)` which has a hard limit of 50 invocations per transaction — insufficient for high-volume bulk operations. The Queueable processes up to 50 orders per execution and chains a new job for any remainder, supporting unlimited batch sizes:

```apex
// Trigger — collect Ids, enqueue Queueable
trigger Order_AfterUpdate on Order__c (after update) {
    Set<Id> idsToSync = new Set<Id>();
    for (Order__c o : Trigger.new) {
        Order__c old = Trigger.oldMap.get(o.Id);
        if (o.Status__c == 'Activated' && old.Status__c != 'Activated')
            idsToSync.add(o.Id);
    }
    if (!idsToSync.isEmpty())
        System.enqueueJob(new OrderSyncQueueable(idsToSync));
}

// Queueable — chunked processing with chaining
public class OrderSyncQueueable implements Queueable, Database.AllowsCallouts {
    private static final Integer CHUNK_SIZE = 50;
    private List<Id> orderIdList;
    public OrderSyncQueueable(Set<Id> orderIds) { this.orderIdList = new List<Id>(orderIds); }
    public void execute(QueueableContext ctx) {
        List<Id> chunk = orderIdList.subList(0, Math.min(CHUNK_SIZE, orderIdList.size()));
        OrderSyncHandler.processSyncBatch(new Set<Id>(chunk));
        if (orderIdList.size() > CHUNK_SIZE) {
            System.enqueueJob(new OrderSyncQueueable(
                new List<Id>(orderIdList.subList(CHUNK_SIZE, orderIdList.size()))));
        }
    }
}

// Handler — processes a batch of orders with concurrent sync guard
public static void processSyncBatch(Set<Id> orderIds) {
    List<Order__c> orders = [SELECT ... FROM Order__c
        WHERE Id IN :orderIds AND Status__c = 'Activated'
        AND (Sync_Status__c = null OR Sync_Status__c NOT IN ('Synced','Pending'))];
    for (Order__c o : orders) {
        SyncResult result = syncSingleOrder(o);
        // persist result with partial-success DML (see F6, Scale Enhancements)
    }
}
```

This also resolves **D2** (oldMap guard) and **D11** (bulk SOQL).

### Fix F2: Null-Safe Discount (→ D3)

Default null discount to zero before payload construction:

```apex
Decimal discount = (o.Discount__c == null) ? 0 : o.Discount__c;
```

This ensures the JSON always sends a numeric value, preventing the middleware's `422 DISCOUNT_NULL`.

### Fix F3: Proportional Discount Allocation (→ D4)

Allocate discount to each line proportionally to its gross amount, with the last line absorbing the remainder to eliminate rounding drift:

```apex
Decimal grossTotal = 0;
for (OrderItem__c item : items) grossTotal += item.UnitPrice__c * item.Quantity__c;

Decimal runningDiscountSum = 0;
for (Integer i = 0; i < items.size(); i++) {
    Decimal lineGross = items[i].UnitPrice__c * items[i].Quantity__c;
    Decimal lineDiscount;
    if (i == items.size() - 1) {
        lineDiscount = discount - runningDiscountSum; // absorb remainder
    } else {
        lineDiscount = (lineGross / grossTotal * discount).setScale(2, RoundingMode.HALF_UP);
        runningDiscountSum += lineDiscount;
    }
    Decimal lineAmount = lineGross - lineDiscount;
    // add to payload...
}
```

### Fix F4: Derive Header Amount from Line Sum (→ D5)

Compute `amount` as the sum of all line `amount` values *after* discount allocation, guaranteeing `header == Σ lines`:

```apex
Decimal headerAmount = 0;
for (Map<String, Object> line : lines) {
    headerAmount += (Decimal) line.get('amount');
}
payload.put('amount', headerAmount);
```

### Fix F5: Idempotency Key (→ D10)

Add a stable, versioned key derived from `External_Id__c` + `LastModifiedDate` so the middleware can safely deduplicate retries:

```apex
String idempotencyKey = o.External_Id__c + '-' + String.valueOf(o.LastModifiedDate.getTime());
payload.put('idempotencyKey', idempotencyKey);
```

The middleware can use this to return 409 with confidence that the payload is truly a duplicate (same version), rather than a modified retry.

### Fix F6: Durable Error Logging & Status Tracking (→ D7, D9)

Introduce `Sync_Status__c` and `Sync_Error__c` fields on `Order__c`, plus an `Order_Sync_Log__c` child object for an immutable audit trail:

```apex
if (res.getStatusCode() == 200) {
    result.status = 'Synced';
    result.erpOrderId = (String) body.get('erpOrderId');
} else if (res.getStatusCode() == 202) {
    result.status = 'Pending';
    result.jobId = (String) body.get('jobId');
} else if (res.getStatusCode() == 409) {
    result.status = 'Synced'; // already exists
    result.erpOrderId = (String) body.get('existingErpOrderId');
} else if (res.getStatusCode() == 422) {
    result.status = 'Error';
    result.errorMessage = '422: ' + res.getBody();
} else if (res.getStatusCode() >= 500) {
    result.status = 'Error';
    result.errorMessage = '5xx: ' + res.getBody();
    result.isRetryable = true;
}
```

Each sync attempt produces an `Order_Sync_Log__c` record with timestamp, response code, payload hash, and error message. This gives Finance and Ops full visibility.

### Fix F7: 202 Polling via Queueable Job (→ D8)

When the middleware returns 202, enqueue a `Queueable` job that polls `/orders/status/{jobId}` with exponential backoff:

```apex
if (result.status == 'Pending' && String.isNotBlank(result.jobId)) {
    System.enqueueJob(new OrderSyncPollJob(o.Id, result.jobId, 0));
}
```

`OrderSyncPollJob` re-enqueues itself (up to a max attempt count) until the middleware reports `completed` or `failed`.

### Fix F8: Scheduled Retry for Transient Failures

A `Schedulable` + `Batchable` class (`OrderSyncRetryScheduler`) runs every 15 minutes, picks up orders with `Sync_Status__c = 'Error'` and `Sync_Is_Retryable__c = true`, and re-invokes `syncSingleOrder` with an incremented `Retry_Count__c`. After 5 retries, the order is flagged for manual review.

A new `Sync_Is_Retryable__c` checkbox on `Order__c` (set by the handler based on HTTP response classification) ensures that non-retryable errors (e.g., 422 validation) are never automatically retried — only transient failures (5xx, timeouts) are eligible.

### Fix F9: Named Credential for Endpoint (→ D12)

Replace the hardcoded URL with a Named Credential (`callout:OrderSyncAPI/orders`), which centralizes auth, enables admin management, and avoids leaking the middleware URL in code.

### Summary of Sample Payload — Before vs. After

| Field | Before (Buggy) | After (Fixed) |
|-------|----------------|---------------|
| `schemaVersion` | *(missing)* | `"2.0"` |
| `discount` | `null` (when empty) | `0` or actual value |
| Line CHAT-TEAM amount | 5,850.00 (equal split) | 6,653.85 (proportional) |
| Line API-COMMIT amount | 2,650.00 | 4,017.86 |
| Line SUPPORT-PREM amount | 0.00 | 1,828.29 |
| Header `amount` | 10,000 (raw field) | 12,500.00 → discounted to 8,500.00 (Σ lines) |
| `idempotencyKey` | *(missing)* | `EXT-12345-1741877400000` |

> **Note on D6 (CPQ LineAmount):** If Rev Ops confirms that `LineAmount__c` is the pricing source of truth, the handler should use it directly instead of recalculating. This is stubbed in the fix but gated behind confirmation to avoid overriding CPQ logic prematurely.

---

### Scale Enhancements for High-Volume Production

Beyond the defect fixes above, the following enhancements harden the system for high-throughput, zero-error production use at enterprise scale.

#### S1: Queueable with Chunked Chaining (→ replaces @future)

`@future(callout=true)` has a hard limit of 50 invocations per transaction. A data loader activating 51+ orders would silently fail. `OrderSyncQueueable` processes up to 50 orders per execution and chains a new Queueable for the remainder — supporting unlimited batch sizes.

#### S2: Partial-Success DML

All DML operations now use `Database.update(records, false)` and `Database.insert(records, false)`. If one record has a validation rule failure, other records in the batch still succeed. DML failures are logged individually.

#### S3: Concurrent Sync Guard

The `processSyncBatch` query filters out orders already in `Synced` or `Pending` status, preventing duplicate callouts from near-simultaneous trigger fires or race conditions between the initial sync and retry scheduler.

#### S4: HTTP Timeout (30s)

All HTTP callouts now set `req.setTimeout(30000)` explicitly. The Apex default of 10 seconds may cause false `CalloutException` timeouts when the middleware is under load.

#### S5: Circuit Breaker

Before sending any callouts, `processSyncBatch` checks the last 10 sync log entries within a 30-minute window. If all are errors (no successes), the circuit is "open" — callouts are skipped and orders are marked as retryable errors. This prevents cascading failures during a middleware outage. The circuit auto-closes when the retry scheduler processes orders and the middleware recovers.

```apex
@TestVisible
private static Boolean isCircuitOpen() {
    Datetime windowStart = Datetime.now().addMinutes(-CIRCUIT_BREAKER_WINDOW_MINUTES);
    List<Order_Sync_Log__c> recentLogs = [
        SELECT Status__c FROM Order_Sync_Log__c
        WHERE Sync_Timestamp__c >= :windowStart
        ORDER BY Sync_Timestamp__c DESC LIMIT :CIRCUIT_BREAKER_THRESHOLD
    ];
    if (recentLogs.size() < CIRCUIT_BREAKER_THRESHOLD) return false;
    for (Order_Sync_Log__c log : recentLogs) {
        if (log.Status__c == 'Synced' || log.Status__c == 'Pending') return false;
    }
    return true;
}
```

#### S6: Negative Amount / Excessive Discount Validation

`buildPayload` now validates that `discount ≤ grossTotal` and that no line amount is negative after discount allocation. Violations throw `OrderSyncException`, which is caught by `syncSingleOrder` and logged as a non-retryable error — preventing bad data from reaching the middleware.

#### S7: Schema Versioning

Every payload now includes `"schemaVersion": "2.0"`. This allows the middleware to negotiate or reject incompatible payloads during rolling deployments, avoiding silent data misinterpretation.

#### S8: Last_Sync_Attempt__c on Initial Sync

`Last_Sync_Attempt__c` is now set during the initial sync (not just retries). This ensures the retry scheduler's backoff filter (`Last_Sync_Attempt__c < cutoff`) correctly includes orders that failed on first attempt — previously, a null timestamp could prevent these orders from ever being retried.

#### S9: Sync_Is_Retryable__c on Order__c

A new `Sync_Is_Retryable__c` checkbox on `Order__c` stores whether the last failure is transient (set by HTTP response classification). The retry scheduler now filters on this field, ensuring that 422 validation errors are never automatically retried — only 5xx / timeout failures qualify.

#### S10: Exponential Backoff in PollJob

`OrderSyncPollJob` now implements both `Queueable` and `Schedulable`. Instead of immediately re-enqueuing (which consumed async Apex slots in tight loops), it schedules the next poll at `2^attempt` minutes (1, 2, 4, 8, … capped at 60 min). This prevents async slot exhaustion at scale.

#### S11: Platform Event Publish Verification

The retry scheduler's `finish()` method now checks `Database.SaveResult` from `EventBus.publish()`. A failed alert publish is logged rather than silently dropped.

---

## 4. Architecture — After Fixes

```
┌──────────────┐   trigger            ┌───────────────────┐   chunked       ┌──────────────────┐
│  Order__c    │─────────────────────▶│ OrderSyncQueueable│──────────────▶│ OrderSyncHandler │
│ (Salesforce) │  status change only  │ (Queueable chain) │  processBatch  │  (sync logic)    │
└──────────────┘                      └───────────────────┘               └────────┬─────────┘
                                                                                  │
                                           circuit breaker check                  │
                                           HTTP POST (Named Cred, 30s timeout)    │
                                                                                  ▼
                                                                            ┌─────────────┐  transform  ┌─────┐
                                                                            │ OrderSyncAPI │───────────▶│ ERP │
                                                                            │ (Middleware) │            │     │
                                                                            └──────┬──────┘            └─────┘
                                                                                   │
                              ┌───────────────────────────────────────────┬─────────────────────────┴─────────────────────────┐
                              │                                           │                         │
                       200/409 → Synced                            202 → poll                 5xx → retry
                              │                                           │                         │
                     ┌────────▼──────────┐   ┌──────────▼────────────┐   ┌───────▼──────────┐
                     │ Order_Sync_Log__c │   │  OrderSyncPollJob     │   │ OrderSyncRetry   │
                     │  (audit trail)    │   │  (Queueable+Sched,    │   │  Scheduler       │
                     │  + Order__c       │   │   exp. backoff)       │   │  (batch, 15min)  │
                     │  status update    │   └───────────────────────┘   │  retryable only  │
                     └───────────────────┘                           └──────────────────┘
                                                                              │
                                                                     exceeded max retries?
                                                                              │
                                                                     ┌────────▼─────────┐
                                                                     │ Platform Event   │
                                                                     │ Alert (CRITICAL) │
                                                                     └──────────────────┘
```

---

## 5. Partner Update — FinEng Team

> **To:** FinEng (OrderSyncAPI team)
> **From:** GTM Systems (Salesforce)
> **Subject:** Order Sync — Root Cause Findings & Remediation Plan
>
> **Hi team,**
>
> Thanks for flagging the intermittent 422s, duplicate 409s, and missing poll callbacks — those reports directly helped us pinpoint the root causes. Here's a summary of what we found and what we're shipping.
>
> ### What We Found
>
> 1. **Null discount → 422 rejections.** When an order has no discount, we were sending `"discount": null` instead of `0`. We've added a null-safe default so the field is always numeric. This should eliminate your `DISCOUNT_NULL` errors immediately.
>
> 2. **Duplicate posts & mismatched amounts → 409 / 422.** Two contributing factors:
>    - **No transition guard.** Our trigger fired on every update to an activated order, not just the activation event itself. We now use `Trigger.oldMap` to fire only on the status *change*.
>    - **Discount math.** We were splitting the discount equally across lines regardless of line value, and the header `amount` was the raw field rather than `Σ(line amounts)`. This produced payloads where header ≠ sum-of-lines and slightly different line amounts on retries (rounding drift). We've moved to proportional allocation with a remainder-absorbing last line, and we now derive the header from the computed line sum.
>
> 3. **No 202 follow-up.** You were right — we were logging the 202 but never polling or calling back. We've built a `Queueable` polling job that hits `GET /orders/status/{jobId}` with backoff until we get a terminal state.
>
> 4. **Silent failures.** Everything was going to `System.debug`, which is ephemeral. We've added an `Order_Sync_Log__c` object that persists every attempt with response code, payload hash, and error detail. We also write `Sync_Status__c` on the order itself, making it reportable and alertable.
>
> ### What We Need from You
>
> - **Idempotency key support.** We're now sending an `idempotencyKey` field (`externalId-lastModifiedTimestamp`). Could you confirm you can use this for dedup on your side? This will let you distinguish true duplicates from legitimate retries with updated data.
> - **Schema version acknowledgment.** We're adding `"schemaVersion": "2.0"` to all payloads. We'd like to agree on a contract where you reject payloads with unrecognized schema versions rather than silently misinterpreting them.
> - **202 poll endpoint confirmation.** We're hitting `GET /orders/status/{jobId}` — please confirm the contract (response shape for `completed`, `failed`, `processing`). Our polling now uses exponential backoff (1, 2, 4, 8… up to 60 min).
> - **Circuit breaker coordination.** We've implemented a client-side circuit breaker that stops callouts after 10 consecutive failures within 30 minutes. If you have a health-check endpoint (`GET /health`), we can check that first — please advise.
> - **Webhook / callback option.** Longer-term, if you support a callback URL header, we'd prefer push over poll. Happy to discuss.
>
> ### Timeline
>
> - **Immediate (this sprint):** Null-safe discount, transition guard, proportional allocation, header reconciliation, 422/5xx handling, durable logging, Queueable migration (replacing @future), partial-success DML, HTTP timeout, retryable flag filtering, and Last_Sync_Attempt__c fix.
> - **Next sprint:** 202 polling with exponential backoff, circuit breaker, retry scheduler hardening, schema versioning, Named Credential migration.
> - **Backlog:** CPQ `LineAmount__c` as source of truth (pending Rev Ops confirmation), callback-based flow if you support it, Change Data Capture evaluation for ultimate decoupling.
>
> Let's sync this week to walk through the payload changes and confirm the idempotency key contract. Happy to jump on a call or async in Slack — whatever works for your team.
>
> Thanks for the partnership.
>
> — GTM Systems (Salesforce)

---

*End of document.*
