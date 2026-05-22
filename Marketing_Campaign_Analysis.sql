-- ============================================================
-- FreshCart India - Marketing Campaign Performance Analysis
-- MySQL 8.0 | Data Cleaning + KPI Computation + EDA
-- ============================================================

-- ============================================================
-- SECTION 1: INSPECT RAW DATA
-- ============================================================

-- 1.1 Row counts
SELECT 'campaign_raw' AS tbl, COUNT(*) AS total_rows FROM campaign_raw
UNION ALL
SELECT 'spend_raw', COUNT(*) FROM spend_raw
UNION ALL
SELECT 'audience_raw', COUNT(*) FROM audience_raw;

-- 1.2 Sample rows
SELECT * FROM campaign_raw LIMIT 5;
SELECT * FROM spend_raw LIMIT 5;
SELECT * FROM audience_raw LIMIT 5;

-- 1.3 Quick data-quality check for campaign_raw
SELECT
    SUM(Spend_INR IS NULL) AS null_spend,
    SUM(Revenue_INR IS NULL OR Revenue_INR = '') AS null_revenue,
    SUM(Conversions IS NULL) AS null_conversions,
    SUM(Impressions = 0) AS zero_impressions,
    SUM(Clicks < 0) AS negative_clicks,
    SUM(Revenue_INR LIKE 'Rs.%') AS rs_prefix_revenue
FROM campaign_raw
WHERE Date IS NOT NULL;

-- 1.4 Distinct values
SELECT DISTINCT Channel FROM campaign_raw ORDER BY Channel;
SELECT DISTINCT Channel FROM spend_raw ORDER BY Channel;
SELECT DISTINCT Device FROM spend_raw ORDER BY Device;

-- 1.5 Duplicate check
SELECT
    Date,
    Channel,
    Campaign_Name,
    Region,
    City,
    ROUND(Spend_INR, 2) AS spend_inr,
    COUNT(*) AS dup_count
FROM campaign_raw
GROUP BY Date, Channel, Campaign_Name, Region, City, ROUND(Spend_INR, 2)
HAVING COUNT(*) > 1
LIMIT 10;


-- ============================================================
-- SECTION 2: CREATE campaign_clean
-- ============================================================
-- Raw file format:
-- Date = dd-mm-yyyy
-- Audit notes from campaign_raw.csv:
-- 8902 rows
-- 61 blank/null Spend_INR
-- 70 blank/null Revenue_INR
-- 41 blank Conversions
-- 30 rows with 0 impressions
-- 41 rows with negative clicks
-- 41 rows with 'Rs.' revenue prefix
-- 150 duplicate groups on
-- (Date, Channel, Campaign_Name, Region, City, Spend_INR)
-- Columns:
-- Date, Channel, Campaign_Name, Product_Category, Region, City,
-- Spend_INR, Impressions, Clicks, Conversions, Revenue_INR, Campaign_ID
-- ============================================================

DROP TABLE IF EXISTS campaign_clean;

CREATE TABLE campaign_clean AS
SELECT
    t.clean_date AS `date`,
    t.channel,
    t.campaign_name,
    t.product_category,
    t.region,
    t.city,
    t.spend_inr,
    t.impressions,
    t.clicks,
    t.conversions,
    t.revenue_inr,
    ROUND(t.clicks / NULLIF(t.impressions, 0) * 100, 4) AS ctr_pct,
    ROUND(t.conversions / NULLIF(t.clicks, 0) * 100, 4) AS cvr_pct,
    ROUND(t.spend_inr / NULLIF(t.clicks, 0), 2) AS cpc_inr,
    ROUND((t.revenue_inr - t.spend_inr) / NULLIF(t.spend_inr, 0) * 100, 2) AS roi_pct,
    ROUND(t.revenue_inr / NULLIF(t.spend_inr, 0), 4) AS roas,
    ROUND(t.spend_inr / NULLIF(t.conversions, 0), 2) AS cac_inr,
    DATE_FORMAT(t.clean_date, '%Y-%m') AS `month`,
    CONCAT(YEAR(t.clean_date), '-Q', QUARTER(t.clean_date)) AS `quarter`,
    YEAR(t.clean_date) AS `year`,
    WEEK(t.clean_date, 1) AS week_num,
    t.campaign_id
