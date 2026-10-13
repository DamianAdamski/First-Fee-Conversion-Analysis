-- 01_load_and_validate.sql
-- Data-quality checks on the raw tables. Each column = number of rows failing that check (0 = pass).

CREATE VIEW dq_checks AS
SELECT
    -- keys and missing values
    COUNT(*) - COUNT(DISTINCT user_id) AS duplicate_user_id,
    COUNT(*) FILTER (WHERE num_nulls(
        user_id, signup_date, platform, subscription_tier, num_children, channel_id,
        is_activated, has_allowance, allowance_amount, has_savings_goal, savings_goal_amount,
        has_successful_spend, successful_spend_count, has_failed_spend, failed_spend_count,
        has_login, login_count, has_family_login, family_login_count,
        has_notification_enabled, has_custom_card, fee_collected_m1) > 0) AS null_in_any_column,

    -- allowed values
    COUNT(*) FILTER (WHERE signup_date::date NOT BETWEEN '2024-01-01' AND '2024-12-31') AS signup_date_outside_2024,
    COUNT(*) FILTER (WHERE platform NOT IN ('iOS', 'Android', 'Web')) AS invalid_platform,
    COUNT(*) FILTER (WHERE subscription_tier NOT IN ('Everyday', 'Plus', 'Max')) AS invalid_subscription_tier,
    COUNT(*) FILTER (WHERE num_children < 1) AS num_children_below_1,

    -- lookup table
    COUNT(*) FILTER (WHERE channel_id NOT IN (SELECT channel_id FROM raw_channel_lookup)) AS channel_id_not_in_lookup,
    (SELECT COUNT(*) - COUNT(DISTINCT channel_id) FROM raw_channel_lookup) AS duplicate_channel_id_in_lookup,

    -- has_X flag must agree with its count / amount
    COUNT(*) FILTER (WHERE has_allowance <> (allowance_amount > 0)) AS flag_mismatch_allowance,
    COUNT(*) FILTER (WHERE has_savings_goal <> (savings_goal_amount > 0)) AS flag_mismatch_savings_goal,
    COUNT(*) FILTER (WHERE has_successful_spend <> (successful_spend_count > 0)) AS flag_mismatch_successful_spend,
    COUNT(*) FILTER (WHERE has_failed_spend <> (failed_spend_count > 0)) AS flag_mismatch_failed_spend,
    COUNT(*) FILTER (WHERE has_login <> (login_count > 0)) AS flag_mismatch_login,
    COUNT(*) FILTER (WHERE has_family_login <> (family_login_count > 0)) AS flag_mismatch_family_login,

    -- plausibility
    COUNT(*) FILTER (WHERE num_children <> FLOOR(num_children)
        OR channel_id <> FLOOR(channel_id)
        OR successful_spend_count <> FLOOR(successful_spend_count)
        OR failed_spend_count <> FLOOR(failed_spend_count)
        OR login_count <> FLOOR(login_count)
        OR family_login_count <> FLOOR(family_login_count)) AS non_integer_counts,
    COUNT(*) FILTER (WHERE allowance_amount < 0 OR savings_goal_amount < 0
        OR successful_spend_count < 0 OR failed_spend_count < 0
        OR login_count < 0 OR family_login_count < 0) AS negative_values,
    COUNT(*) FILTER (WHERE login_count > 30) AS login_count_above_30,
    COUNT(*) FILTER (WHERE login_count = 30) AS login_count_equals_30, -- info: expected (confirmed by the hiring team)
    COUNT(*) FILTER (WHERE family_login_count > login_count
        OR (has_family_login AND NOT has_login)) AS family_login_without_parent_login, -- known issue: planted (confirmed by the hiring team)

    -- funnel order: no activity or fee without an activated card
    COUNT(*) FILTER (WHERE NOT is_activated AND (has_allowance OR has_savings_goal
        OR has_successful_spend OR has_failed_spend OR has_login OR has_family_login
        OR has_notification_enabled OR has_custom_card)) AS not_activated_with_engagement,
    COUNT(*) FILTER (WHERE NOT is_activated AND fee_collected_m1) AS not_activated_with_fee_collected,
    COUNT(*) FILTER (WHERE is_activated AND NOT has_login) AS activated_without_any_login -- info only
FROM raw_customers;

-- Amount ranges (outliers / pence-vs-pounds check), users who set one up only
CREATE VIEW dq_amount_profile AS
SELECT
    MIN(allowance_amount) FILTER (WHERE allowance_amount > 0) AS allowance_min,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY allowance_amount)
        FILTER (WHERE allowance_amount > 0) AS allowance_median,
    MAX(allowance_amount) AS allowance_max,
    MIN(savings_goal_amount) FILTER (WHERE savings_goal_amount > 0) AS savings_goal_min,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY savings_goal_amount)
        FILTER (WHERE savings_goal_amount > 0) AS savings_goal_median,
    MAX(savings_goal_amount) AS savings_goal_max
FROM raw_customers;

-- allowance_amount should be a TOTAL, so it should rise with the number of children
CREATE VIEW dq_allowance_by_children AS
SELECT
    num_children::int AS num_children,
    COUNT(*) AS n_with_allowance,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY allowance_amount) AS median_allowance
FROM raw_customers
WHERE allowance_amount > 0
GROUP BY num_children
ORDER BY num_children;
