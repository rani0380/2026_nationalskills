-- Run each paragraph in a separate Zeppelin cell.
%flink.ssql
SET 'table.local-time-zone' = 'UTC';

%flink.ssql
CREATE TEMPORARY TABLE order_stream (
  order_id STRING,
  product_name STRING,
  price BIGINT,
  quantity INT,
  event_time TIMESTAMP(3),
  WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
  'connector' = 'kinesis',
  'stream' = 'wsc2026-order-stream',
  'aws.region' = 'ap-northeast-2',
  'scan.stream.initpos' = 'TRIM_HORIZON',
  'format' = 'json',
  'json.timestamp-format.standard' = 'SQL'
);

%flink.ssql(type=update)
SELECT COUNT(*) AS order_count
FROM order_stream
WHERE event_time > CURRENT_TIMESTAMP - INTERVAL '1' MINUTE;

%flink.ssql(type=update)
SELECT product_name, SUM(price * quantity) AS total_revenue
FROM order_stream
GROUP BY product_name;
