"""Take-home case study: which early behaviours predict first fee collection?

Run from the project root:  .venv\\Scripts\\python.exe python\\analysis.py
Or cell by cell in VS Code (each "# %%" block is a cell).

Excel -> PostgreSQL -> sql/01, 02, 03 -> Python statistics -> outputs/*.csv -> Tableau
"""

# %% 0. Setup
import os
import re
from pathlib import Path

import numpy as np
import pandas as pd
import statsmodels.formula.api as smf
from scipy.stats import chi2
from sqlalchemy import URL, create_engine, text
from statsmodels.stats.power import NormalIndPower
from statsmodels.stats.proportion import proportion_effectsize

try:
    ROOT = Path(__file__).resolve().parents[1]
except NameError:  # interactive window: cwd is python/ or the project root
    ROOT = Path.cwd() if (Path.cwd() / "sql").exists() else Path.cwd().parent

RAW_XLSX = ROOT / "Data" / "raw" / "Data Analyst Take Home Task (1).xlsx"
SQL_DIR = ROOT / "sql"
OUT = ROOT / "outputs"
PROCESSED = ROOT / "Data" / "processed"
OUT.mkdir(exist_ok=True)
PROCESSED.mkdir(exist_ok=True)

SCHEMA = "fee_analysis"  # rebuilt from scratch on every run
ALPHA = 0.05

BEHAVIOURS = [
    "has_allowance",
    "has_savings_goal",
    "has_successful_spend",
    "has_failed_spend",
    "has_login",
    "has_family_login",
    "has_notification_enabled",
    "has_custom_card",
]

pd.set_option("display.width", 200)
pd.set_option("display.max_columns", 30)


def save(df: pd.DataFrame, name: str) -> None:
    # utf-8-sig so "£" also shows correctly in Excel
    df.to_csv(OUT / f"{name}.csv", index=False, encoding="utf-8-sig")


def header(title: str) -> None:
    print(f"\n{'=' * 80}\n{title}\n{'=' * 80}")


# %% 1. Load the workbook
header("1. Load")
sheets = pd.read_excel(RAW_XLSX, sheet_name=None)
customers_raw = sheets["customers"]
channel_raw = sheets["channel_lookup"]
glossary = sheets["glossary"]
print({name: sheet.shape for name, sheet in sheets.items()})

assert len(customers_raw) == 5000, f"Expected 5,000 customers, got {len(customers_raw)}"
assert set(customers_raw.columns) == set(glossary["field"]), "Columns and glossary do not match"


# %% 2. Load into PostgreSQL and run the validation checks (slide 3)
header("2. Data validation (sql/01_load_and_validate.sql)")
# Connection settings come from the standard PG* environment variables.
# Password: PGPASSWORD or %APPDATA%\postgresql\pgpass.conf (never hard-coded).
engine = create_engine(
    URL.create(
        "postgresql+psycopg",
        username=os.getenv("PGUSER", "postgres"),
        password=os.getenv("PGPASSWORD"),
        host=os.getenv("PGHOST", "localhost"),
        port=int(os.getenv("PGPORT", "5432")),
        database=os.getenv("PGDATABASE", "Interview"),
    ),
    connect_args={"options": f"-c search_path={SCHEMA}"},
)

