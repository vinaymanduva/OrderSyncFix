/**
 * OrderSyncHandlerTest
 *
 * Unit tests for the Order Sync system covering:
 *   - Trigger status-change guard
 *   - Payload construction (null discount, proportional allocation, header reconciliation)
 *   - HTTP response handling (200, 202, 409, 422, 500)
 *   - Idempotency key generation
 *   - Retry scheduler query logic
 *   - Schema versioning, excessive discount validation
 *   - Bulk activation, Last_Sync_Attempt__c, retryable flag
 */
@isTest
private class OrderSyncHandlerTest {

    // ─────────────────────────────────────────────────────────────────────
    // Test data factory
    // ─────────────────────────────────────────────────────────────────────
    @TestSetup
    static void setupData() {
        Order__c order = new Order__c(
            Name          = 'ORD-TEST-001',
            Status__c     = 'Draft',
            Amount__c     = 10000.00,
            Discount__c   = 1500.00,
            External_Id__c = 'EXT-TEST-001'
        );
        insert order;

        List<OrderItem__c> items = new List<OrderItem__c>{
            new OrderItem__c(
                Order__c       = order.Id,
                ProductCode__c = 'CHAT-TEAM',
                Quantity__c    = 50,
                UnitPrice__c   = 150.00,
                LineAmount__c  = 7500.00
            ),
            new OrderItem__c(
                Order__c       = order.Id,
                ProductCode__c = 'API-COMMIT',
                Quantity__c    = 1,
                UnitPrice__c   = 4500.00,
                LineAmount__c  = 4500.00
            ),
            new OrderItem__c(
                Order__c       = order.Id,
                ProductCode__c = 'SUPPORT-PREM',
                Quantity__c    = 1,
                UnitPrice__c   = 2000.00,
                LineAmount__c  = 2000.00
            )
        };
        insert items;
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. Trigger: only fires on status CHANGE to Activated
    // ─────────────────────────────────────────────────────────────────────
    @isTest
    static void testTrigger_OnlyFiresOnStatusChange() {
        Order__c o = [SELECT Id, Status__c FROM Order__c LIMIT 1];

        // First activation — should enqueue async job
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MockMiddleware(200,
            '{"status":"ok","erpOrderId":"ERP-99999"}'));

        o.Status__c = 'Activated';
        update o;
        Test.stopTest();

        Order__c updated = [SELECT Sync_Status__c, ERP_Order_Id__c FROM Order__c WHERE Id = :o.Id];
        System.assertEquals('Synced', updated.Sync_Status__c, 'Should be synced after activation');
        System.assertEquals('ERP-99999', updated.ERP_Order_Id__c);
    }