FROM (
    SELECT
        STR_TO_DATE(TRIM(Date), '%d-%m-%Y') AS clean_date,

        CASE
            WHEN NULLIF(TRIM(Channel), '') IS NULL THEN NULL
            WHEN LOWER(TRIM(Channel)) = 'meta' THEN 'Meta'
            WHEN LOWER(TRIM(Channel)) = 'google' THEN 'Google'
            WHEN LOWER(TRIM(Channel)) = 'linkedin' THEN 'Linkedin'
            WHEN LOWER(TRIM(Channel)) = 'youtube' THEN 'Youtube'
            ELSE CONCAT(UPPER(LEFT(LOWER(TRIM(Channel)), 1)), LOWER(SUBSTRING(TRIM(Channel), 2)))
        END AS channel,

        NULLIF(TRIM(Campaign_Name), '') AS campaign_name,
        NULLIF(TRIM(Product_Category), '') AS product_category,

        CASE
            WHEN NULLIF(TRIM(Region), '') IS NULL THEN NULL
            ELSE CONCAT(UPPER(LEFT(LOWER(TRIM(Region)), 1)), LOWER(SUBSTRING(TRIM(Region), 2)))
        END AS region,

        CASE
            WHEN NULLIF(TRIM(City), '') IS NULL THEN NULL
            ELSE CONCAT(UPPER(LEFT(LOWER(TRIM(City)), 1)), LOWER(SUBSTRING(TRIM(City), 2)))
        END AS city,

        CAST(NULLIF(TRIM(Spend_INR), '') AS DECIMAL(14,2)) AS spend_inr,
        CAST(NULLIF(TRIM(Impressions), '') AS UNSIGNED) AS impressions,
        ABS(CAST(NULLIF(TRIM(Clicks), '') AS SIGNED)) AS clicks,
        CAST(COALESCE(NULLIF(TRIM(Conversions), ''), '0') AS UNSIGNED) AS conversions,
        CAST(
            NULLIF(REGEXP_REPLACE(TRIM(Revenue_INR), '[^0-9.]', ''), '')
            AS DECIMAL(14,2)
        ) AS revenue_inr,
        NULLIF(TRIM(Campaign_ID), '') AS campaign_id,

        ROW_NUMBER() OVER (
            PARTITION BY
                TRIM(Date),
                LOWER(TRIM(Channel)),
                TRIM(Campaign_Name),
                LOWER(TRIM(Region)),
                LOWER(TRIM(City)),
                TRIM(Spend_INR)
            ORDER BY TRIM(Campaign_ID)
        ) AS rn
    FROM campaign_raw
) AS t
WHERE t.rn = 1
  AND t.clean_date IS NOT NULL
  AND t.channel IS NOT NULL
  AND t.campaign_name IS NOT NULL
  AND t.spend_inr IS NOT NULL
  AND t.spend_inr > 0
  AND t.revenue_inr IS NOT NULL
  AND t.revenue_inr > 0
  AND t.impressions IS NOT NULL
  AND t.impressions > 0
  AND t.clicks IS NOT NULL;

SELECT COUNT(*) AS campaign_clean_rows FROM campaign_clean;


-- ============================================================
-- SECTION 3: CREATE spend_clean
-- ============================================================
-- Raw file format:
-- Date = dd/mm/yyyy
-- Audit notes from spend_raw.csv:
-- 13228 rows
-- 60 blank/null Spend_INR
-- 50 blank Clicks
-- 20 rows with CPC_INR = -99 placeholder
-- 41 rows with uppercase channel values
-- 30 rows with lowercase device values
-- 100 duplicate groups on
-- (Date, Channel, Placement, Device, Spend_INR)
-- Columns:
-- Date, Channel, Placement, Device, Spend_INR, Impressions, Clicks, CPC_INR
-- ============================================================

DROP TABLE IF EXISTS spend_clean;

CREATE TABLE spend_clean AS
SELECT
    t.clean_date AS `date`,
    t.channel,
    t.placement,
    t.device,
    t.spend_inr,
    t.impressions,
    t.clicks,
    CASE
        WHEN t.cpc_inr IS NULL THEN NULL
        WHEN t.cpc_inr < 0 THEN NULL
        WHEN t.cpc_inr > 500 THEN NULL
        ELSE ROUND(t.cpc_inr, 2)
    END AS cpc_inr
