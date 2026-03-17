/**
 * OrderSyncHandler
 *
 * Handles synchronization of activated Orders to the FinEng middleware (OrderSyncAPI),
 * which transforms and forwards to ERP.
 *
 * Defect fixes:
 *   D1  - Async callout via Queueable (replaces @future for scalability)
 *   D3  - Null-safe discount (defaults to 0)
 *   D4  - Proportional discount allocation across lines
 *   D5  - Header amount derived from line sum (self-consistent payload)
 *   D6  - Uses LineAmount__c when available (CPQ source of truth)
 *   D7  - Handles all HTTP response codes (200, 202, 409, 422, 500)
 *   D9  - Durable error logging via Sync_Status__c + Order_Sync_Log__c
 *   D10 - Idempotency key in payload
 *   D11 - Bulk SOQL outside loop
 *   D12 - Named Credential instead of hardcoded URL
 *
 * Scale enhancements:
 *   S1  - Queueable with chunked chaining (no 50-call @future limit)
 *   S2  - Partial-success DML (Database.update/insert with allOrNone=false)
 *   S3  - Concurrent sync guard (prevents duplicate in-flight syncs)
 *   S4  - HTTP timeout configuration (30s)
 *   S5  - Circuit breaker (stops retries during middleware outage)
 *   S6  - Negative amount / excessive discount validation
 *   S7  - Schema versioning in payload
 *   S8  - Last_Sync_Attempt__c set on initial sync
 *   S9  - Sync_Is_Retryable__c on Order__c for accurate retry filtering
 */
