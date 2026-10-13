# Assumptions and Findings

Summary of the analysis so far. Details for each finding are in `sql/explore/explore.sql` (query numbers in brackets).

---

## Assumptions

| # | Assumption | Why | Status |
|---|---|---|---|
| A1 | Behaviours are analysed on **activated users only** (4,236 of 5,000) | Users who never activated show no engagement and none of them paid. Including them would make every behaviour look important just because it means "activated". | **Confirmed by the hiring team:** "this is the correct approach" |
| A2 | The first fee is attempted **at or after day 30**, so the 30-day behaviours happen **before** the fee | If the fee is taken earlier, some behaviours could be a reaction to it | It stays an assumption (state it in the deck) |
| A3 | We don't know **why** a fee failed (payment declined vs customer cancelled) | Recommendations should cover both | It stays an assumption (state it in the deck) |
| A4 | Results show **associations, not cause and effect** | Engaged parents tend to do everything, so we can't prove that one behaviour causes payment. Recommendations need an A/B test. | Stated in deck |
| A5 | The **4 family-login rows** that contradict the definition are kept and flagged | Removing them changes the family-login gap by only 0.02pp | **Confirmed by the hiring team:** a deliberately planted data-quality issue, which I found |
| A6 | The **8 users with 30 login days** are kept | The glossary may count day 30 as inclusive | **Confirmed by the hiring team:** expected; include with no special treatment |
| A7 | `allowance_amount` is used as the **total for all children** | The median is ~£24.5 whatever the number of children, which looked like per child | **Confirmed by the hiring team:** treat it as the sum for all children |
| A8 | All 2024 signups are analysed together | Only valid if fee rates don't trend across months | Confirmed: fee rate is flat across signup months (62–68%, within the margins of error; `agg_segments.csv`) |
| A9 | Margins of error are 95% ranges: `1.96 × √(p(1−p)/n)` | Standard method; the same formula is used in SQL and Tableau | — |
| A10 | The data is dummy data | The behaviours are almost unrelated to each other, which is unusual in real data | Mention as a caveat |

---

## Findings

### Data
1. **The data is clean.** 5,000 unique customers. All checks pass except one known issue: 4 family-login rows, a planted issue confirmed by the hiring team. They are kept, flagged, and don't change the results. The 8 users with 30 login days are expected (confirmed by the hiring team). *(Q2, Q4, Q5)*
2. **Activation is a gate.** 764 users (15%) never activated, and none of them paid. They are **34% of everyone who didn't pay**, so activation is a lever in its own right. *(Q6)*
3. **Funnel:** 84.7% activate → 65% of activated users pay → 55% of all signups pay. *(Q9)*

### Brief Q1: which behaviours matter? (activated users, gap = fee rate with minus without)
4. **Allowance is the strongest:** 82% vs 55% (**+27pp**). *(Q10, Q11b)*
   **The amount doesn't matter, only having one.** Customers with an allowance pay 80–85% at every amount (£0–10: 82%, £10–20: 81%, £20–30: 79%, £30+: 85%). There is no correlation between the amount and paying. So onboarding can pre-fill a small default amount; what matters is getting the allowance set up. *(outputs/agg_dose_response.csv, allowance_band)*
5. **Family login is second:** 81% vs 60% (**+21pp**). *(Q11b)*
6. **They stack:** 94% pay with both vs 49% with neither. *(Q12)*
7. **Failed card payments are the main warning sign:** 56% vs 67% (**−11pp**). *(Q11b)*
8. Smaller positive gaps: savings goal +8pp, successful spend +8pp, custom card +6pp. Only 325 users have a custom card, so that one is weak evidence. *(Q11b)*
9. **Notifications make almost no difference** (+2pp), so turning them on is not a lever. *(Q11b)*

### Brief Q2: segments (activated users)
10. **Channel matters most:** Referral 77% vs TikTok 54% (a 23pp gap). *(Q13)*
11. **Platform matters:** iOS 68% (66–70%), Android 63%, Web 60% (56–64%). The ranges don't overlap, so the iOS vs Web gap is real. *(Q14)*
12. **Subscription tier makes no difference:** Everyday, Plus and Max are all about 64–66%. *(Q14)*

### Python check: which findings can we trust?
Two tests per finding:
- **Real or luck?** p-value from the regression. Real = p below 0.05, i.e. less than a 5% chance the gap is luck. For segments, also whether the 95% ranges overlap. *(outputs/marginal_effects.csv, agg_segments.csv)*
- **Still matters when everything else is taken into account?** Logistic regression, which compares customers who are the same in everything else. *(outputs/marginal_effects.csv)*

| # | Finding (from SQL) | Real or luck? | After taking everything else into account | Verdict |
|---|---|---|---|---|
| 4 | Allowance +27pp | Real | +25pp | **Headline** |
| 4 | Allowance amount (among customers with one) | No correlation | — | Keep as "having one matters, not the amount" |
| 5 | Family login +21pp | Real | +20pp | **Headline** |
| 6 | Both together: 94% vs 49% | — | The two effects mostly just add up | Keep as a chart |
| 7 | Failed spend −11pp | Real | −12pp | **Key warning sign** |
| — | More login days → pays more often | Real | +5pp per extra 5 login days | Secondary |
| 8 | Savings goal +8pp | Real | +6pp | Secondary |
| 8 | Successful spend +8pp | Real | +8pp | Secondary |
| 8 | Custom card +6pp | Could be luck (p = 0.21) | +3pp, **could be luck** | **Drop** |
| 9 | Notifications +2pp | Luck | +1pp, could be luck | Keep as "not a lever" |
| 10 | Channel: Referral best, TikTok worst | Real | Still real: Referral +8pp, TikTok −14pp vs Organic | **Headline for Q2** |
| 11 | Platform: iOS > Android > Web | Real | Still real: Web −8pp, Android −5pp vs iOS | Keep |
| 12 | Tier makes no difference | No difference | No difference | Keep as "tier doesn't matter" |
| — | Signup month | No difference | — | Assumption A8 holds |

**Do the two habits interact?** Tested with a likelihood-ratio test: p = 0.05, borderline, so the effects are described as mostly adding up. *(outputs/model_metrics.csv)*

---

## Final findings for the slides
1. **Activation is the first gate:** 15% never activate and none of them pay. They are 34% of all non-payers.
2. **Allowance (+25pp) and family login (+20pp)** are the strongest behaviours. Together: 94% pay vs 49% with neither. For the allowance, having one matters, not the amount.
3. **Failed card payments are a warning sign** (−12pp).
4. **Notifications and custom cards don't make a real difference.** They aren't levers.
5. **Channel and platform matter even after taking behaviour into account:** Referral best, TikTok worst; Web lowest.
6. **Tier and signup month make no difference.**