FROM (
    SELECT
        STR_TO_DATE(TRIM(Date), '%d/%m/%Y') AS clean_date,

        CASE
            WHEN NULLIF(TRIM(Channel), '') IS NULL THEN NULL
            WHEN LOWER(TRIM(Channel)) = 'meta' THEN 'Meta'
            WHEN LOWER(TRIM(Channel)) = 'google' THEN 'Google'
            WHEN LOWER(TRIM(Channel)) = 'linkedin' THEN 'Linkedin'
            WHEN LOWER(TRIM(Channel)) = 'youtube' THEN 'Youtube'
            ELSE CONCAT(UPPER(LEFT(LOWER(TRIM(Channel)), 1)), LOWER(SUBSTRING(TRIM(Channel), 2)))
        END AS channel,

        NULLIF(TRIM(Placement), '') AS placement,

        CASE
            WHEN NULLIF(TRIM(Device), '') IS NULL THEN NULL
            ELSE CONCAT(UPPER(LEFT(LOWER(TRIM(Device)), 1)), LOWER(SUBSTRING(TRIM(Device), 2)))
        END AS device,

        CAST(NULLIF(TRIM(Spend_INR), '') AS DECIMAL(14,2)) AS spend_inr,
        CAST(NULLIF(TRIM(Impressions), '') AS UNSIGNED) AS impressions,
        CAST(NULLIF(TRIM(Clicks), '') AS UNSIGNED) AS clicks,
        CAST(NULLIF(TRIM(CPC_INR), '') AS DECIMAL(10,2)) AS cpc_inr,

        ROW_NUMBER() OVER (
            PARTITION BY
                TRIM(Date),
                LOWER(TRIM(Channel)),
                TRIM(Placement),
                LOWER(TRIM(Device)),
                TRIM(Spend_INR)
            ORDER BY TRIM(Date)
        ) AS rn
    FROM spend_raw
) AS t
WHERE t.rn = 1
  AND t.clean_date IS NOT NULL
  AND t.channel IS NOT NULL
  AND t.spend_inr IS NOT NULL
  AND t.spend_inr > 0
  AND t.impressions IS NOT NULL
  AND t.clicks IS NOT NULL;

SELECT COUNT(*) AS spend_clean_rows FROM spend_clean;


-- ============================================================
-- SECTION 4: CREATE audience_clean
-- ============================================================
-- Raw file format:
-- Week_Starting = yyyy/mm/dd
-- Audit notes from audience_raw.csv:
-- 4740 rows
-- 41 blank/null Spend_INR
-- 40 blank/null Revenue_INR
-- 20 rows with Age_Group = 'unknown'
-- 20 rows with Gender = 'N/A'
-- 60 duplicate groups on
-- (Week_Starting, Channel, Age_Group, Gender)
-- Columns:
-- Week_Starting, Channel, Age_Group, Gender,
-- Impressions, Clicks, Conversions, Spend_INR, Revenue_INR
-- ============================================================

DROP TABLE IF EXISTS audience_clean;

CREATE TABLE audience_clean AS
SELECT
    t.week_starting,
    t.channel,
    t.age_group,
    t.gender,
    t.impressions,
    t.clicks,
    t.conversions,
    t.spend_inr,
    t.revenue_inr
