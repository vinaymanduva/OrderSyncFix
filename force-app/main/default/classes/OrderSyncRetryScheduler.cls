/**
 * OrderSyncRetryScheduler
 *
 * Schedulable + Batchable job that retries failed order syncs.
 * Runs on a configurable schedule (e.g., every 15 minutes).
 * Queries orders in 'Error' status with retryable failures, re-attempts sync,
 * and updates status accordingly.
 *
 * Schedule example:
 *   System.schedule('OrderSyncRetry-Every15Min',
 *       '0 0/15 * * * ?', new OrderSyncRetryScheduler());
 *
 * Also picks up 'Pending' orders (202 accepted) for status polling.
 *
 * Fix: D7/D8/D9 — durable retry with backoff, governor-safe batch processing.
 */
public with sharing class OrderSyncRetryScheduler implements Schedulable, Database.Batchable<sObject>, Database.AllowsCallouts, Database.Stateful {

    private static final Integer MAX_RETRIES = 5;
    private static final Integer BACKOFF_MINUTES = 15;
    private static final Integer BATCH_SIZE = 10; // Callouts per execute scope

    // ─────────────────────────────────────────────────────────────────────
    // Schedulable interface
    // ─────────────────────────────────────────────────────────────────────
    public void execute(SchedulableContext sc) {
        Database.executeBatch(new OrderSyncRetryScheduler(), BATCH_SIZE);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Batchable: start — find retryable orders
    // ─────────────────────────────────────────────────────────────────────
    public Database.QueryLocator start(Database.BatchableContext bc) {
        Datetime cutoff = Datetime.now().addMinutes(-BACKOFF_MINUTES);

        return Database.getQueryLocator([
            SELECT Id, Name, Status__c, Amount__c, Discount__c,
                   External_Id__c, LastModifiedDate, Sync_Status__c,
                   Retry_Count__c, Sync_Job_Id__c, Sync_Is_Retryable__c,
                   (SELECT Id, ProductCode__c, Quantity__c, UnitPrice__c, LineAmount__c
                    FROM OrderItems__r)
            FROM Order__c
            WHERE Status__c = 'Activated'
              AND (
                  (Sync_Status__c = 'Error' AND Sync_Is_Retryable__c = true
                   AND Retry_Count__c < :MAX_RETRIES
                   AND Last_Sync_Attempt__c < :cutoff)
                  OR
                  (Sync_Status__c = 'Pending' AND Sync_Job_Id__c != null
                   AND Last_Sync_Attempt__c < :cutoff)
              )
            ORDER BY Last_Sync_Attempt__c ASC
        ]);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Batchable: execute — retry sync or poll status
    // ─────────────────────────────────────────────────────────────────────
    public void execute(Database.BatchableContext bc, List<Order__c> scope) {
        List<Order__c> ordersToUpdate = new List<Order__c>();
        List<Order_Sync_Log__c> logsToInsert = new List<Order_Sync_Log__c>();

        for (Order__c o : scope) {
            if (o.Sync_Status__c == 'Pending') {
                // Poll middleware for async job status
                handlePendingOrder(o, ordersToUpdate, logsToInsert);
            } else {
                // Retry failed sync
                handleRetryOrder(o, ordersToUpdate, logsToInsert);
            }
        }

        if (!ordersToUpdate.isEmpty()) {
            Database.update(ordersToUpdate, false);
        }
        if (!logsToInsert.isEmpty()) {
            Database.insert(logsToInsert, false);
        }
    }

    private void handleRetryOrder(Order__c o, List<Order__c> ordersToUpdate,
                                   List<Order_Sync_Log__c> logsToInsert) {
        OrderSyncHandler.SyncResult result = OrderSyncHandler.syncSingleOrder(o);

        Decimal retryCount = (o.Retry_Count__c == null ? 0 : o.Retry_Count__c) + 1;

        Order__c toUpdate = new Order__c(
            Id                   = o.Id,
            Sync_Status__c       = result.status,
            Sync_Error__c        = result.errorMessage,
            ERP_Order_Id__c      = result.erpOrderId,
            Sync_Job_Id__c       = result.jobId,
            Sync_Is_Retryable__c = result.isRetryable,
            Retry_Count__c       = retryCount,
            Last_Sync_Attempt__c = Datetime.now()
        );

        // If still failing after max retries, mark as permanently failed
        if (result.status == 'Error' && retryCount >= MAX_RETRIES) {
            toUpdate.Sync_Status__c = 'Failed';
            toUpdate.Sync_Is_Retryable__c = false;
            toUpdate.Sync_Error__c = 'Max retries (' + MAX_RETRIES + ') exceeded. Last error: '
                + result.errorMessage;
        }

        ordersToUpdate.add(toUpdate);
        logsToInsert.add(new Order_Sync_Log__c(
            Order__c                = o.Id,
            Sync_Timestamp__c       = Datetime.now(),
            Response_Code__c        = result.responseCode,
            Response_Body__c        = result.responseBody,
            Status__c               = toUpdate.Sync_Status__c,
            Error_Message__c        = toUpdate.Sync_Error__c,
            Is_Retryable__c         = result.isRetryable,
            Retry_Attempt_Number__c = retryCount
        ));
    }

    private void handlePendingOrder(Order__c o, List<Order__c> ordersToUpdate,
                                     List<Order_Sync_Log__c> logsToInsert) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:OrderSyncAPI/orders/status/' + o.Sync_Job_Id__c);
            req.setMethod('GET');
            req.setHeader('Content-Type', 'application/json');

            HttpResponse res = new Http().send(req);
            Map<String, Object> body = new Map<String, Object>();
            if (String.isNotBlank(res.getBody())) {
                body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            }

            Order__c toUpdate = new Order__c(
                Id                   = o.Id,
                Last_Sync_Attempt__c = Datetime.now()
            );

            String jobStatus = (String) body.get('status');

            if (res.getStatusCode() == 200 && jobStatus == 'completed') {
                toUpdate.Sync_Status__c = 'Synced';
                toUpdate.ERP_Order_Id__c = (String) body.get('erpOrderId');
            } else if (res.getStatusCode() == 200 && jobStatus == 'failed') {
                toUpdate.Sync_Status__c = 'Error';
                toUpdate.Sync_Error__c = 'Async job failed: ' + (String) body.get('message');
            } else {
                // Still processing — leave as Pending, will be checked next cycle
                toUpdate.Sync_Status__c = 'Pending';
            }

            ordersToUpdate.add(toUpdate);
            logsToInsert.add(new Order_Sync_Log__c(
                Order__c             = o.Id,
                Sync_Timestamp__c    = Datetime.now(),
                Response_Code__c     = res.getStatusCode(),
                Response_Body__c     = res.getBody(),
                Status__c            = toUpdate.Sync_Status__c
            ));

        } catch (Exception e) {
            // Polling failure is non-fatal; will retry next cycle
            ordersToUpdate.add(new Order__c(
                Id                   = o.Id,
                Last_Sync_Attempt__c = Datetime.now(),
                Sync_Error__c        = 'Poll error: ' + e.getMessage()
            ));
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Batchable: finish
    // ─────────────────────────────────────────────────────────────────────
    public void finish(Database.BatchableContext bc) {
        // Check if any orders moved to permanent 'Failed' status — alert ops
        Integer failedCount = [
            SELECT COUNT()
            FROM Order__c
            WHERE Sync_Status__c = 'Failed'
              AND Last_Sync_Attempt__c = TODAY
        ];

        if (failedCount > 0) {
            // Fire a Platform Event for monitoring/Slack alerting
            Order_Sync_Alert__e alert = new Order_Sync_Alert__e(
                Message__c = failedCount + ' order(s) permanently failed sync after max retries.',
                Severity__c = 'CRITICAL',
                Timestamp__c = Datetime.now()
            );
            Database.SaveResult sr = EventBus.publish(alert);
            if (!sr.isSuccess()) {
                System.debug(LoggingLevel.ERROR,
                    'Failed to publish Order_Sync_Alert__e: '
                    + sr.getErrors()[0].getMessage());
            }
        }
    }
}
