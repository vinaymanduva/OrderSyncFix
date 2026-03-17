/**
 * OrderSyncPollJob
 *
 * Queueable + Schedulable job that polls the middleware for the status of an async
 * (202) order sync. Uses exponential backoff: first poll is immediate, subsequent
 * polls are scheduled at 2^attempt minutes (1, 2, 4, 8, ... up to 60 min cap).
 *
 * Flow: Queueable.execute() runs the poll → if still processing, scheduleNextPoll()
 * creates a one-time Schedulable at a future time → Schedulable.execute() re-enqueues
 * the Queueable. This achieves true backoff without consuming async Apex slots.
 *
 * Fix: D8 — missing 202 polling mechanism.
 * Scale: S10 — exponential backoff prevents async slot exhaustion.
 */
public with sharing class OrderSyncPollJob implements Queueable, Schedulable, Database.AllowsCallouts {

    private static final Integer MAX_POLL_ATTEMPTS = 10;
    private static final Integer MAX_BACKOFF_MINUTES = 60;
    private static final Integer HTTP_TIMEOUT_MS = 30000;
    private static final String STATUS_ENDPOINT = 'callout:OrderSyncAPI/orders/status/';

    private Id orderId;
    private String jobId;
    private Integer pollAttempt;

    public OrderSyncPollJob(Id orderId, String jobId, Integer pollAttempt) {
        this.orderId = orderId;
        this.jobId = jobId;
        this.pollAttempt = pollAttempt;
    }

    // Schedulable entry point — re-enqueues as Queueable for callout context
    public void execute(SchedulableContext sc) {
        System.enqueueJob(new OrderSyncPollJob(this.orderId, this.jobId, this.pollAttempt));
    }

    public void execute(QueueableContext ctx) {
        Order__c orderToUpdate = new Order__c(
            Id                   = this.orderId,
            Last_Sync_Attempt__c = Datetime.now()
        );

        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(STATUS_ENDPOINT + this.jobId);
            req.setMethod('GET');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(HTTP_TIMEOUT_MS);

            HttpResponse res = new Http().send(req);

            Map<String, Object> body = new Map<String, Object>();
            if (String.isNotBlank(res.getBody())) {
                body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            }

            String jobStatus = (String) body.get('status');

            if (res.getStatusCode() == 200 && jobStatus == 'completed') {
                orderToUpdate.Sync_Status__c = 'Synced';
                orderToUpdate.ERP_Order_Id__c = (String) body.get('erpOrderId');

            } else if (res.getStatusCode() == 200 && jobStatus == 'failed') {
                orderToUpdate.Sync_Status__c = 'Error';
                orderToUpdate.Sync_Error__c = 'Async job failed: ' + (String) body.get('message');

            } else if (this.pollAttempt < MAX_POLL_ATTEMPTS) {
                // Still processing — schedule next poll with exponential backoff
                orderToUpdate.Sync_Status__c = 'Pending';
                update orderToUpdate;

                // Log the poll attempt
                insert new Order_Sync_Log__c(
                    Order__c          = this.orderId,
                    Sync_Timestamp__c = Datetime.now(),
                    Response_Code__c  = res.getStatusCode(),
                    Response_Body__c  = res.getBody(),
                    Status__c         = 'Pending'
                );

                scheduleNextPoll();
                return; // Early return — already updated

            } else {
                // Exceeded max poll attempts
                orderToUpdate.Sync_Status__c = 'Error';
                orderToUpdate.Sync_Error__c = 'Async job did not complete after '
                    + MAX_POLL_ATTEMPTS + ' poll attempts. Job ID: ' + this.jobId;
            }

        } catch (Exception e) {
            orderToUpdate.Sync_Status__c = 'Error';
            orderToUpdate.Sync_Error__c = 'Poll exception: ' + e.getMessage();
        }

        update orderToUpdate;

        // Log final result
        insert new Order_Sync_Log__c(
            Order__c          = this.orderId,
            Sync_Timestamp__c = Datetime.now(),
            Status__c         = orderToUpdate.Sync_Status__c,
            Error_Message__c  = orderToUpdate.Sync_Error__c
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // Exponential backoff: schedule next poll at 2^attempt minutes
    // ─────────────────────────────────────────────────────────────────────
    private void scheduleNextPoll() {
        Integer delayMinutes = (Integer) Math.min(Math.pow(2, this.pollAttempt), MAX_BACKOFF_MINUTES);
        Datetime nextPoll = Datetime.now().addMinutes(delayMinutes);
        String cronExp = nextPoll.second() + ' ' + nextPoll.minute() + ' ' + nextPoll.hour()
            + ' ' + nextPoll.day() + ' ' + nextPoll.month() + ' ? ' + nextPoll.year();
        String jobName = 'OrderSyncPoll-' + this.orderId + '-' + (this.pollAttempt + 1);
        System.schedule(jobName, cronExp,
            new OrderSyncPollJob(this.orderId, this.jobId, this.pollAttempt + 1));
    }
}