FROM (
    SELECT
        STR_TO_DATE(TRIM(Week_Starting), '%Y/%m/%d') AS week_starting,

        CASE
            WHEN NULLIF(TRIM(Channel), '') IS NULL THEN NULL
            WHEN LOWER(TRIM(Channel)) = 'meta' THEN 'Meta'
            WHEN LOWER(TRIM(Channel)) = 'google' THEN 'Google'
            WHEN LOWER(TRIM(Channel)) = 'linkedin' THEN 'Linkedin'
            WHEN LOWER(TRIM(Channel)) = 'youtube' THEN 'Youtube'
            ELSE CONCAT(UPPER(LEFT(LOWER(TRIM(Channel)), 1)), LOWER(SUBSTRING(TRIM(Channel), 2)))
        END AS channel,

        CASE
            WHEN NULLIF(TRIM(Age_Group), '') IS NULL THEN 'Unknown'
            WHEN LOWER(TRIM(Age_Group)) = 'unknown' THEN 'Unknown'
            ELSE TRIM(Age_Group)
        END AS age_group,

        CASE
            WHEN NULLIF(TRIM(Gender), '') IS NULL THEN 'Unknown'
            WHEN UPPER(TRIM(Gender)) IN ('N/A', 'NA') THEN 'Unknown'
            WHEN LOWER(TRIM(Gender)) = 'male' THEN 'Male'
            WHEN LOWER(TRIM(Gender)) = 'female' THEN 'Female'
            ELSE 'Unknown'
        END AS gender,

        CAST(NULLIF(TRIM(Impressions), '') AS UNSIGNED) AS impressions,
        CAST(NULLIF(TRIM(Clicks), '') AS UNSIGNED) AS clicks,
        CAST(NULLIF(TRIM(Conversions), '') AS UNSIGNED) AS conversions,
        CAST(NULLIF(TRIM(Spend_INR), '') AS DECIMAL(14,2)) AS spend_inr,
        CAST(NULLIF(TRIM(Revenue_INR), '') AS DECIMAL(14,2)) AS revenue_inr,

        ROW_NUMBER() OVER (
            PARTITION BY
                TRIM(Week_Starting),
                LOWER(TRIM(Channel)),
                CASE
                    WHEN NULLIF(TRIM(Age_Group), '') IS NULL THEN 'unknown'
                    WHEN LOWER(TRIM(Age_Group)) = 'unknown' THEN 'unknown'
                    ELSE TRIM(Age_Group)
                END,
                CASE
                    WHEN NULLIF(TRIM(Gender), '') IS NULL THEN 'unknown'
                    WHEN UPPER(TRIM(Gender)) IN ('N/A', 'NA') THEN 'unknown'
                    WHEN LOWER(TRIM(Gender)) = 'male' THEN 'male'
                    WHEN LOWER(TRIM(Gender)) = 'female' THEN 'female'
                    ELSE 'unknown'
                END
            ORDER BY TRIM(Week_Starting)
        ) AS rn
    FROM audience_raw
) AS t
WHERE t.rn = 1
  AND t.week_starting IS NOT NULL
  AND t.channel IS NOT NULL
  AND t.impressions IS NOT NULL
  AND t.clicks IS NOT NULL
  AND t.spend_inr IS NOT NULL
  AND t.spend_inr > 0
  AND t.revenue_inr IS NOT NULL
  AND t.revenue_inr > 0;

SELECT COUNT(*) AS audience_clean_rows FROM audience_clean;


-- ============================================================
-- SECTION 5: EDA - 18 Analytical Queries
-- ============================================================

-- EDA 01: Overall KPIs
SELECT
    ROUND(SUM(spend_inr) / 100000, 2) AS total_spend_lakhs,
    ROUND(SUM(revenue_inr) / 100000, 2) AS total_revenue_lakhs,
    SUM(conversions) AS total_conversions,
    SUM(clicks) AS total_clicks,
    SUM(impressions) AS total_impressions,
    ROUND((SUM(revenue_inr) - SUM(spend_inr)) / SUM(spend_inr) * 100, 1) AS overall_roi_pct,
    ROUND(SUM(revenue_inr) / SUM(spend_inr), 2) AS overall_roas,
    ROUND(SUM(clicks) / NULLIF(SUM(impressions), 0) * 100, 2) AS overall_ctr_pct,
    ROUND(SUM(conversions) / NULLIF(SUM(clicks), 0) * 100, 2) AS overall_cvr_pct,
    ROUND(SUM(spend_inr) / NULLIF(SUM(conversions), 0), 0) AS overall_cac
FROM campaign_clean;

