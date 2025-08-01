WITH
  cs_ui AS (
   SELECT
     "cs_item_sk"
   , "sum"("cs_ext_list_price") "sale"
   , "sum"((("cr_refunded_cash" + "cr_reversed_charge") + "cr_store_credit")) "refund"
   FROM
     ${database}.${schema}.catalog_sales
   , ${database}.${schema}.catalog_returns
   WHERE ("cs_item_sk" = "cr_item_sk")
      AND ("cs_order_number" = "cr_order_number")
   GROUP BY "cs_item_sk"
   HAVING ("sum"("cs_ext_list_price") > (2 * "sum"((("cr_refunded_cash" + "cr_reversed_charge") + "cr_store_credit"))))
) 
, cross_sales AS (
   SELECT
     "i_product_name" "product_name"
   , "i_item_sk" "item_sk"
   , "s_store_name" "store_name"
   , "s_zip" "store_zip"
   , "ad1"."ca_street_number" "b_street_number"
   , "ad1"."ca_street_name" "b_street_name"
   , "ad1"."ca_city" "b_city"
   , "ad1"."ca_zip" "b_zip"
   , "ad2"."ca_street_number" "c_street_number"
   , "ad2"."ca_street_name" "c_street_name"
   , "ad2"."ca_city" "c_city"
   , "ad2"."ca_zip" "c_zip"
   , "d1"."d_year" "syear"
   , "d2"."d_year" "fsyear"
   , "d3"."d_year" "s2year"
   , "count"(*) "cnt"
   , "sum"("ss_wholesale_cost") "s1"
   , "sum"("ss_list_price") "s2"
   , "sum"("ss_coupon_amt") "s3"
   FROM
     ${database}.${schema}.store_sales
   , ${database}.${schema}.store_returns
   , cs_ui
   , ${database}.${schema}.date_dim d1
   , ${database}.${schema}.date_dim d2
   , ${database}.${schema}.date_dim d3
   , ${database}.${schema}.store
   , ${database}.${schema}.customer
   , ${database}.${schema}.customer_demographics cd1
   , ${database}.${schema}.customer_demographics cd2
   , ${database}.${schema}.promotion
   , ${database}.${schema}.household_demographics hd1
   , ${database}.${schema}.household_demographics hd2
   , ${database}.${schema}.customer_address ad1
   , ${database}.${schema}.customer_address ad2
   , ${database}.${schema}.income_band ib1
   , ${database}.${schema}.income_band ib2
   , ${database}.${schema}.item
   WHERE ("ss_store_sk" = "s_store_sk")
      AND ("ss_sold_date_sk" = "d1"."d_date_sk")
      AND ("ss_customer_sk" = "c_customer_sk")
      AND ("ss_cdemo_sk" = "cd1"."cd_demo_sk")
      AND ("ss_hdemo_sk" = "hd1"."hd_demo_sk")
      AND ("ss_addr_sk" = "ad1"."ca_address_sk")
      AND ("ss_item_sk" = "i_item_sk")
      AND ("ss_item_sk" = "sr_item_sk")
      AND ("ss_ticket_number" = "sr_ticket_number")
      AND ("ss_item_sk" = "cs_ui"."cs_item_sk")
      AND ("c_current_cdemo_sk" = "cd2"."cd_demo_sk")
      AND ("c_current_hdemo_sk" = "hd2"."hd_demo_sk")
      AND ("c_current_addr_sk" = "ad2"."ca_address_sk")
      AND ("c_first_sales_date_sk" = "d2"."d_date_sk")
      AND ("c_first_shipto_date_sk" = "d3"."d_date_sk")
      AND ("ss_promo_sk" = "p_promo_sk")
      AND ("hd1"."hd_income_band_sk" = "ib1"."ib_income_band_sk")
      AND ("hd2"."hd_income_band_sk" = "ib2"."ib_income_band_sk")
      AND ("cd1"."cd_marital_status" <> "cd2"."cd_marital_status")
      AND ("i_color" IN ('purple'   , 'burlywood'   , 'indian'   , 'spring'   , 'floral'   , 'medium'))
      AND ("i_current_price" BETWEEN 64 AND (64 + 10))
      AND ("i_current_price" BETWEEN (64 + 1) AND (64 + 15))
   GROUP BY "i_product_name", "i_item_sk", "s_store_name", "s_zip", "ad1"."ca_street_number", "ad1"."ca_street_name", "ad1"."ca_city", "ad1"."ca_zip", "ad2"."ca_street_number", "ad2"."ca_street_name", "ad2"."ca_city", "ad2"."ca_zip", "d1"."d_year", "d2"."d_year", "d3"."d_year"
) 
SELECT
  "cs1"."product_name"
, "cs1"."store_name"
, "cs1"."store_zip"
, "cs1"."b_street_number"
, "cs1"."b_street_name"
, "cs1"."b_city"
, "cs1"."b_zip"
, "cs1"."c_street_number"
, "cs1"."c_street_name"
, "cs1"."c_city"
, "cs1"."c_zip"
, "cs1"."syear"
, "cs1"."cnt"
, "cs1"."s1" "s11"
, "cs1"."s2" "s21"
, "cs1"."s3" "s31"
, "cs2"."s1" "s12"
, "cs2"."s2" "s22"
, "cs2"."s3" "s32"
, "cs2"."syear"
, "cs2"."cnt"
FROM
  cross_sales cs1
, cross_sales cs2
WHERE ("cs1"."item_sk" = "cs2"."item_sk")
   AND ("cs1"."syear" = 1999)
   AND ("cs2"."syear" = (1999 + 1))
   AND ("cs2"."cnt" <= "cs1"."cnt")
   AND ("cs1"."store_name" = "cs2"."store_name")
   AND ("cs1"."store_zip" = "cs2"."store_zip")
ORDER BY "cs1"."product_name" ASC, "cs1"."store_name" ASC, "cs2"."cnt" ASC, 14, 15, 16, 17, 18
;
