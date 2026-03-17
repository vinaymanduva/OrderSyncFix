# Order Sync Fix — Deployment Guide

## Overview

This package fixes 12 critical defects in the Order-to-ERP sync pipeline.
See `Order_Sync_Analysis.md` for the full defect analysis and root cause mapping.

## What's Included

```
OrderSyncFix/
└── force-app/main/default/
    ├── triggers/
    │   └── Order_AfterUpdate.trigger          ← Fixed trigger (D1, D2, D11)
    ├── classes/
    │   ├── OrderSyncHandler.cls               ← Core sync logic (D3-D7, D9-D12)
    │   ├── OrderSyncRetryScheduler.cls        ← Batch retry for failed syncs (D7, D8, D9)
    │   ├── OrderSyncPollJob.cls               ← Queueable 202 polling (D8)
    │   └── OrderSyncHandlerTest.cls           ← 12 unit tests
    └── objects/
        ├── Order__c/fields/
        │   ├── Sync_Status__c                 ← Picklist: Pending/Synced/Error/Retrying/Failed
        │   ├── Sync_Error__c                  ← Long text: last error message
        │   ├── ERP_Order_Id__c                ← Text: ERP order identifier
        │   ├── Sync_Job_Id__c                 ← Text: middleware async job ID
        │   ├── Retry_Count__c                 ← Number: retry attempts
        │   └── Last_Sync_Attempt__c           ← DateTime: last sync timestamp
        └── Order_Sync_Log__c/                 ← New audit log object
            └── fields/
                ├── Order__c                   ← Lookup to Order__c
                ├── Sync_Timestamp__c          ← DateTime
                ├── Request_Payload_Hash__c    ← SHA-256 hash
                ├── Response_Code__c           ← HTTP status code
                ├── Response_Body__c           ← Raw response
                ├── Status__c                  ← Outcome
                ├── Error_Message__c           ← Error detail
                ├── Is_Retryable__c            ← Checkbox
                └── Retry_Attempt_Number__c    ← Number
```

## Defect → Fix Mapping

| Defect | Description                              | Fixed In                     |
|--------|------------------------------------------|------------------------------|
| D1     | Synchronous callout in trigger           | Trigger + Handler (@future)  |
| D2     | No Trigger.oldMap status-change guard    | Trigger                      |
| D3     | Null discount → middleware 422           | Handler (buildPayload)       |
| D4     | Even discount split (not proportional)   | Handler (buildPayload)       |
| D5     | Header ≠ line sum                        | Handler (buildPayload)       |
| D6     | LineAmount__c queried but unused         | Handler (commented hook)     |
| D7     | Unhandled 422/500 responses              | Handler (syncSingleOrder)    |
| D8     | No 202 polling                           | PollJob + RetryScheduler     |
| D9     | Debug-only error handling                | Sync_Status__c + Log object  |
| D10    | No idempotency key                       | Handler (buildPayload)       |
| D11    | SOQL inside loop                         | Handler (bulk query)         |
| D12    | Hardcoded URL → same org                 | Named Credential endpoint    |

## Prerequisites

### 1. Named Credential

Create a Named Credential named `OrderSyncAPI` pointing to the FinEng middleware:

- **URL**: `https://<middleware-host>` (get from FinEng team)
- **Identity Type**: Named Principal
- **Authentication Protocol**: OAuth 2.0 or API Key (per FinEng spec)
- **Generate Authorization Header**: Checked

### 2. Platform Event (optional alerting)

If you want automated Slack/email alerts for permanently failed orders, create:

- **Platform Event**: `Order_Sync_Alert__e`
  - `Message__c` (Text, 255)
  - `Severity__c` (Text, 20)
  - `Timestamp__c` (DateTime)

Then subscribe via Flow or a Platform Event trigger to route to Slack.

## Deployment Steps

### Sandbox

```bash
# Authenticate to sandbox
sf org login web --set-default --alias sandbox --instance-url https://test.salesforce.com

# Deploy metadata
sf project deploy start --source-dir force-app --target-org sandbox

# Run tests
sf apex run test --class-names OrderSyncHandlerTest --target-org sandbox --wait 10
```

### Schedule the Retry Job (post-deploy)

Execute in Developer Console or via Anonymous Apex:

```apex
// Run retry scheduler every 15 minutes
System.schedule(
    'OrderSyncRetry-Every15Min',
    '0 0/15 * * * ?',
    new OrderSyncRetryScheduler()
);
```

### Validation Checklist

- [ ] Deploy to sandbox — all metadata pushes without errors
- [ ] Run `OrderSyncHandlerTest` — 12/12 tests pass
- [ ] Activate a test order → verify Sync_Status__c = 'Synced' and ERP_Order_Id__c populated
- [ ] Activate order with null discount → verify no 422 error (discount sends as 0)
- [ ] Check Order_Sync_Log__c records created for each sync attempt
- [ ] Simulate middleware 500 → verify order marked Error, retried by scheduler, log created
- [ ] Update a non-status field on activated order → verify NO duplicate sync fires
- [ ] Bulk-activate 200 orders via Data Loader → verify no governor limit errors
- [ ] Schedule retry job → verify it picks up Error orders after backoff period

### Production

After sandbox validation + FinEng joint testing:

```bash
sf project deploy start --source-dir force-app --target-org production --dry-run
sf project deploy start --source-dir force-app --target-org production
```

## Open Items (Coordinate with FinEng)

1. **Idempotency key**: Confirm FinEng will honor `idempotencyKey` field in payload
2. **202 polling endpoint**: Confirm `GET /orders/status/{jobId}` contract
3. **CPQ LineAmount__c**: Confirm with Rev Ops whether to use CPQ value vs. recalculated
4. **Canary rollout**: Enable for one business unit first, monitor 48h, then full rollout