-- EDA 02: Channel performance ranked by ROI
SELECT
    channel,
    COUNT(*) AS total_rows,
    ROUND(SUM(spend_inr) / 100000, 1) AS spend_L,
    ROUND(SUM(revenue_inr) / 100000, 1) AS revenue_L,
    SUM(conversions) AS conversions,
    ROUND((SUM(revenue_inr) - SUM(spend_inr)) / SUM(spend_inr) * 100, 1) AS roi_pct,
    ROUND(SUM(revenue_inr) / SUM(spend_inr), 2) AS roas,
    ROUND(SUM(spend_inr) / NULLIF(SUM(conversions), 0), 0) AS cac_inr,
    ROUND(SUM(clicks) / NULLIF(SUM(impressions), 0) * 100, 2) AS ctr_pct,
    ROUND(SUM(conversions) / NULLIF(SUM(clicks), 0) * 100, 2) AS cvr_pct,
    ROUND(SUM(spend_inr) / SUM(SUM(spend_inr)) OVER () * 100, 1) AS spend_share_pct
FROM campaign_clean
GROUP BY channel
ORDER BY roi_pct DESC;

-- EDA 03: Monthly revenue and ROI trend
SELECT
    `month`,
    spend_L,
    revenue_L,
    conversions,
    roi_pct,
    roas,
    ROUND(revenue_L - LAG(revenue_L) OVER (ORDER BY `month`), 2) AS mom_change_L
FROM (
    SELECT
        `month`,
        ROUND(SUM(spend_inr) / 100000, 2) AS spend_L,
        ROUND(SUM(revenue_inr) / 100000, 2) AS revenue_L,
        SUM(conversions) AS conversions,
        ROUND((SUM(revenue_inr) - SUM(spend_inr)) / SUM(spend_inr) * 100, 1) AS roi_pct,
        ROUND(SUM(revenue_inr) / SUM(spend_inr), 2) AS roas
    FROM campaign_clean
    GROUP BY `month`
) AS monthly_sub
ORDER BY `month`;

-- EDA 04: Quarterly aggregation
SELECT
    `quarter`,
    ROUND(SUM(spend_inr) / 100000, 2) AS spend_L,
    ROUND(SUM(revenue_inr) / 100000, 2) AS revenue_L,
    SUM(conversions) AS conversions,
    ROUND((SUM(revenue_inr) - SUM(spend_inr)) / SUM(spend_inr) * 100, 1) AS roi_pct,
    ROUND(SUM(revenue_inr) / SUM(spend_inr), 2) AS roas
FROM campaign_clean
GROUP BY `quarter`
ORDER BY `quarter`;

-- EDA 05: Regional performance ranked by ROI
SELECT
    region,
    ROUND(SUM(spend_inr) / 100000, 1) AS spend_L,
    ROUND(SUM(revenue_inr) / 100000, 1) AS revenue_L,
    SUM(conversions) AS conversions,
    ROUND((SUM(revenue_inr) - SUM(spend_inr)) / SUM(spend_inr) * 100, 1) AS roi_pct,
    ROUND(SUM(revenue_inr) / SUM(spend_inr), 2) AS roas
FROM campaign_clean
GROUP BY region
ORDER BY roi_pct DESC;

-- EDA 06: Top 10 cities by revenue
SELECT
    city,
    region,
    ROUND(SUM(revenue_inr) / 100000, 2) AS revenue_L,
    ROUND(SUM(spend_inr) / 100000, 2) AS spend_L,
    ROUND((SUM(revenue_inr) - SUM(spend_inr)) / SUM(spend_inr) * 100, 1) AS roi_pct,
    SUM(conversions) AS conversions
FROM campaign_clean
GROUP BY city, region
ORDER BY revenue_L DESC
LIMIT 10;

-- EDA 07: Product category breakdown
SELECT
    product_category,
    ROUND(SUM(spend_inr) / 100000, 2) AS spend_L,
    ROUND(SUM(revenue_inr) / 100000, 2) AS revenue_L,
    SUM(conversions) AS conversions,
    ROUND((SUM(revenue_inr) - SUM(spend_inr)) / SUM(spend_inr) * 100, 1) AS roi_pct
FROM campaign_clean
GROUP BY product_category
ORDER BY revenue_L DESC;

