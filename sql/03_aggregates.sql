-- 03_aggregates.sql
-- Tables behind the slides. Behaviours use activated users only (non-activated users can't pay).
-- ci = 1.96 * SQRT(p * (1 - p) / n), the same formula as in Tableau.

-- Funnel: one row
CREATE VIEW agg_funnel AS
SELECT
    COUNT(*) AS signups,
    COUNT(*) FILTER (WHERE is_activated) AS activated,
    COUNT(*) FILTER (WHERE fee_collected_m1) AS fee_collected,
    COUNT(*) FILTER (WHERE NOT is_activated) AS never_activated,
    COUNT(*) FILTER (WHERE is_activated AND NOT fee_collected_m1) AS activated_not_paid,
    AVG(is_activated_int) AS activation_rate,
    AVG(fee_collected_int) AS fee_rate_all_signups,
    AVG(fee_collected_int) FILTER (WHERE is_activated) AS fee_rate_activated
FROM v_customers;

-- Fee rate with vs without each behaviour.
-- GROUPING SETS = a separate GROUP BY per behaviour, in one query.
-- In each row one behaviour column is TRUE/FALSE and the rest are NULL.
CREATE VIEW agg_behaviour_lift AS
WITH grouped AS (
    SELECT
        has_allowance, has_savings_goal, has_successful_spend, has_failed_spend,
        has_login, has_family_login, has_notification_enabled, has_custom_card,
        COUNT(*) AS n,
        AVG(fee_collected_int) AS fee_rate
    FROM v_customers
    WHERE is_activated
    GROUP BY GROUPING SETS (
        (has_allowance), (has_savings_goal), (has_successful_spend), (has_failed_spend),
        (has_login), (has_family_login), (has_notification_enabled), (has_custom_card)
    )
)
SELECT *, 1.96 * SQRT(fee_rate * (1 - fee_rate) / n) AS ci
FROM grouped;

-- Fee rate by band of each count / amount
CREATE VIEW agg_dose_response AS
WITH grouped AS (
    SELECT
        login_band, failed_spend_band, family_login_band,
        successful_spend_band, allowance_band, savings_goal_band,
        COUNT(*) AS n,
        AVG(fee_collected_int) AS fee_rate
    FROM v_customers
    WHERE is_activated
    GROUP BY GROUPING SETS (
        (login_band), (failed_spend_band), (family_login_band),
        (successful_spend_band), (allowance_band), (savings_goal_band)
    )
)
SELECT *, 1.96 * SQRT(fee_rate * (1 - fee_rate) / n) AS ci
FROM grouped;

-- Fee rate by number of positive habits
CREATE VIEW agg_behaviour_count AS
WITH grouped AS (
    SELECT
        positive_behaviour_count,
        COUNT(*) AS n,
        AVG(fee_collected_int) AS fee_rate
    FROM v_customers
    WHERE is_activated
    GROUP BY positive_behaviour_count
)
SELECT *, 1.96 * SQRT(fee_rate * (1 - fee_rate) / n) AS ci
FROM grouped;

-- 2x2 of the two strongest behaviours
CREATE VIEW agg_allowance_family_matrix AS
SELECT
    has_allowance,
    has_family_login,
    COUNT(*) AS n,
    AVG(fee_collected_int) AS fee_rate
FROM v_customers
WHERE is_activated
GROUP BY has_allowance, has_family_login;

-- Segments: activation rate (all signups) and fee rate (activated users)
CREATE VIEW agg_segments AS
WITH grouped AS (
    SELECT
        platform, subscription_tier, channel_name, num_children, signup_month,
        COUNT(*) AS n_signups,
        COUNT(*) FILTER (WHERE is_activated) AS n_activated,
        AVG(is_activated_int) AS activation_rate,
        AVG(fee_collected_int) FILTER (WHERE is_activated) AS fee_rate_activated
    FROM v_customers
    GROUP BY GROUPING SETS (
        (platform), (subscription_tier), (channel_name), (num_children), (signup_month)
    )
)
SELECT *, 1.96 * SQRT(fee_rate_activated * (1 - fee_rate_activated) / n_activated) AS fee_rate_activated_ci
FROM grouped;

-- Segment fee rate split by allowance: is the segment gap just behaviour mix?
CREATE VIEW agg_segment_by_allowance AS
WITH grouped AS (
    SELECT
        platform, subscription_tier, channel_name, has_allowance,
        COUNT(*) AS n,
        AVG(fee_collected_int) AS fee_rate
    FROM v_customers
    WHERE is_activated
    GROUP BY GROUPING SETS (
        (platform, has_allowance), (subscription_tier, has_allowance), (channel_name, has_allowance)
    )
)
SELECT *, 1.96 * SQRT(fee_rate * (1 - fee_rate) / n) AS ci
FROM grouped;
