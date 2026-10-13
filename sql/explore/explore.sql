-- explore.sql
-- My exploration: each query has a question, the SQL, and what I found.
-- Run one query at a time: highlight it, press F5, then fill in "Result:".

SET search_path TO fee_analysis;


-- PART 1: Raw data

-- Q1: What does the data look like?
SELECT * FROM raw_customers LIMIT 10;
-- Result: for my own benefit

-- Q2: How many customers?
SELECT COUNT(*) FROM raw_customers;
-- Result: count = 5000 

-- Q3: What channels are there?
SELECT * FROM raw_channel_lookup;
-- Result: too long to list here


-- PART 2: Data quality (file 01)

-- Q4: Which data-quality checks fail?
SELECT * FROM dq_checks;
-- Result: 
--		login_count_equals_30 = 8/ may be an issue depending when the count starts
--		family_login_without_parent_login = 4 / it seems impossible, as by definition a family login requires a parent login
--		activated_without_any_login = 46 / 
--		all other fields are 0 as expected

-- Q5: Which rows have a family login but no parent login?
SELECT user_id, has_login, login_count, has_family_login, family_login_count
FROM raw_customers
WHERE has_family_login AND NOT has_login;
-- Result:user_id = 00470,02644,03034,03643

-- Q6: Did anyone who never activated pay a fee?
SELECT is_activated, COUNT(*) AS users, SUM(fee_collected_m1::int) AS paid
FROM raw_customers
GROUP BY is_activated;
-- Result: only those who activated paid a fee, so activation is a gate. 


-- PART 3: Clean view (file 02)

-- Q7: Did the channel join lose or duplicate any rows?
SELECT COUNT(*), COUNT(DISTINCT user_id), COUNT(channel_name)
FROM v_customers;
-- Result: No duplicates

-- Q8: Are the login bands correct?
SELECT login_band, MIN(login_count), MAX(login_count), COUNT(*)
FROM v_customers
GROUP BY login_band
ORDER BY MIN(login_count);
-- Result: they are correct (within range)


-- PART 4: Results (file 03)

-- Q9: What does the funnel look like?
SELECT * FROM agg_funnel;
-- Result: Signups must always be activated to be paid, activation rate is 84.7%, and the fee rate among
-- activated users is 65%

-- Q10: Do users with an allowance pay more often? (activated users only)
SELECT has_allowance, COUNT(*), AVG(fee_collected_int)
FROM v_customers
WHERE is_activated
GROUP BY has_allowance;
-- Result: Yes, there is a big difference: 54% of those without an allowance paid vs 82% of those with one.

-- Q11: Which behaviours matter most?
SELECT * FROM agg_behaviour_lift
ORDER BY fee_rate DESC; 
-- Result: Top 5 behaviours in a descending order based on fee rate are:
-- has allowance
-- has family login
-- has custom card
-- has savings goal
-- has successful spend

-- Q11b: Gap in fee rate between "yes" and "no" for each behaviour (activated users)
-- Better than Q11: Q11 only looks at the "yes" group, this compares yes vs no.
SELECT
    AVG(fee_collected_int) FILTER (WHERE has_allowance)
  - AVG(fee_collected_int) FILTER (WHERE NOT has_allowance) AS gap_allowance,
    AVG(fee_collected_int) FILTER (WHERE has_family_login)
  - AVG(fee_collected_int) FILTER (WHERE NOT has_family_login) AS gap_family_login,
    AVG(fee_collected_int) FILTER (WHERE has_savings_goal)
  - AVG(fee_collected_int) FILTER (WHERE NOT has_savings_goal) AS gap_savings_goal,
    AVG(fee_collected_int) FILTER (WHERE has_successful_spend)
  - AVG(fee_collected_int) FILTER (WHERE NOT has_successful_spend) AS gap_successful_spend,
    AVG(fee_collected_int) FILTER (WHERE has_custom_card)
  - AVG(fee_collected_int) FILTER (WHERE NOT has_custom_card) AS gap_custom_card,
    AVG(fee_collected_int) FILTER (WHERE has_notification_enabled)
  - AVG(fee_collected_int) FILTER (WHERE NOT has_notification_enabled) AS gap_notification,
    AVG(fee_collected_int) FILTER (WHERE has_failed_spend)
  - AVG(fee_collected_int) FILTER (WHERE NOT has_failed_spend) AS gap_failed_spend
FROM v_customers
WHERE is_activated;
-- Result: Based on the gap indicators, allowance, family login and failed spend matter most, while the rest are
-- less significant

-- Q12: Allowance + family login together?
SELECT * FROM agg_allowance_family_matrix;
-- Result: If both are true, the fee rate is 94%, and if none the fee rate drops below 50%

-- Q13: Which channels pay best and worst?
SELECT channel_name, n_activated, fee_rate_activated
FROM agg_segments
WHERE channel_name IS NOT NULL
ORDER BY fee_rate_activated DESC;
-- Result: best is referral and worst is tiktok

-- Q14: Do platform and subscription tier make a difference?
SELECT platform, subscription_tier, n_activated, fee_rate_activated, fee_rate_activated_ci
FROM agg_segments
WHERE platform IS NOT NULL OR subscription_tier IS NOT NULL
ORDER BY fee_rate_activated DESC;
-- Result: subscription tiers have about the same rate, platform makes a small difference but minimal and may be due to
-- margin of error. Follow-up: the 95% ranges for iOS and Web don't overlap and the regression confirms the gap,
-- so the platform difference is real (finding 12). 


-- MY FINDINGS (fill in as you go, one line each)
-- DATA
-- 1. Data is clean: 5,000 unique customers, all checks pass except 2 small known issues
--    (4 family-login rows, 8 users with 30 login days). Kept and flagged, they don't change results. (Q2, Q4, Q5)
-- 2. Activation is a gate: 764 users (15%) never activated and none of them paid.
--    So behaviours are analysed on activated users only, and activation is its own lever. (Q6)
-- 3. Funnel: 84.7% activate, 65% of activated users pay, 55% of all signups pay. (Q9)
--
-- Q1 OF THE BRIEF: BEHAVIOURS (gap = fee rate with the behaviour minus without it)
-- 4. Allowance is the strongest behaviour: 82% pay with one vs 55% without (+27pp). (Q10, Q11b)
-- 5. Family login is second: 81% vs 60% (+21pp). (Q11b)
-- 6. Together they stack: 94% pay with both vs 49% with neither. (Q12)
-- 7. Failed card payments are the main warning sign: 56% pay vs 67% without a decline (-11pp). (Q11b)
-- 8. Smaller positive gaps: savings goal +8pp, successful spend +8pp, custom card +6pp
--    (custom card is only 325 users, so weak evidence). (Q11b)
-- 9. Notifications make almost no difference (+2pp), so turning them on is not a lever. (Q11b)
-- 10. Ranking by the gap (Q11b) is better than ranking by fee rate (Q11): a high fee rate means
--     little if the "no" group pays almost as often.
--
-- Q2 OF THE BRIEF: SEGMENTS (activated users)
-- 11. Channel matters most: Referral 77% vs TikTok 54% (23pp gap). (Q13)
-- 12. Platform matters: iOS 68% (66-70%), Android 63%, Web 60% (56-64%).
--     The ranges don't overlap, so the iOS vs Web gap (8pp) is real, not margin of error. (Q14)
-- 13. Subscription tier makes no difference: Everyday, Plus and Max are all about 64-66%. (Q14)