-- EDA 08: Channel x Region ROI matrix
SELECT
    region,
    ROUND(
        SUM(CASE WHEN channel = 'Google' THEN revenue_inr ELSE 0 END) /
        NULLIF(SUM(CASE WHEN channel = 'Google' THEN spend_inr ELSE 0 END), 0) * 100 - 100,
        1
    ) AS google_roi_pct,
    ROUND(
        SUM(CASE WHEN channel = 'Meta' THEN revenue_inr ELSE 0 END) /
        NULLIF(SUM(CASE WHEN channel = 'Meta' THEN spend_inr ELSE 0 END), 0) * 100 - 100,
        1
    ) AS meta_roi_pct,
    ROUND(
        SUM(CASE WHEN channel = 'Linkedin' THEN revenue_inr ELSE 0 END) /
        NULLIF(SUM(CASE WHEN channel = 'Linkedin' THEN spend_inr ELSE 0 END), 0) * 100 - 100,
        1
    ) AS linkedin_roi_pct,
    ROUND(
        SUM(CASE WHEN channel = 'Youtube' THEN revenue_inr ELSE 0 END) /
        NULLIF(SUM(CASE WHEN channel = 'Youtube' THEN spend_inr ELSE 0 END), 0) * 100 - 100,
        1
    ) AS youtube_roi_pct
FROM campaign_clean
GROUP BY region
ORDER BY region;

-- EDA 09: Top 10 campaigns by ROAS
SELECT
    campaign_name,
    channel,
    ROUND(SUM(spend_inr) / 100000, 2) AS spend_L,
    ROUND(SUM(revenue_inr) / 100000, 2) AS revenue_L,
    SUM(conversions) AS conversions,
    ROUND((SUM(revenue_inr) - SUM(spend_inr)) / SUM(spend_inr) * 100, 1) AS roi_pct,
    ROUND(SUM(revenue_inr) / SUM(spend_inr), 2) AS roas
FROM campaign_clean
GROUP BY campaign_name, channel
ORDER BY roas DESC
LIMIT 10;

-- EDA 10: Device spend share from spend_clean
SELECT
    device,
    ROUND(SUM(spend_inr) / 100000, 2) AS spend_L,
    SUM(impressions) AS impressions,
    SUM(clicks) AS clicks,
    ROUND(SUM(clicks) / NULLIF(SUM(impressions), 0) * 100, 2) AS ctr_pct,
    ROUND(SUM(spend_inr) / NULLIF(SUM(clicks), 0), 2) AS avg_cpc,
    ROUND(SUM(spend_inr) / SUM(SUM(spend_inr)) OVER () * 100, 1) AS spend_share_pct
FROM spend_clean
GROUP BY device
ORDER BY spend_L DESC;

-- EDA 11: Placement CTR by channel
SELECT
    channel,
    placement,
    ROUND(SUM(spend_inr) / 100000, 2) AS spend_L,
    SUM(clicks) AS clicks,
    ROUND(SUM(clicks) / NULLIF(SUM(impressions), 0) * 100, 2) AS ctr_pct,
    ROUND(SUM(spend_inr) / NULLIF(SUM(clicks), 0), 2) AS avg_cpc
FROM spend_clean
GROUP BY channel, placement
ORDER BY channel, ctr_pct DESC;

-- EDA 12: Age group conversion analysis
SELECT
    age_group,
    SUM(conversions) AS total_conversions,
    SUM(clicks) AS total_clicks,
    ROUND(SUM(conversions) / NULLIF(SUM(clicks), 0) * 100, 2) AS cvr_pct,
    ROUND(SUM(spend_inr) / 100000, 2) AS spend_L,
    ROUND(SUM(revenue_inr) / 100000, 2) AS revenue_L,
    ROUND((SUM(revenue_inr) - SUM(spend_inr)) / SUM(spend_inr) * 100, 1) AS roi_pct
FROM audience_clean
WHERE age_group != 'Unknown'
GROUP BY age_group
ORDER BY total_conversions DESC;

-- EDA 13: Gender CVR comparison
SELECT
    gender,
    SUM(conversions) AS conversions,
    SUM(clicks) AS clicks,
    ROUND(SUM(conversions) / NULLIF(SUM(clicks), 0) * 100, 2) AS cvr_pct,
    ROUND(SUM(revenue_inr) / 100000, 2) AS revenue_L,
    ROUND((SUM(revenue_inr) - SUM(spend_inr)) / SUM(spend_inr) * 100, 1) AS roi_pct