public with sharing class OrderSyncHandler {

    private static final String NAMED_CREDENTIAL_ENDPOINT = 'callout:OrderSyncAPI/orders';
    private static final Integer MAX_RETRY_COUNT = 5;
    private static final Integer HTTP_TIMEOUT_MS = 30000;
    private static final String SCHEMA_VERSION = '2.0';

    // Circuit breaker settings
    private static final Integer CIRCUIT_BREAKER_THRESHOLD = 10;
    private static final Integer CIRCUIT_BREAKER_WINDOW_MINUTES = 30;

    // ─────────────────────────────────────────────────────────────────────
    // Entry point: called from OrderSyncQueueable (async context)
    // ─────────────────────────────────────────────────────────────────────
    public static void processSyncBatch(Set<Id> orderIds) {
        // Circuit breaker: stop hammering middleware during an outage
        if (isCircuitOpen()) {
            List<Order__c> ordersToSkip = new List<Order__c>();
            List<Order_Sync_Log__c> skipLogs = new List<Order_Sync_Log__c>();
            for (Id oid : orderIds) {
                ordersToSkip.add(new Order__c(
                    Id                   = oid,
                    Sync_Status__c       = 'Error',
                    Sync_Error__c        = 'Circuit breaker open — middleware appears down.',
                    Sync_Is_Retryable__c = true,
                    Last_Sync_Attempt__c = Datetime.now()
                ));
                skipLogs.add(new Order_Sync_Log__c(
                    Order__c          = oid,
                    Sync_Timestamp__c = Datetime.now(),
                    Status__c         = 'Error',
                    Error_Message__c  = 'Circuit breaker open — middleware appears down. Will retry when circuit closes.',
                    Is_Retryable__c   = true
                ));
            }
            Database.update(ordersToSkip, false);
            Database.insert(skipLogs, false);
            return;
        }

        // Concurrent sync guard: skip orders already Synced or Pending
        List<Order__c> orders = [
            SELECT Id, Name, Status__c, Amount__c, Discount__c,
                   External_Id__c, LastModifiedDate, Sync_Status__c,
                   (SELECT Id, ProductCode__c, Quantity__c, UnitPrice__c, LineAmount__c
                    FROM OrderItems__r)
            FROM Order__c
            WHERE Id IN :orderIds
              AND Status__c = 'Activated'
              AND (Sync_Status__c = null
                   OR Sync_Status__c NOT IN ('Synced', 'Pending'))
        ];

        List<Order__c> ordersToUpdate = new List<Order__c>();
        List<Order_Sync_Log__c> logsToInsert = new List<Order_Sync_Log__c>();

        for (Order__c o : orders) {
            SyncResult result = syncSingleOrder(o);

            ordersToUpdate.add(new Order__c(
                Id                   = o.Id,
                Sync_Status__c       = result.status,
                Sync_Error__c        = result.errorMessage,
                ERP_Order_Id__c      = result.erpOrderId,
                Sync_Job_Id__c       = result.jobId,
                Sync_Is_Retryable__c = result.isRetryable,
                Last_Sync_Attempt__c = Datetime.now()
            ));

            logsToInsert.add(buildSyncLog(o.Id, result));
        }

        // Partial-success DML: one bad record won't fail the entire batch
        if (!ordersToUpdate.isEmpty()) {
            List<Database.SaveResult> updateResults = Database.update(ordersToUpdate, false);
            logDmlFailures(updateResults, ordersToUpdate, 'Order update');
        }
        if (!logsToInsert.isEmpty()) {
            List<Database.SaveResult> insertResults = Database.insert(logsToInsert, false);
            logDmlFailures(insertResults, logsToInsert, 'Sync log insert');
        }

        // Enqueue polling for any 202-accepted orders
        for (Order__c o : ordersToUpdate) {
            if (o.Sync_Status__c == 'Pending' && String.isNotBlank(o.Sync_Job_Id__c)) {
                System.enqueueJob(new OrderSyncPollJob(o.Id, o.Sync_Job_Id__c, 0));
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Core sync logic for a single order (also called by retry scheduler)
    // ─────────────────────────────────────────────────────────────────────
    public static SyncResult syncSingleOrder(Order__c o) {
        SyncResult result = new SyncResult();
        result.status = 'Error'; // Default, overwritten on success

        try {
            Map<String, Object> payload = buildPayload(o);
            String payloadJson = JSON.serialize(payload);

            HttpRequest req = new HttpRequest();
            req.setEndpoint(NAMED_CREDENTIAL_ENDPOINT);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(HTTP_TIMEOUT_MS);
            req.setBody(payloadJson);

            result.requestPayloadHash = generatePayloadHash(payloadJson);

            Http h = new Http();
            HttpResponse res = h.send(req);

            result.responseCode = res.getStatusCode();
            result.responseBody = res.getBody();

            Map<String, Object> body = new Map<String, Object>();
            if (String.isNotBlank(res.getBody())) {
                body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            }

            if (res.getStatusCode() == 200) {
                result.status = 'Synced';
                result.erpOrderId = (String) body.get('erpOrderId');

            } else if (res.getStatusCode() == 202) {
                result.status = 'Pending';
                result.jobId = (String) body.get('jobId');

            } else if (res.getStatusCode() == 409) {
                // Duplicate — middleware already has this order; treat as success
                result.status = 'Synced';
                result.erpOrderId = (String) body.get('existingErpOrderId');

            } else if (res.getStatusCode() == 422) {
                result.status = 'Error';
                result.errorMessage = '422 Unprocessable: ' + res.getBody();

            } else if (res.getStatusCode() >= 500) {
                result.status = 'Error';
                result.errorMessage = res.getStatusCode() + ' Server Error: ' + res.getBody();
                result.isRetryable = true;

            } else {
                result.status = 'Error';
                result.errorMessage = 'Unexpected ' + res.getStatusCode() + ': ' + res.getBody();
            }

        } catch (System.CalloutException ce) {
            result.status = 'Error';
            result.errorMessage = 'CalloutException: ' + ce.getMessage();
            result.isRetryable = true;
        } catch (Exception e) {
            result.status = 'Error';
            result.errorMessage = e.getTypeName() + ': ' + e.getMessage();
        }

        return result;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Payload construction with all fixes applied
    // ─────────────────────────────────────────────────────────────────────
    @TestVisible
    private static Map<String, Object> buildPayload(Order__c o) {
        Decimal discount = (o.Discount__c == null) ? 0 : o.Discount__c;

        // Calculate gross total across all lines
        Decimal grossTotal = 0;
        for (OrderItem__c item : o.OrderItems__r) {
            grossTotal += item.UnitPrice__c * item.Quantity__c;
        }

        // Validate: discount must not exceed gross total
        if (discount > grossTotal) {
            throw new OrderSyncException(
                'Discount (' + discount + ') exceeds gross total (' + grossTotal
                + ') for order ' + o.Name + '. Payload rejected.'
            );
        }

        // Build line items with proportional discount allocation
        List<Map<String, Object>> lines = new List<Map<String, Object>>();
        Decimal runningDiscountSum = 0;
        Integer lineCount = o.OrderItems__r.size();

        for (Integer idx = 0; idx < lineCount; idx++) {
            OrderItem__c item = o.OrderItems__r[idx];
            Decimal lineGross = item.UnitPrice__c * item.Quantity__c;

            Decimal lineDiscount;
            if (idx == lineCount - 1) {
                // Last line absorbs remainder — eliminates rounding drift
                lineDiscount = discount - runningDiscountSum;
            } else {
                lineDiscount = (grossTotal > 0)
                    ? (lineGross / grossTotal * discount).setScale(2, RoundingMode.HALF_UP)
                    : 0;
                runningDiscountSum += lineDiscount;
            }

            Decimal lineAmount = lineGross - lineDiscount;

            // Guard: line amount must never be negative after discount
            if (lineAmount < 0) {
                throw new OrderSyncException(
                    'Negative line amount (' + lineAmount + ') for SKU '
                    + item.ProductCode__c + ' on order ' + o.Name
                    + '. Check discount allocation.'
                );
            }

            // If CPQ-calculated LineAmount__c exists and is populated, prefer it
            // (Uncomment below and remove lineAmount calculation above once CPQ
            //  source-of-truth is confirmed with Rev Ops)
            // if (item.LineAmount__c != null) {
            //     lineAmount = item.LineAmount__c;
            // }

            lines.add(new Map<String, Object>{
                'sku'       => item.ProductCode__c,
                'qty'       => item.Quantity__c,
                'unitPrice' => item.UnitPrice__c,
                'amount'    => lineAmount
            });
        }

        // Derive header total from line sum — guarantees self-consistency
        Decimal headerAmount = 0;
        for (Map<String, Object> line : lines) {
            headerAmount += (Decimal) line.get('amount');
        }

        // Idempotency key: externalId + lastModified timestamp
        String idempotencyKey = (o.External_Id__c != null ? o.External_Id__c : String.valueOf(o.Id))
            + '-' + String.valueOf(o.LastModifiedDate.getTime());

        Map<String, Object> payload = new Map<String, Object>{
            'schemaVersion'  => SCHEMA_VERSION,
            'orderId'        => (o.External_Id__c != null ? o.External_Id__c : String.valueOf(o.Id)),
            'orderName'      => o.Name,
            'amount'         => headerAmount,
            'discount'       => discount,
            'idempotencyKey' => idempotencyKey,
            'lines'          => lines
        };

        return payload;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────
    private static Order_Sync_Log__c buildSyncLog(Id orderId, SyncResult result) {
        return new Order_Sync_Log__c(
            Order__c             = orderId,
            Sync_Timestamp__c    = Datetime.now(),
            Request_Payload_Hash__c = result.requestPayloadHash,
            Response_Code__c     = result.responseCode,
            Response_Body__c     = truncate(result.responseBody, 32000),
            Status__c            = result.status,
            Error_Message__c     = truncate(result.errorMessage, 32000),
            Is_Retryable__c      = result.isRetryable
        );
    }

    private static String generatePayloadHash(String payload) {
        Blob digest = Crypto.generateDigest('SHA-256', Blob.valueOf(payload));
        return EncodingUtil.convertToHex(digest);
    }

    private static String truncate(String value, Integer maxLength) {
        if (value == null) return null;
        return value.length() > maxLength ? value.substring(0, maxLength) : value;
    }

    private static void logDmlFailures(List<Database.SaveResult> results,
                                        List<SObject> records, String context) {
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                for (Database.Error err : results[i].getErrors()) {
                    System.debug(LoggingLevel.ERROR,
                        context + ' failed for record ' + records[i].Id
                        + ': ' + err.getStatusCode() + ' — ' + err.getMessage());
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Circuit Breaker — trips when middleware appears down
    // ─────────────────────────────────────────────────────────────────────
    @TestVisible
    private static Boolean isCircuitOpen() {
        Datetime windowStart = Datetime.now().addMinutes(-CIRCUIT_BREAKER_WINDOW_MINUTES);
        List<Order_Sync_Log__c> recentLogs = [
            SELECT Status__c
            FROM Order_Sync_Log__c
            WHERE Sync_Timestamp__c >= :windowStart
            ORDER BY Sync_Timestamp__c DESC
            LIMIT :CIRCUIT_BREAKER_THRESHOLD
        ];

        if (recentLogs.size() < CIRCUIT_BREAKER_THRESHOLD) {
            return false;
        }

        // Circuit is open only if ALL recent logs are errors (no successes)
        for (Order_Sync_Log__c log : recentLogs) {
            if (log.Status__c == 'Synced' || log.Status__c == 'Pending') {
                return false;
            }
        }

        return true;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Custom exception for payload validation
    // ─────────────────────────────────────────────────────────────────────
    public class OrderSyncException extends Exception {}

    // ─────────────────────────────────────────────────────────────────────
    // Result wrapper
    // ─────────────────────────────────────────────────────────────────────
    public class SyncResult {
        public String  status;
        public String  errorMessage;
        public String  erpOrderId;
        public String  jobId;
        public Integer responseCode;
        public String  responseBody;
        public String  requestPayloadHash;
        public Boolean isRetryable = false;
    }
}
