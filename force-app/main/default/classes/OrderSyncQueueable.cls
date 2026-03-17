/**
 * OrderSyncQueueable
 *
 * Queueable job that processes order sync callouts in async context.
 * Replaces @future(callout=true) to overcome the 50-invocation-per-transaction
 * limit and support chunked chaining for bulk operations.
 *
 * Each execution processes up to CHUNK_SIZE orders, then chains a new
 * Queueable for any remaining orders — supporting thousands of records
 * without hitting governor limits.
 *
 * Scale enhancement S1.
 */
public with sharing class OrderSyncQueueable implements Queueable, Database.AllowsCallouts {

    private static final Integer CHUNK_SIZE = 50;

    private List<Id> orderIdList;

    public OrderSyncQueueable(Set<Id> orderIds) {
        this.orderIdList = new List<Id>(orderIds);
    }

    @TestVisible
    private OrderSyncQueueable(List<Id> orderIdList) {
        this.orderIdList = orderIdList;
    }

    public void execute(QueueableContext ctx) {
        List<Id> currentChunk = new List<Id>();
        List<Id> remaining = new List<Id>();

        for (Integer i = 0; i < orderIdList.size(); i++) {
            if (i < CHUNK_SIZE) {
                currentChunk.add(orderIdList[i]);
            } else {
                remaining.add(orderIdList[i]);
            }
        }

        OrderSyncHandler.processSyncBatch(new Set<Id>(currentChunk));

        if (!remaining.isEmpty()) {
            System.enqueueJob(new OrderSyncQueueable(remaining));
        }
    }
}
