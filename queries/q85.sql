SELECT
  "substr"("r_reason_desc", 1, 20)
, "avg"("ws_quantity")
, "avg"("wr_refunded_cash")
, "avg"("wr_fee")
FROM
  ${database}.${schema}.web_sales
, ${database}.${schema}.web_returns
, ${database}.${schema}.web_page
, ${database}.${schema}.customer_demographics cd1
, ${database}.${schema}.customer_demographics cd2
, ${database}.${schema}.customer_address
, ${database}.${schema}.date_dim
, ${database}.${schema}.reason
WHERE ("ws_web_page_sk" = "wp_web_page_sk")
   AND ("ws_item_sk" = "wr_item_sk")
   AND ("ws_order_number" = "wr_order_number")
   AND ("ws_sold_date_sk" = "d_date_sk")
   AND ("d_year" = 2000)
   AND ("cd1"."cd_demo_sk" = "wr_refunded_cdemo_sk")
   AND ("cd2"."cd_demo_sk" = "wr_returning_cdemo_sk")
   AND ("ca_address_sk" = "wr_refunded_addr_sk")
   AND ("r_reason_sk" = "wr_reason_sk")
   AND ((("cd1"."cd_marital_status" = 'M')
         AND ("cd1"."cd_marital_status" = "cd2"."cd_marital_status")
         AND ("cd1"."cd_education_status" = 'Advanced Degree')
         AND ("cd1"."cd_education_status" = "cd2"."cd_education_status")
         AND ("ws_sales_price" BETWEEN DECIMAL '100.00' AND DECIMAL '150.00'))
      OR (("cd1"."cd_marital_status" = 'S')
         AND ("cd1"."cd_marital_status" = "cd2"."cd_marital_status")
         AND ("cd1"."cd_education_status" = 'College')
         AND ("cd1"."cd_education_status" = "cd2"."cd_education_status")
         AND ("ws_sales_price" BETWEEN DECIMAL '50.00' AND DECIMAL '100.00'))
      OR (("cd1"."cd_marital_status" = 'W')
         AND ("cd1"."cd_marital_status" = "cd2"."cd_marital_status")
         AND ("cd1"."cd_education_status" = '2 yr Degree')
         AND ("cd1"."cd_education_status" = "cd2"."cd_education_status")
         AND ("ws_sales_price" BETWEEN DECIMAL '150.00' AND DECIMAL '200.00')))
   AND ((("ca_country" = 'United States')
         AND ("ca_state" IN ('IN'      , 'OH'      , 'NJ'))
         AND ("ws_net_profit" BETWEEN 100 AND 200))
      OR (("ca_country" = 'United States')
         AND ("ca_state" IN ('WI'      , 'CT'      , 'KY'))
         AND ("ws_net_profit" BETWEEN 150 AND 300))
      OR (("ca_country" = 'United States')
         AND ("ca_state" IN ('LA'      , 'IA'      , 'AR'))
         AND ("ws_net_profit" BETWEEN 50 AND 250)))
GROUP BY "r_reason_desc"
ORDER BY "substr"("r_reason_desc", 1, 20) ASC, "avg"("ws_quantity") ASC, "avg"("wr_refunded_cash") ASC, "avg"("wr_fee") ASC
LIMIT 100
;