    @isTest
    static void testTrigger_DoesNotReFire_WhenAlreadyActivated() {
        Order__c o = [SELECT Id FROM Order__c LIMIT 1];
        o.Status__c = 'Activated';
        o.Sync_Status__c = 'Synced';
        update o; // activate first

        // Now update another field on an already-activated order
        Test.startTest();
        // If the trigger re-fires, the mock will receive a callout.
        // We intentionally do NOT set a mock — if a callout happens, it will fail.
        o.Name = 'ORD-TEST-001-UPDATED';
        update o;
        Test.stopTest();

        // If we reach here without a CalloutException, the trigger correctly skipped
        System.assert(true, 'Trigger should not re-fire sync for already-activated order');
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. Payload: null discount defaults to 0
    // ─────────────────────────────────────────────────────────────────────
    @isTest
    static void testPayload_NullDiscount_DefaultsToZero() {
        Order__c o = [SELECT Id, Name, Status__c, Amount__c, Discount__c,
                             External_Id__c, LastModifiedDate,
                             (SELECT Id, ProductCode__c, Quantity__c, UnitPrice__c, LineAmount__c
                              FROM OrderItems__r)
                      FROM Order__c LIMIT 1];
        o.Discount__c = null;

        Map<String, Object> payload = OrderSyncHandler.buildPayload(o);

        System.assertEquals(0, (Decimal) payload.get('discount'),
            'Null discount should serialize as 0');
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. Payload: proportional discount allocation
    // ─────────────────────────────────────────────────────────────────────
    @isTest
    static void testPayload_ProportionalDiscountAllocation() {
        Order__c o = [SELECT Id, Name, Status__c, Amount__c, Discount__c,
                             External_Id__c, LastModifiedDate,
                             (SELECT Id, ProductCode__c, Quantity__c, UnitPrice__c, LineAmount__c
                              FROM OrderItems__r)
                      FROM Order__c LIMIT 1];

        // Discount = 1500, Gross = 7500 + 4500 + 2000 = 14000
        Map<String, Object> payload = OrderSyncHandler.buildPayload(o);
        List<Object> lines = (List<Object>) payload.get('lines');

        Decimal lineSum = 0;
        for (Object lineObj : lines) {
            Map<String, Object> line = (Map<String, Object>) lineObj;
            Decimal amt = (Decimal) line.get('amount');
            System.assert(amt > 0, 'All line amounts should be positive: ' + line.get('sku'));
            lineSum += amt;
        }

        // Header must equal sum of lines
        Decimal headerAmount = (Decimal) payload.get('amount');
        System.assertEquals(headerAmount, lineSum,
            'Header amount must equal sum of line amounts');

        // Total net should be grossTotal - discount = 14000 - 1500 = 12500
        System.assertEquals(12500.00, headerAmount,
            'Net total should be gross minus discount');
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. Payload: idempotency key format
    // ─────────────────────────────────────────────────────────────────────
    @isTest
    static void testPayload_IdempotencyKeyPresent() {
        Order__c o = [SELECT Id, Name, Status__c, Amount__c, Discount__c,
                             External_Id__c, LastModifiedDate,
                             (SELECT Id, ProductCode__c, Quantity__c, UnitPrice__c, LineAmount__c
                              FROM OrderItems__r)
                      FROM Order__c LIMIT 1];

        Map<String, Object> payload = OrderSyncHandler.buildPayload(o);
        String key = (String) payload.get('idempotencyKey');

        System.assertNotEquals(null, key, 'Idempotency key must be present');
        System.assert(key.startsWith('EXT-TEST-001-'),
            'Key should start with external ID: ' + key);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. HTTP 200 — successful sync
    // ─────────────────────────────────────────────────────────────────────
    @isTest
    static void testSync_Http200_Success() {
        Order__c o = getFullOrder();

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MockMiddleware(200,
            '{"status":"ok","erpOrderId":"ERP-12345"}'));

        OrderSyncHandler.SyncResult result = OrderSyncHandler.syncSingleOrder(o);
        Test.stopTest();

        System.assertEquals('Synced', result.status);
        System.assertEquals('ERP-12345', result.erpOrderId);
        System.assertEquals(200, result.responseCode);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6. HTTP 202 — accepted for async processing
    // ─────────────────────────────────────────────────────────────────────
    @isTest
    static void testSync_Http202_Accepted() {
        Order__c o = getFullOrder();

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MockMiddleware(202,
            '{"status":"accepted","jobId":"JOB-9999"}'));

        OrderSyncHandler.SyncResult result = OrderSyncHandler.syncSingleOrder(o);
        Test.stopTest();

        System.assertEquals('Pending', result.status);
        System.assertEquals('JOB-9999', result.jobId);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 7. HTTP 409 — duplicate, treated as success
    // ─────────────────────────────────────────────────────────────────────
    @isTest
    static void testSync_Http409_Duplicate() {
        Order__c o = getFullOrder();

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MockMiddleware(409,
            '{"status":"duplicate","existingErpOrderId":"ERP-12345"}'));

        OrderSyncHandler.SyncResult result = OrderSyncHandler.syncSingleOrder(o);
        Test.stopTest();

        System.assertEquals('Synced', result.status);
        System.assertEquals('ERP-12345', result.erpOrderId);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 8. HTTP 422 — validation error, not retryable
    // ─────────────────────────────────────────────────────────────────────
    @isTest
    static void testSync_Http422_ValidationError() {
        Order__c o = getFullOrder();

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MockMiddleware(422,
            '{"error":"DISCOUNT_NULL","message":"discount must be provided"}'));

        OrderSyncHandler.SyncResult result = OrderSyncHandler.syncSingleOrder(o);
        Test.stopTest();

        System.assertEquals('Error', result.status);
        System.assert(result.errorMessage.contains('422'), 'Error should include status code');
        System.assertEquals(false, result.isRetryable, '422 should NOT be retryable');
    }

    // ─────────────────────────────────────────────────────────────────────
    // 9. HTTP 500 — server error, retryable
    // ─────────────────────────────────────────────────────────────────────
    @isTest
    static void testSync_Http500_ServerError() {
        Order__c o = getFullOrder();

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MockMiddleware(500,
            '{"error":"INTERNAL","message":"timeout downstream"}'));

        OrderSyncHandler.SyncResult result = OrderSyncHandler.syncSingleOrder(o);
        Test.stopTest();

        System.assertEquals('Error', result.status);
        System.assertEquals(true, result.isRetryable, '500 should be retryable');
    }

    // ─────────────────────────────────────────────────────────────────────
    // 10. Sync logs are created
    // ─────────────────────────────────────────────────────────────────────
    @isTest
    static void testSyncAsync_CreatesSyncLog() {
        Order__c o = [SELECT Id FROM Order__c LIMIT 1];

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MockMiddleware(200,
            '{"status":"ok","erpOrderId":"ERP-77777"}'));

        o.Status__c = 'Activated';
        update o;
        Test.stopTest();

        List<Order_Sync_Log__c> logs = [
            SELECT Id, Status__c, Response_Code__c
            FROM Order_Sync_Log__c
            WHERE Order__c = :o.Id
        ];
        System.assert(!logs.isEmpty(), 'At least one sync log should be created');
        System.assertEquals('Synced', logs[0].Status__c);
        System.assertEquals(200, logs[0].Response_Code__c);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 11. Retry scheduler picks up failed orders
    // ─────────────────────────────────────────────────────────────────────
    @isTest
    static void testRetryScheduler_ProcessesFailedOrders() {
        Order__c o = [SELECT Id FROM Order__c LIMIT 1];
        o.Status__c            = 'Activated';
        o.Sync_Status__c       = 'Error';
        o.Sync_Is_Retryable__c = true;
        o.Retry_Count__c       = 1;
        o.Last_Sync_Attempt__c = Datetime.now().addHours(-1); // well past backoff
        update o;

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MockMiddleware(200,
            '{"status":"ok","erpOrderId":"ERP-RETRY"}'));

        Database.executeBatch(new OrderSyncRetryScheduler(), 10);
        Test.stopTest();

        Order__c updated = [SELECT Sync_Status__c, ERP_Order_Id__c, Retry_Count__c
                            FROM Order__c WHERE Id = :o.Id];
        System.assertEquals('Synced', updated.Sync_Status__c);
        System.assertEquals('ERP-RETRY', updated.ERP_Order_Id__c);
        System.assertEquals(2, updated.Retry_Count__c, 'Retry count should increment');
    }

    // ─────────────────────────────────────────────────────────────────────
    // 12. Proportional discount: no negative line amounts
    // ─────────────────────────────────────────────────────────────────────
    @isTest
    static void testPayload_LargeDiscount_NoNegativeLines() {
        Order__c o = [SELECT Id, Name, Status__c, Amount__c, Discount__c,
                             External_Id__c, LastModifiedDate,
                             (SELECT Id, ProductCode__c, Quantity__c, UnitPrice__c, LineAmount__c
                              FROM OrderItems__r)
                      FROM Order__c LIMIT 1];

        // Set discount to a large but valid value
        o.Discount__c = 5000.00;

        Map<String, Object> payload = OrderSyncHandler.buildPayload(o);
        List<Object> lines = (List<Object>) payload.get('lines');

        for (Object lineObj : lines) {
            Map<String, Object> line = (Map<String, Object>) lineObj;
            Decimal amt = (Decimal) line.get('amount');
            System.assert(amt >= 0,
                'Line amount must not be negative for SKU: ' + line.get('sku') + ' (got ' + amt + ')');
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // 13. Schema version in payload
    // ─────────────────────────────────────────────────────────────────────
    @isTest
    static void testPayload_SchemaVersionPresent() {
        Order__c o = getFullOrder();
        Map<String, Object> payload = OrderSyncHandler.buildPayload(o);
        System.assertEquals('2.0', (String) payload.get('schemaVersion'),
            'Payload must include schema version');
    }

    // ─────────────────────────────────────────────────────────────────────
    // 14. Excessive discount throws exception
    // ─────────────────────────────────────────────────────────────────────
    @isTest
    static void testPayload_ExcessiveDiscount_ThrowsException() {
        Order__c o = getFullOrder();
        o.Discount__c = 20000.00; // Greater than gross total (14000)

        Boolean threwException = false;
        try {
            OrderSyncHandler.buildPayload(o);
        } catch (OrderSyncHandler.OrderSyncException e) {
            threwException = true;
            System.assert(e.getMessage().contains('exceeds gross total'),
                'Exception should mention exceeds gross total: ' + e.getMessage());
        }
        System.assert(threwException, 'Should throw OrderSyncException for excessive discount');
    }

    // ─────────────────────────────────────────────────────────────────────
    // 15. Last_Sync_Attempt__c is set after sync
    // ─────────────────────────────────────────────────────────────────────
    @isTest
    static void testSync_SetsLastSyncAttempt() {
        Order__c o = [SELECT Id FROM Order__c LIMIT 1];

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MockMiddleware(200,
            '{"status":"ok","erpOrderId":"ERP-TS-001"}'));

        o.Status__c = 'Activated';
        update o;
        Test.stopTest();

        Order__c updated = [SELECT Last_Sync_Attempt__c FROM Order__c WHERE Id = :o.Id];
        System.assertNotEquals(null, updated.Last_Sync_Attempt__c,
            'Last_Sync_Attempt__c must be set after sync');
    }

    // ─────────────────────────────────────────────────────────────────────
    // 16. Bulk activation: multiple orders in one transaction
    // ─────────────────────────────────────────────────────────────────────
    @isTest
    static void testBulkActivation_MultipleOrders() {
        // Create additional orders beyond the one from @TestSetup
        List<Order__c> newOrders = new List<Order__c>();
        for (Integer i = 0; i < 5; i++) {
            newOrders.add(new Order__c(
                Name          = 'ORD-BULK-' + i,
                Status__c     = 'Draft',
                Amount__c     = 5000.00,
                Discount__c   = 500.00,
                External_Id__c = 'EXT-BULK-' + i
            ));
        }
        insert newOrders;

        // Add line items for each order
        List<OrderItem__c> items = new List<OrderItem__c>();
        for (Order__c ord : newOrders) {
            items.add(new OrderItem__c(
                Order__c       = ord.Id,
                ProductCode__c = 'BULK-SKU',
                Quantity__c    = 10,
                UnitPrice__c   = 500.00,
                LineAmount__c  = 5000.00
            ));
        }
        insert items;

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MockMiddleware(200,
            '{"status":"ok","erpOrderId":"ERP-BULK"}'));

        // Activate all at once
        for (Order__c ord : newOrders) {
            ord.Status__c = 'Activated';
        }
        update newOrders;
        Test.stopTest();

        List<Order__c> synced = [SELECT Sync_Status__c FROM Order__c
                                  WHERE Id IN :newOrders AND Sync_Status__c = 'Synced'];
        System.assertEquals(5, synced.size(), 'All 5 bulk orders should be synced');
    }

    // ─────────────────────────────────────────────────────────────────────
    // 17. Non-retryable error (422) sets Sync_Is_Retryable__c = false
    // ─────────────────────────────────────────────────────────────────────
    @isTest
    static void testSync_422_IsNotRetryable() {
        Order__c o = [SELECT Id FROM Order__c LIMIT 1];

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MockMiddleware(422,
            '{"error":"VALIDATION","message":"bad data"}'));

        o.Status__c = 'Activated';
        update o;
        Test.stopTest();

        Order__c updated = [SELECT Sync_Status__c, Sync_Is_Retryable__c FROM Order__c WHERE Id = :o.Id];
        System.assertEquals('Error', updated.Sync_Status__c);
        System.assertEquals(false, updated.Sync_Is_Retryable__c,
            '422 errors should not be retryable');
    }

    // ─────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────
    private static Order__c getFullOrder() {
        return [SELECT Id, Name, Status__c, Amount__c, Discount__c,
                       External_Id__c, LastModifiedDate,
                       (SELECT Id, ProductCode__c, Quantity__c, UnitPrice__c, LineAmount__c
                        FROM OrderItems__r)
                FROM Order__c LIMIT 1];
    }

    // ─────────────────────────────────────────────────────────────────────
    // Mock HTTP callout
    // ─────────────────────────────────────────────────────────────────────
    private class MockMiddleware implements HttpCalloutMock {
        private Integer statusCode;
        private String body;

        MockMiddleware(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(this.statusCode);
            res.setBody(this.body);
            res.setHeader('Content-Type', 'application/json');
            return res;
        }
    }
}
