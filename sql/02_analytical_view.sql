-- 02_analytical_view.sql
-- Fix data types, join channel names, add bands and flags. v_customers is the Tableau source.

CREATE VIEW stg_customers AS
SELECT
    user_id,
    signup_date::date AS signup_date,
    platform,
    subscription_tier,
    num_children::int AS num_children,
    channel_id::int AS channel_id,
    is_activated,
    has_allowance,
    allowance_amount,
    has_savings_goal,
    savings_goal_amount,
    has_successful_spend,
    successful_spend_count::int AS successful_spend_count,
    has_failed_spend,
    failed_spend_count::int AS failed_spend_count,
    has_login,
    login_count::int AS login_count,
    has_family_login,
    family_login_count::int AS family_login_count,
    has_notification_enabled,
    has_custom_card,
    fee_collected_m1
FROM raw_customers;

CREATE VIEW stg_channel_lookup AS
SELECT
    channel_id::int AS channel_id,
    channel_name,
    channel_group
FROM raw_channel_lookup;

CREATE VIEW v_customers AS
SELECT
    c.*,
    l.channel_name,
    l.channel_group,
    EXTRACT(MONTH FROM c.signup_date)::int AS signup_month,
    c.fee_collected_m1::int AS fee_collected_int, -- AVG() of 0/1 = rate
    c.is_activated::int AS is_activated_int,

    -- bands for the dose-response charts
    CASE
        WHEN c.login_count = 0 THEN '0'
        WHEN c.login_count <= 5 THEN '1-5'
        WHEN c.login_count <= 10 THEN '6-10'
        WHEN c.login_count <= 15 THEN '11-15'
        WHEN c.login_count <= 20 THEN '16-20'
        WHEN c.login_count <= 25 THEN '21-25'
        ELSE '26-30'
    END AS login_band,
    CASE
        WHEN c.failed_spend_count <= 3 THEN c.failed_spend_count::text
        ELSE '4+'
    END AS failed_spend_band,
    CASE
        WHEN c.family_login_count = 0 THEN '0'
        WHEN c.family_login_count <= 2 THEN '1-2'
        WHEN c.family_login_count <= 4 THEN '3-4'
        ELSE '5+'
    END AS family_login_band,
    CASE
        WHEN c.successful_spend_count = 0 THEN '0'
        WHEN c.successful_spend_count <= 2 THEN '1-2'
        WHEN c.successful_spend_count <= 5 THEN '3-5'
        WHEN c.successful_spend_count <= 8 THEN '6-8'
        ELSE '9+'
    END AS successful_spend_band,
    CASE
        WHEN c.allowance_amount = 0 THEN 'none'
        WHEN c.allowance_amount <= 10 THEN '£0-10'
        WHEN c.allowance_amount <= 20 THEN '£10-20'
        WHEN c.allowance_amount <= 30 THEN '£20-30'
        ELSE '£30+'
    END AS allowance_band,
    CASE
        WHEN c.savings_goal_amount = 0 THEN 'none'
        WHEN c.savings_goal_amount <= 25 THEN '£0-25'
        WHEN c.savings_goal_amount <= 50 THEN '£25-50'
        WHEN c.savings_goal_amount <= 75 THEN '£50-75'
        ELSE '£75+'
    END AS savings_goal_band,

    -- number of positive habits (failed spend excluded, it is a negative signal)
    c.has_allowance::int
    + c.has_savings_goal::int
    + c.has_successful_spend::int
    + c.has_family_login::int
    + c.has_notification_enabled::int
    + c.has_custom_card::int AS positive_behaviour_count,

    (c.has_family_login AND NOT c.has_login) AS dq_flag_family_login -- the 4 anomalies
FROM stg_customers c
LEFT JOIN stg_channel_lookup l
    ON c.channel_id = l.channel_id;
