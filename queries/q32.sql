SELECT "sum"("cs_ext_discount_amt") "excess discount amount"
FROM
  ${database}.${schema}.catalog_sales
, ${database}.${schema}.item
, ${database}.${schema}.date_dim
WHERE ("i_manufact_id" = 977)
   AND ("i_item_sk" = "cs_item_sk")
   AND ("d_date" BETWEEN CAST('2000-01-27' AS DATE) AND (CAST('2000-01-27' AS DATE) + INTERVAL  '90' DAY))
   AND ("d_date_sk" = "cs_sold_date_sk")
   AND ("cs_ext_discount_amt" > (
      SELECT (DECIMAL '1.3' * "avg"("cs_ext_discount_amt"))
      FROM
        ${database}.${schema}.catalog_sales
      , ${database}.${schema}.date_dim
      WHERE ("cs_item_sk" = "i_item_sk")
         AND ("d_date" BETWEEN CAST('2000-01-27' AS DATE) AND (CAST('2000-01-27' AS DATE) + INTERVAL  '90' DAY))
         AND ("d_date_sk" = "cs_sold_date_sk")
   ))
LIMIT 100
;