with engine.begin() as conn:
    conn.execute(text(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE"))
    conn.execute(text(f"CREATE SCHEMA {SCHEMA}"))
customers_raw.to_sql("raw_customers", engine, schema=SCHEMA, index=False)
channel_raw.to_sql("raw_channel_lookup", engine, schema=SCHEMA, index=False)


def run_sql_file(name: str) -> None:
    conn = engine.raw_connection()
    try:
        with conn.cursor() as cur:
            cur.execute((SQL_DIR / name).read_text(encoding="utf-8"))
        conn.commit()
    finally:
        conn.close()


def sql_df(query: str) -> pd.DataFrame:
    return pd.read_sql(text(query), engine)  # NUMERIC values are converted to float


run_sql_file("01_load_and_validate.sql")

# dq_checks is one row with one column per check -> turn it into one row per check
dq = sql_df("SELECT * FROM dq_checks").T.reset_index()
dq.columns = ["check_name", "failing_rows"]
dq["failing_rows"] = dq["failing_rows"].astype(int)

KNOWN_ISSUES = {"family_login_without_parent_login": 4}  # planted issue (confirmed by the hiring team): kept and flagged
INFO_ONLY = {"activated_without_any_login", "login_count_equals_30"}  # 30 login days: expected (confirmed by the hiring team)
dq["severity"] = np.select(
    [dq["check_name"].isin(list(KNOWN_ISSUES)), dq["check_name"].isin(list(INFO_ONLY))],
    ["known_issue", "info"],
    default="blocking",
)
save(dq, "validation_log")
save(sql_df("SELECT * FROM dq_amount_profile"), "dq_amount_profile")
save(sql_df("SELECT * FROM dq_allowance_by_children"), "dq_allowance_by_children")
print(dq.to_string(index=False))

blocking = dq[(dq["severity"] == "blocking") & (dq["failing_rows"] > 0)]
assert blocking.empty, f"Blocking data-quality checks failed:\n{blocking}"
for check, expected in KNOWN_ISSUES.items():
    actual = int(dq.loc[dq["check_name"] == check, "failing_rows"].iloc[0])
    assert actual == expected, f"{check}: expected {expected} rows, found {actual}"
print("\nAll blocking checks passed. Known issues match the documented counts.")


# %% 3. Build the analysis view and aggregates, export for Tableau
header("3. Analysis view and aggregates (sql/02, sql/03)")
run_sql_file("02_analytical_view.sql")
run_sql_file("03_aggregates.sql")

df = sql_df("SELECT * FROM v_customers ORDER BY user_id")
assert len(df) == len(customers_raw), "The channel join changed the row count"
assert df["channel_name"].notna().all(), "Some customers have no channel name after the join"
df.to_csv(PROCESSED / "customers_clean.csv", index=False, encoding="utf-8-sig")  # main Tableau source

AGG_VIEWS = [
    "agg_funnel",
    "agg_behaviour_lift",
    "agg_dose_response",
    "agg_behaviour_count",
    "agg_allowance_family_matrix",
    "agg_segments",
    "agg_segment_by_allowance",
]
agg = {view: sql_df(f"SELECT * FROM {view}") for view in AGG_VIEWS}
for view, table in agg.items():
    save(table, view)
print(f"Exported customers_clean.csv ({len(df):,} rows) and {len(AGG_VIEWS)} aggregate tables.")


# %% 4. Funnel, SQL <-> pandas reconciliation and the data-quality sensitivity check 
header("4. Funnel and population")
n_signups = len(df)
n_activated = int(df["is_activated"].sum())
n_paid = int(df["fee_collected_m1"].sum())
activation_rate = n_activated / n_signups
fee_rate_all = n_paid / n_signups
act = df[df["is_activated"]].copy()  # population for all behaviour analysis
fee_rate_activated = act["fee_collected_m1"].mean()
never_activated_share = (n_signups - n_activated) / (n_signups - n_paid)

# Activation gate: no activated card = no fee
assert df.loc[~df["is_activated"], "fee_collected_m1"].sum() == 0

print(f"Signups:        {n_signups:,}")
print(f"Activated:      {n_activated:,} ({activation_rate:.1%})")
print(f"Fee collected:  {n_paid:,} ({fee_rate_all:.1%} of signups, {fee_rate_activated:.1%} of activated)")
print(f"Non-payers who never activated: {n_signups - n_activated:,} ({never_activated_share:.1%})")


def assert_close(pandas_value: float, sql_value: float, label: str, tol: float = 1e-9) -> None:
    assert abs(pandas_value - sql_value) <= tol, f"{label}: pandas={pandas_value} sql={sql_value}"


funnel = agg["agg_funnel"].iloc[0]
assert_close(n_signups, funnel["signups"], "signups")
assert_close(n_activated, funnel["activated"], "activated")
assert_close(n_paid, funnel["fee_collected"], "fee collected")
assert_close(fee_rate_activated, funnel["fee_rate_activated"], "fee rate activated")

sql_lift = agg["agg_behaviour_lift"]
for b in BEHAVIOURS:
    for value in (True, False):
        sql_rate = sql_lift.loc[sql_lift[b] == value, "fee_rate"].item()
        assert_close(act.loc[act[b] == value, "fee_collected_m1"].mean(), sql_rate, f"{b}={value}")
print("Reconciliation passed: SQL matches pandas.")


def family_login_gap(data: pd.DataFrame) -> float:
    with_fl = data.loc[data["has_family_login"], "fee_collected_m1"].mean()
    without_fl = data.loc[~data["has_family_login"], "fee_collected_m1"].mean()
    return 100 * (with_fl - without_fl)


# Sensitivity: do the 4 planted DQ rows change the family-login result?
gap_all = family_login_gap(act)
gap_clean = family_login_gap(act[~act["dq_flag_family_login"]])
print(f"Family-login gap: {gap_all:.2f}pp with the 4 DQ rows, {gap_clean:.2f}pp without them")


# %% 5. Logistic regression on activated users (slides 4, 5 and 6)
header("5. Logistic regression: adjusted effects")
model_df = act.copy()
model_df["fee"] = model_df["fee_collected_m1"].astype(int)
for b in BEHAVIOURS:
    model_df[b] = model_df[b].astype(int)
# Logins as "per 5 days": the 0-login band (n=46) is too small to be a reference category.
# has_login is left out because login_count already contains it.
model_df["login_days_per5"] = model_df["login_count"] / 5

BEHAVIOUR_TERMS = [
    "has_allowance",
    "has_family_login",
    "login_days_per5",
    "has_failed_spend",
    "has_savings_goal",
    "has_successful_spend",
    "has_custom_card",
    "has_notification_enabled",
]
# Reference category = largest group
SEGMENT_TERMS = [
    "C(platform, Treatment('iOS'))",
    "C(subscription_tier, Treatment('Everyday'))",
    "C(channel_name, Treatment('Organic'))",
    "num_children",
]
FORMULA = "fee ~ " + " + ".join(BEHAVIOUR_TERMS + SEGMENT_TERMS)


def clean_term(term: str) -> str:
    """C(channel_name, Treatment('Organic'))[T.TikTok] -> channel_name: TikTok (vs Organic)"""
    match = re.match(r"C\((\w+), Treatment\('([^']+)'\)\)\[T\.(.+)\]", term)
    return f"{match[1]}: {match[3]} (vs {match[2]})" if match else term


logit = smf.logit(FORMULA, data=model_df).fit(disp=False)

# Average marginal effects = change in fee probability (pp). dummy=True: 0 -> 1 change for flags.
# Slide 4 bars = behaviour rows; grey = p_value >= 0.05. Slide 6 footnote = segment rows.
margeff = logit.get_margeff(at="overall", dummy=True)
ame = margeff.summary_frame()
ame.columns = ["effect", "std_err", "z", "p_value", "ci_low", "ci_high"]
ame = ame.reset_index(names="raw_term")
ame["term"] = ame["raw_term"].map(clean_term)
ame["group"] = np.where(ame["raw_term"].isin(BEHAVIOUR_TERMS), "behaviour", "segment")
for col in ["effect", "ci_low", "ci_high"]:
    ame[f"{col}_pp"] = 100 * ame[col]
ame = ame.sort_values("effect", ascending=False)
save(ame[["term", "group", "effect_pp", "ci_low_pp", "ci_high_pp", "p_value", "raw_term"]], "marginal_effects")

print(f"n = {int(logit.nobs):,}, pseudo R^2 (McFadden) = {logit.prsquared:.3f}")
print(ame[["term", "effect_pp", "ci_low_pp", "ci_high_pp", "p_value"]].round(3).to_string(index=False))

# Slide 5 likelihood-ratio test of an allowance x family login interaction
interaction = smf.logit(FORMULA + " + has_allowance:has_family_login", data=model_df).fit(disp=False)
lr_stat = 2 * (interaction.llf - logit.llf)
interaction_p = chi2.sf(lr_stat, df=1)
print(f"\nInteraction allowance x family login: LR = {lr_stat:.2f}, p = {interaction_p:.3f}")

save(pd.DataFrame([
    ("logit_n", logit.nobs),
    ("logit_pseudo_r2_mcfadden", logit.prsquared),
    ("interaction_lr_p_value", interaction_p),
], columns=["metric", "value"]), "model_metrics")

with open(OUT / "regression_summary.txt", "w", encoding="utf-8") as f:
    f.write(f"Formula: {FORMULA}\nPopulation: activated users (n={int(logit.nobs)})\n\n")
    f.write(str(logit.summary()))
    f.write("\n\nAverage marginal effects\n")
    f.write(str(margeff.summary()))


# %% 6. Opportunity sizing
header("6. Opportunity sizing")
# Effects are associations, so assume only part of each adjusted effect is causal.
ame_by_term = ame.set_index("raw_term")["effect"]
allowance_effect = ame_by_term["has_allowance"]
failed_effect = abs(ame_by_term["has_failed_spend"])
failed_share = act["has_failed_spend"].mean()

sizing_rows = []
for scenario, act_uplift, new_user_factor in [("low", 0.02, 0.75), ("central", 0.03, 0.9), ("high", 0.05, 1.0)]:
    # newly activated users assumed to pay at a discount to today's rate
    impact = act_uplift * fee_rate_activated * new_user_factor
    sizing_rows.append({"lever": "R1 activation nudges", "scenario": scenario,
                        "assumption": f"+{100 * act_uplift:.0f}pp activation; new activators pay at {new_user_factor:.0%} of today's rate",
                        "impact_pp_all_signups": 100 * impact})
for scenario, uptake_uplift, causal_share in [("low", 0.05, 0.25), ("central", 0.10, 0.5), ("high", 0.15, 0.75)]:
    impact = activation_rate * uptake_uplift * allowance_effect * causal_share
    sizing_rows.append({"lever": "R2 allowance in onboarding", "scenario": scenario,
                        "assumption": f"+{100 * uptake_uplift:.0f}pp allowance uptake; {causal_share:.0%} of adjusted effect causal",
                        "impact_pp_all_signups": 100 * impact})
for scenario, reduction, causal_share in [("low", 0.20, 0.25), ("central", 0.35, 0.5), ("high", 0.50, 0.75)]:
    impact = activation_rate * failed_share * reduction * failed_effect * causal_share
    sizing_rows.append({"lever": "R3 fewer failed card payments", "scenario": scenario,
                        "assumption": f"{reduction:.0%} fewer users with a decline; {causal_share:.0%} of adjusted effect causal",
                        "impact_pp_all_signups": 100 * impact})
sizing = pd.DataFrame(sizing_rows)
sizing["extra_payers_per_10k_signups"] = (sizing["impact_pp_all_signups"] * 100).round()
save(sizing, "opportunity_sizing")
print(f"Inputs: activation {activation_rate:.1%}, fee|activated {fee_rate_activated:.1%}, "
      f"allowance AME {100 * allowance_effect:.1f}pp, failed-spend AME {-100 * failed_effect:.1f}pp, "
      f"share with a decline {failed_share:.1%}")
print(sizing.round(2).to_string(index=False))


# %% 7. A/B test sample size
header("7. Power calculation (two-sided, alpha 5%, power 80%)")
power_rows = []
for mde in [0.02, 0.03, 0.05]:
    effect = proportion_effectsize(fee_rate_all + mde, fee_rate_all)  # Cohen's h
    n_per_arm = NormalIndPower().solve_power(effect_size=abs(effect), alpha=ALPHA, power=0.8, ratio=1)
    power_rows.append({"baseline": fee_rate_all, "mde_pp": 100 * mde,
                       "users_per_arm": int(np.ceil(n_per_arm)),
                       "total_users": 2 * int(np.ceil(n_per_arm))})
power = pd.DataFrame(power_rows)
save(power, "power_calc")
print(power.round(4).to_string(index=False))


# %% 8. Key numbers for the deck (number -> source file)
header("8. Key numbers")
matrix = agg["agg_allowance_family_matrix"].set_index(["has_allowance", "has_family_login"])
channels = agg["agg_segments"].dropna(subset=["channel_name"]).set_index("channel_name")["fee_rate_activated"]
platforms = agg["agg_segments"].dropna(subset=["platform"]).set_index("platform")["fee_rate_activated"]
central = sizing[sizing["scenario"] == "central"].set_index("lever")["impact_pp_all_signups"]
key_numbers = pd.DataFrame([
    ("slide 3", "activation_rate", activation_rate, "agg_funnel.csv"),
    ("slide 3", "fee_rate_activated", fee_rate_activated, "agg_funnel.csv"),
    ("slide 3", "fee_rate_all_signups", fee_rate_all, "agg_funnel.csv"),
    ("slide 3", "share_of_non_payers_never_activated", never_activated_share, "agg_funnel.csv"),
    ("slide 4", "allowance_effect_pp", 100 * allowance_effect, "marginal_effects.csv"),
    ("slide 4", "family_login_effect_pp", 100 * ame_by_term["has_family_login"], "marginal_effects.csv"),
    ("slide 4", "failed_spend_effect_pp", -100 * failed_effect, "marginal_effects.csv"),
    ("slide 5", "fee_rate_allowance_and_family_login", matrix.loc[(True, True), "fee_rate"], "agg_allowance_family_matrix.csv"),
    ("slide 5", "fee_rate_neither", matrix.loc[(False, False), "fee_rate"], "agg_allowance_family_matrix.csv"),
    ("slide 6", "fee_rate_referral", channels["Referral"], "agg_segments.csv"),
    ("slide 6", "fee_rate_tiktok", channels["TikTok"], "agg_segments.csv"),
    ("slide 6", "fee_rate_ios", platforms["iOS"], "agg_segments.csv"),
    ("slide 6", "fee_rate_web", platforms["Web"], "agg_segments.csv"),
    ("slide 7", "activation_nudges_central_pp", central["R1 activation nudges"], "opportunity_sizing.csv"),
    ("slide 7", "allowance_onboarding_central_pp", central["R2 allowance in onboarding"], "opportunity_sizing.csv"),
    ("slide 7", "failed_payments_central_pp", central["R3 fewer failed card payments"], "opportunity_sizing.csv"),
    ("slide 8", "users_per_group_for_3pp", power.loc[power["mde_pp"] == 3, "users_per_arm"].item(), "power_calc.csv"),
], columns=["slide", "metric", "value", "source"])
save(key_numbers, "key_numbers")
print(key_numbers.round(4).to_string(index=False))

engine.dispose()  # close the database connections
print(f"\nDone. Outputs in {OUT}")