FROM audience_clean
WHERE gender != 'Unknown'
GROUP BY gender
ORDER BY cvr_pct DESC;

-- EDA 14: Cumulative revenue by month
SELECT
    `month`,
    monthly_rev_L,
    ROUND(SUM(monthly_rev_L) OVER (ORDER BY `month`), 2) AS cumulative_rev_L
FROM (
    SELECT
        `month`,
        ROUND(SUM(revenue_inr) / 100000, 2) AS monthly_rev_L
    FROM campaign_clean
    GROUP BY `month`
) AS monthly_base
ORDER BY `month`;

-- EDA 15: Month-over-month growth using LAG
WITH monthly AS (
    SELECT
        `month`,
        ROUND(SUM(revenue_inr) / 100000, 2) AS revenue_L
    FROM campaign_clean
    GROUP BY `month`
)
SELECT
    `month`,
    revenue_L,
    LAG(revenue_L) OVER (ORDER BY `month`) AS prev_month_L,
    ROUND(
        (revenue_L - LAG(revenue_L) OVER (ORDER BY `month`)) /
        NULLIF(LAG(revenue_L) OVER (ORDER BY `month`), 0) * 100,
        1
    ) AS mom_growth_pct
FROM monthly
ORDER BY `month`;

-- EDA 16: Best performing month per channel
WITH channel_monthly AS (
    SELECT
        channel,
        `month`,
        ROUND(SUM(revenue_inr) / 100000, 2) AS revenue_L,
        ROUND(SUM(revenue_inr) / SUM(spend_inr), 2) AS roas
    FROM campaign_clean
    GROUP BY channel, `month`
),
ranked AS (
    SELECT
        channel,
        `month`,
        revenue_L,
        roas,
        RANK() OVER (PARTITION BY channel ORDER BY revenue_L DESC) AS rev_rank
    FROM channel_monthly
)
SELECT
    channel,
    `month`,
    revenue_L,
    roas
FROM ranked
WHERE rev_rank = 1
ORDER BY revenue_L DESC;

-- EDA 17: Underperforming channel-region combos
SELECT
    channel,
    region,
    ROUND(SUM(spend_inr) / 100000, 2) AS spend_L,
    ROUND((SUM(revenue_inr) - SUM(spend_inr)) / SUM(spend_inr) * 100, 1) AS roi_pct,
    ROUND(SUM(revenue_inr) / SUM(spend_inr), 2) AS roas
FROM campaign_clean
GROUP BY channel, region
HAVING ROUND(SUM(revenue_inr) / SUM(spend_inr), 2) < 1.8
ORDER BY roas ASC;
 
-- EDA 18: Budget efficiency recommendation
SELECT
    channel,
    ROUND(SUM(spend_inr) / 100000, 1) AS spend_L,
    ROUND(SUM(spend_inr) / SUM(SUM(spend_inr)) OVER () * 100, 1) AS spend_share_pct,
    ROUND((SUM(revenue_inr) - SUM(spend_inr)) / SUM(spend_inr) * 100, 1) AS roi_pct,
    ROUND(SUM(revenue_inr) / SUM(spend_inr), 2) AS roas,
    CASE
        WHEN ROUND(SUM(revenue_inr) / SUM(spend_inr), 2) < 2.0 THEN 'REALLOCATE - below 2x ROAS threshold'
        WHEN ROUND(SUM(revenue_inr) / SUM(spend_inr), 2) < 2.5 THEN 'REVIEW - marginal performance'
        ELSE 'SCALE - strong performer'
    END AS recommendation
FROM campaign_clean
GROUP BY channel
ORDER BY roi_pct DESC;


-- ============================================================
-- SECTION 6: EXPORT CLEAN TABLES
-- ============================================================

SELECT * FROM campaign_clean;
SELECT * FROM spend_clean;
SELECT * FROM audience_clean;


-- ============================================================
-- FINAL VERIFICATION
-- ============================================================

SELECT 'campaign_clean' AS clean_table, COUNT(*) AS row_count FROM campaign_clean
UNION ALL
SELECT 'spend_clean', COUNT(*) FROM spend_clean
UNION ALL
SELECT 'audience_clean', COUNT(*) FROM audience_clean;
