/**
 * Trigger: Order_AfterUpdate
 * Fires ONLY when Status__c transitions to 'Activated' (not on every update).
 * Delegates to Queueable for async callout processing with chunked chaining.
 *
 * Fixes: D1 (callout in trigger context), D2 (no oldMap guard), D11 (SOQL in loop)
 * Scale: S1 (Queueable replaces @future for unlimited bulk support)
 */
trigger Order_AfterUpdate on Order__c (after update) {
    Set<Id> orderIdsToSync = new Set<Id>();

    for (Order__c newOrder : Trigger.new) {
        Order__c oldOrder = Trigger.oldMap.get(newOrder.Id);

        // Only fire when status CHANGES to Activated
        if (newOrder.Status__c == 'Activated' && oldOrder.Status__c != 'Activated') {
            orderIdsToSync.add(newOrder.Id);
        }
    }

    if (!orderIdsToSync.isEmpty()) {
        System.enqueueJob(new OrderSyncQueueable(orderIdsToSync));
    }
}
