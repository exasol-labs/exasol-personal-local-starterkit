"""How good is the descriptor's first draft? Each column's drafted role, the drafted slots and the sensitive marks,
scored against a reviewer's answer for twenty tables: the fifteen of the kit's datasets (their CSVs, profiled here with
profile_rows - the numbers profile() reads from the database) and five synthetic tables shaped like common data
(customers, order items, sensor readings, employees, loans), built with a fixed seed.

    python3 tools/descriptor_benchmark.py              # the report: scores, then every miss
    python3 tools/descriptor_benchmark.py --json       # the same as one object
    python3 tools/descriptor_benchmark.py --check      # exit 1 when a score falls under its floor (tests/ runs this)

GOLD names, per column, the role a reviewer would approve; a tuple lists the roles that are all right, the first
preferred (a two-valued text column is a flag or a category). Slots the same way, None meaning "left empty". A score
counts a role or slot right when it is one of the answers. Confidence is scored too: a draft is only as good as its
"low" marks, since a reviewer reads those first - "caught" is the share of wrong roles marked low.

The synthetic tables were written before the rules they test were changed, and are the check that a rule was not
fitted to the kit's own datasets.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import random
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "setup" / "lib"), str(ROOT / "tools")]
import descriptor_draft  # noqa: E402  (the shipped descriptors' own reading of 01_create_schema.sql)
from descriptor import draft as drafting  # noqa: E402
from descriptor import profile as profiling  # noqa: E402

DATASETS = ROOT / "data" / "datasets"
FLOORS = {"roles": 0.95, "slots": 0.90, "sensitive_recall": 1.0, "sensitive_precision": 1.0, "caught": 0.75}

# --- the reviewer's answers ------------------------------------------------------------------------------------------
GOLD: dict[str, dict[str, Any]] = {
    "AMAZON.ORDER_LINES": {
        "roles": {"ORDER_LINE_ID": "key", "ORDER_ID": "identifier", "ORDER_DATE": "time", "STATUS": "category",
                  "FULFILMENT": ("flag", "category"), "SALES_CHANNEL": ("flag", "category"),
                  "SHIP_SERVICE_LEVEL": ("flag", "category"), "STYLE_CODE": ("identifier", "category"),
                  "SKU": "identifier", "CATEGORY": "category", "SIZE": "category", "ASIN": "identifier",
                  "COURIER_STATUS": "category", "QTY": "measure", "CURRENCY": "other", "AMOUNT": "measure",
                  "SHIP_CITY": "category", "SHIP_STATE": "category", "SHIP_POSTAL_CODE": "identifier",
                  "SHIP_COUNTRY": "other", "HAS_PROMOTION": "flag", "IS_B2B": "flag",
                  "FULFILLED_BY": ("flag", "other"), "CANCELLED": "flag"},
        "slots": {"key": "ORDER_LINE_ID", "time": "ORDER_DATE", "text": None, "category": "CATEGORY",
                  "entity": ("SHIP_STATE", "SHIP_CITY")},
        "sensitive": ["SHIP_POSTAL_CODE"]},
    "WALMART.WEEKLY_SALES": {
        "roles": {"SALES_ID": "key", "STORE": ("category", "identifier"), "WEEK_DATE": "time", "WEEKLY_SALES": "measure",
                  "HOLIDAY_WEEK": "flag", "TEMPERATURE_F": "measure", "FUEL_PRICE": "measure", "CPI": "measure",
                  "UNEMPLOYMENT": "measure", "ABOVE_STORE_MEDIAN": "flag"},
        "slots": {"key": "SALES_ID", "time": "WEEK_DATE", "text": None, "category": ("STORE", None),
                  "entity": (None, "STORE")}},
    "FRAUD.TRANSACTIONS": {
        "roles": {"ROW_ID": "key", "TRANSACTION_ID": "identifier", "USER_ID": "identifier",
                  "TRANSACTION_AMOUNT": "measure", "TRANSACTION_TYPE": "category",
                  "TRANSACTION_HOUR": ("category", "measure"), "DEVICE_USED": "category", "LOCATION": "category",
                  "PREVIOUS_FRAUDULENT_TRANSACTIONS": ("measure", "category"), "ACCOUNT_AGE": "measure",
                  "TRANSACTIONS_LAST_24H": ("measure", "category"), "PAYMENT_METHOD": "category", "FRAUDULENT": "flag"},
        "slots": {"key": "ROW_ID", "time": None, "text": None,
                  "category": ("TRANSACTION_TYPE", "PAYMENT_METHOD", "DEVICE_USED"), "entity": ("LOCATION", None)}},
    "TPCH.REGION": {
        "roles": {"R_REGIONKEY": "key", "R_NAME": ("category", "identifier"), "R_COMMENT": "text"},
        "slots": {"key": "R_REGIONKEY", "time": None, "text": "R_COMMENT", "category": ("R_NAME", None), "entity": None}},
    "TPCH.NATION": {
        "roles": {"N_NATIONKEY": "key", "N_NAME": ("category", "identifier"), "N_REGIONKEY": ("identifier", "category"),
                  "N_COMMENT": "text"},
        "slots": {"key": "N_NATIONKEY", "time": None, "text": "N_COMMENT", "category": None, "entity": ("N_NAME", None)}},
    "TPCH.CUSTOMER": {
        "roles": {"C_CUSTKEY": "key", "C_NAME": ("identifier", "key"), "C_ADDRESS": ("identifier", "other", "text"),
                  "C_NATIONKEY": ("identifier", "category"), "C_PHONE": "identifier", "C_ACCTBAL": "measure",
                  "C_MKTSEGMENT": "category", "C_COMMENT": "text"},
        "slots": {"key": "C_CUSTKEY", "time": None, "text": "C_COMMENT", "category": "C_MKTSEGMENT", "entity": None},
        "sensitive": ["C_ADDRESS", "C_PHONE"]},
    "TPCH.SUPPLIER": {
        "roles": {"S_SUPPKEY": "key", "S_NAME": ("identifier", "key"), "S_ADDRESS": ("identifier", "other", "text"),
                  "S_NATIONKEY": ("identifier", "category"), "S_PHONE": "identifier", "S_ACCTBAL": "measure",
                  "S_COMMENT": "text"},
        "slots": {"key": "S_SUPPKEY", "time": None, "text": "S_COMMENT", "category": None, "entity": None},
        "sensitive": ["S_ADDRESS", "S_PHONE"]},
    "TPCH.PART": {
        "roles": {"P_PARTKEY": "key", "P_NAME": ("identifier", "text", "other"), "P_MFGR": "category",
                  "P_BRAND": "category", "P_TYPE": "category", "P_SIZE": ("measure", "category"),
                  "P_CONTAINER": "category", "P_RETAILPRICE": "measure", "P_COMMENT": ("text", "other")},
        "slots": {"key": "P_PARTKEY", "time": None, "text": ("P_COMMENT", None), "category": ("P_MFGR", "P_BRAND"),
                  "entity": ("P_BRAND", "P_TYPE", "P_CONTAINER", None)}},
    "TPCH.PARTSUPP": {
        "roles": {"PS_PARTKEY": "identifier", "PS_SUPPKEY": "identifier", "PS_AVAILQTY": "measure",
                  "PS_SUPPLYCOST": "measure", "PS_COMMENT": "text"},
        "slots": {"key": None, "time": None, "text": "PS_COMMENT", "category": None, "entity": None}},
    "TPCH.ORDERS": {
        "roles": {"O_ORDERKEY": "key", "O_CUSTKEY": "identifier", "O_ORDERSTATUS": "category",
                  "O_TOTALPRICE": "measure", "O_ORDERDATE": "time", "O_ORDERPRIORITY": "category",
                  "O_CLERK": ("identifier", "category"), "O_SHIPPRIORITY": "other", "O_COMMENT": "text"},
        "slots": {"key": "O_ORDERKEY", "time": "O_ORDERDATE", "text": "O_COMMENT",
                  "category": ("O_ORDERPRIORITY", "O_ORDERSTATUS"), "entity": ("O_CLERK", None)}},
    "TPCH.LINEITEM": {
        "roles": {"L_ORDERKEY": "identifier", "L_PARTKEY": "identifier", "L_SUPPKEY": "identifier",
                  "L_LINENUMBER": ("category", "identifier", "measure"), "L_QUANTITY": "measure",
                  "L_EXTENDEDPRICE": "measure", "L_DISCOUNT": "measure", "L_TAX": "measure",
                  "L_RETURNFLAG": "category", "L_LINESTATUS": ("flag", "category"), "L_SHIPDATE": "time",
                  "L_COMMITDATE": "time", "L_RECEIPTDATE": "time", "L_SHIPINSTRUCT": "category",
                  "L_SHIPMODE": "category", "L_COMMENT": ("text", "other")},
        "slots": {"key": None, "time": "L_SHIPDATE", "text": ("L_COMMENT", None),
                  "category": ("L_SHIPMODE", "L_RETURNFLAG", "L_SHIPINSTRUCT"), "entity": None}},
    "ENERGY.ENERGY_METERS": {
        "roles": {"METER_ID": "key", "HOUSEHOLD": ("identifier", "key"), "CITY": "category", "TARIFF": "category",
                  "BASE_LOAD_KWH": "measure"},
        "slots": {"key": "METER_ID", "time": None, "text": None, "category": ("TARIFF", "CITY"), "entity": None}},
    "WEATHER.WEATHER_CITIES": {
        "roles": {"CITY_ID": "key", "CITY": ("category", "identifier"), "COUNTRY": "category"},
        "slots": {"key": "CITY_ID", "time": None, "text": None, "category": ("COUNTRY", "CITY", None), "entity": None}},
    "WEATHER.WEATHER_DAILY": {
        "roles": {"CITY_ID": ("identifier", "category"), "W_DATE": "time", "TEMP_AVG_C": "measure",
                  "TEMP_MIN_C": "measure", "TEMP_MAX_C": "measure", "PRECIP_MM": "measure", "WIND_KMH": "measure"},
        "slots": {"key": None, "time": "W_DATE", "text": None, "category": None, "entity": None}},
    # --- synthetic, below: shapes the kit's datasets do not have ---
    "CRM.CUSTOMERS": {
        "roles": {"CUSTOMER_ID": "key", "FULL_NAME": ("identifier", "other"), "EMAIL": "identifier",
                  "PHONE": "identifier", "SIGNUP_DATE": "time", "BIRTH_YEAR": ("measure", "time"), "COUNTRY": "category",
                  "CITY": "category", "SEGMENT": "category", "IS_ACTIVE": "flag", "LIFETIME_VALUE": "measure",
                  "LOYALTY_POINTS": "measure", "ZIP_CODE": "identifier", "NOTES": "text"},
        "slots": {"key": "CUSTOMER_ID", "time": "SIGNUP_DATE", "text": "NOTES", "category": "SEGMENT",
                  "entity": ("CITY", "COUNTRY")},
        "sensitive": ["FULL_NAME", "EMAIL", "PHONE", "ZIP_CODE"]},
    "SHOP.ORDER_ITEMS": {
        "roles": {"ORDER_ITEM_ID": "key", "ORDER_NO": "identifier", "PRODUCT_SKU": "identifier", "QUANTITY": "measure",
                  "UNIT_PRICE": "measure", "DISCOUNT_PCT": ("measure", "category"), "STATUS": "category",
                  "CREATED_AT": "time", "SHIPPED_AT": "time", "RATING": ("category", "measure"), "REVIEW_TEXT": "text",
                  "CURRENCY": "other", "GIFT_WRAP": "flag"},
        "slots": {"key": "ORDER_ITEM_ID", "time": "CREATED_AT", "text": "REVIEW_TEXT", "category": "STATUS",
                  "entity": None}},
    "IOT.SENSOR_READINGS": {
        "roles": {"READING_ID": "key", "DEVICE_ID": ("identifier", "category"), "EPOCH_TS": "time",
                  "TEMPERATURE": "measure", "HUMIDITY": "measure", "BATTERY_PCT": "measure",
                  "STATUS_CODE": "category", "FIRMWARE": "category", "LATITUDE": ("measure", "other"),
                  "LONGITUDE": ("measure", "other")},
        "slots": {"key": "READING_ID", "time": ("EPOCH_TS", None), "text": None, "category": "FIRMWARE",
                  "entity": ("DEVICE_ID", None)}},
    "HR.EMPLOYEES": {
        "roles": {"EMP_NO": "key", "DEPARTMENT": "category", "JOB_TITLE": "category", "HIRE_DATE": "time",
                  "SALARY": "measure", "MANAGER_ID": "identifier", "YEARS_OF_SERVICE": "measure", "REMOTE": "flag",
                  "PERFORMANCE_SCORE": "measure", "IBAN": "identifier"},
        "slots": {"key": "EMP_NO", "time": "HIRE_DATE", "text": None, "category": "DEPARTMENT",
                  "entity": ("JOB_TITLE", None)},
        "sensitive": ["IBAN"]},
    "FIN.LOANS": {
        "roles": {"LOAN_ID": "key", "AMOUNT_REQUESTED": "measure", "TERM_MONTHS": ("flag", "category", "measure"),
                  "INTEREST_RATE": "measure", "GRADE": "category", "EMP_LENGTH": "category",
                  "HOME_OWNERSHIP": "category", "ANNUAL_INCOME": "measure", "PURPOSE": "category",
                  "ADDR_STATE": "category", "DTI": "measure", "DEFAULTED": "flag", "ISSUE_MONTH": ("category", "time")},
        "slots": {"key": "LOAN_ID", "time": (None, "ISSUE_MONTH"), "text": None, "category": ("GRADE", "HOME_OWNERSHIP", "PURPOSE"),
                  "entity": ("ADDR_STATE", None)}},
}

# Held out: written after the rules above were changed, labelled before the first run, and never tuned to. Their first
# score is the honest one (HELD_OUT_FIRST, below).
HELD_OUT: dict[str, dict[str, Any]] = {
    "MKT.CAMPAIGN_EVENTS": {
        "roles": {"eventId": "key", "campaignName": "category", "channel": "category", "sentAt": "time",
                  "opened": "flag", "clicked": "flag", "revenueEur": "measure", "userAgent": ("category", "other"),
                  "countryCode": "category", "sessionSeconds": "measure", "utmSource": "category"},
        "slots": {"key": "eventId", "time": "sentAt", "text": None, "category": ("channel", "utmSource", "campaignName"),
                  "entity": (None, "countryCode")}},
    "LOGISTICS.SHIPMENTS": {
        "roles": {"SHIPMENT_REF": "key", "ORIGIN_WAREHOUSE": "category", "DEST_POSTCODE": "identifier",
                  "CARRIER": "category", "WEIGHT_KG": "measure", "PARCELS": ("measure", "category"),
                  "DISPATCHED_ON": "time", "DELIVERED_ON": "time", "ON_TIME": "flag",
                  "DRIVER_NAME": ("identifier", "category"), "COMMENTS": "text"},
        "slots": {"key": "SHIPMENT_REF", "time": "DISPATCHED_ON", "text": "COMMENTS",
                  "category": ("CARRIER", "ORIGIN_WAREHOUSE"), "entity": (None, "DRIVER_NAME")},
        "sensitive": ["DEST_POSTCODE", "DRIVER_NAME"]},
    "CLINIC.VISITS": {
        "roles": {"VISIT_NO": "key", "PATIENT_ID": "identifier", "VISIT_DATE": "time",
                  "DIAGNOSIS_CODE": ("category", "identifier"), "SYSTOLIC_BP": "measure", "HEART_RATE": "measure",
                  "SMOKER": "flag", "BMI": "measure", "DOCTOR": "category", "NOTES": "text", "PATIENT_EMAIL": "identifier"},
        "slots": {"key": "VISIT_NO", "time": "VISIT_DATE", "text": "NOTES", "category": ("DOCTOR", None),
                  "entity": (None, "DIAGNOSIS_CODE")},
        "sensitive": ["PATIENT_EMAIL"]},
    "RETAIL.STORES_DAILY": {
        "roles": {"STORE_NR": ("identifier", "category"), "BUSINESS_DAY": "time", "FOOTFALL": "measure",
                  "TURNOVER": "measure", "OPEN_HOURS": "measure", "WEATHER": "category", "PROMO_ACTIVE": "flag",
                  "REGION": "category", "MANAGER": ("category", "identifier"), "CURRENCY_CODE": "other"},
        "slots": {"key": None, "time": "BUSINESS_DAY", "text": None, "category": ("REGION", "WEATHER", "MANAGER"),
                  "entity": None}},
    "SAAS.SUBSCRIPTIONS": {
        "roles": {"subscription_uuid": "key", "account_id": "identifier", "plan": "category", "seats": "measure",
                  "mrr_usd": "measure", "started": "time", "cancelled_at": "time", "churned": "flag",
                  "billing_country": "category", "referral_code": "identifier", "nps": ("category", "measure")},
        "slots": {"key": "subscription_uuid", "time": "started", "text": None, "category": "plan",
                  "entity": ("billing_country", None)}},
}
HELD_OUT_FIRST = {"roles": 0.981, "slots": 1.0, "sensitive_recall": 0.667, "sensitive_precision": 1.0, "caught": 0.0,
                  "high_right": 0.979, "missed": ["SAAS.SUBSCRIPTIONS.account_id: measure, high (acCOUNT read as count)",
                                                  "LOGISTICS.SHIPMENTS.DRIVER_NAME: not marked sensitive"]}


# --- the kit's datasets, from their CSVs -----------------------------------------------------------------------------
def kit_tables() -> dict[str, tuple[list[tuple[str, str]], list[list[str]]]]:
    found = {}
    for folder in sorted(p for p in DATASETS.iterdir() if (p / "01_create_schema.sql").is_file()):
        schema, tables = descriptor_draft.tables((folder / "01_create_schema.sql").read_text(encoding="utf-8"))
        for table, columns in tables.items():
            path = folder / "data" / f"{table.lower()}.csv"
            if not path.is_file():
                continue                                   # generated in SQL (energy readings): no file to read
            with path.open(newline="", encoding="utf-8") as handle:
                rows = list(csv.reader(handle))[1:]
            found[f"{schema}.{table}"] = (columns, rows)
    return found


# --- synthetic tables ------------------------------------------------------------------------------------------------
FIRST = ["Anna", "Ben", "Chen", "Dara", "Elif", "Farid", "Grace", "Hugo", "Ines", "Jon", "Kira", "Luca", "Mona", "Nils"]
LAST = ["Meyer", "Okafor", "Silva", "Novak", "Haddad", "Larsen", "Rossi", "Kim", "Dubois", "Schmidt", "Ito", "Brown"]
WORDS = ("delivery was late again and the box arrived damaged, support was friendly but slow to answer my request "
         "great fit and the colour matches the photos exactly would order from this shop again next season").split()


def _sentence(rng: random.Random, low: int, high: int) -> str:
    return " ".join(rng.choice(WORDS) for _ in range(rng.randint(low, high))).capitalize() + "."


def synthetic_tables() -> dict[str, tuple[list[tuple[str, str]], list[list[Any]]]]:
    rng = random.Random(20261106)
    tables = {}
    cities = [f"{c}" for c in ("Berlin", "Hamburg", "Munich", "Cologne", "Paris", "Lyon", "Madrid", "Rome", "Milan",
                                "Vienna", "Zurich", "Oslo", "Lisbon", "Porto", "Prague", "Warsaw", "Dublin", "Cork")]
    cities += [f"Town {i}" for i in range(130)]
    countries = ["DE", "FR", "ES", "IT", "AT", "CH", "NO", "PT", "CZ", "PL", "IE", "NL"]
    rows = []
    for i in range(1, 2001):
        first, last = rng.choice(FIRST), rng.choice(LAST)
        rows.append([i, f"{first} {last}", f"{first.lower()}.{last.lower()}{i}@example.com",
                     f"+49 30 {rng.randint(1000000, 9999999)}",
                     (dt.date(2019, 1, 1) + dt.timedelta(days=rng.randint(0, 1800))).isoformat(),
                     rng.randint(1945, 2005), rng.choice(countries), rng.choice(cities),
                     rng.choice(["consumer", "small business", "enterprise", "public sector"]), rng.choice("YN"),
                     f"{rng.uniform(0, 25000):.2f}", rng.randint(0, 5000), f"{rng.randint(10000, 99999)}",
                     _sentence(rng, 8, 20) if rng.random() < 0.3 else ""])
    tables["CRM.CUSTOMERS"] = ([("CUSTOMER_ID", "DECIMAL(9,0)"), ("FULL_NAME", "VARCHAR(60)"), ("EMAIL", "VARCHAR(80)"),
                                ("PHONE", "VARCHAR(20)"), ("SIGNUP_DATE", "VARCHAR(10)"), ("BIRTH_YEAR", "DECIMAL(4,0)"),
                                ("COUNTRY", "VARCHAR(2)"), ("CITY", "VARCHAR(40)"), ("SEGMENT", "VARCHAR(20)"),
                                ("IS_ACTIVE", "CHAR(1)"), ("LIFETIME_VALUE", "DECIMAL(10,2)"),
                                ("LOYALTY_POINTS", "DECIMAL(6,0)"), ("ZIP_CODE", "VARCHAR(5)"), ("NOTES", "VARCHAR(400)")], rows)
    rows = []
    start = dt.datetime(2024, 1, 1)
    for i in range(1, 5001):
        created = start + dt.timedelta(minutes=rng.randint(0, 500000))
        shipped = created + dt.timedelta(hours=rng.randint(4, 96)) if rng.random() < 0.8 else None
        rated = rng.random() < 0.4
        rows.append([f"OI-{i:06d}", rng.randint(100000, 101500), f"SKU-{rng.randint(10000, 10400)}", rng.randint(1, 12),
                     f"{rng.uniform(2, 300):.2f}", rng.choice([0, 0, 0, 5, 10, 15, 20]),
                     rng.choice(["placed", "paid", "shipped", "delivered", "returned"]),
                     created.isoformat(sep=" "), shipped.isoformat(sep=" ") if shipped else "",
                     rng.randint(1, 5) if rated else "", _sentence(rng, 10, 30) if rated and rng.random() < 0.7 else "",
                     "EUR", rng.choice(["TRUE", "FALSE"])])
    tables["SHOP.ORDER_ITEMS"] = ([("ORDER_ITEM_ID", "VARCHAR(12)"), ("ORDER_NO", "DECIMAL(9,0)"),
                                   ("PRODUCT_SKU", "VARCHAR(12)"), ("QUANTITY", "DECIMAL(3,0)"),
                                   ("UNIT_PRICE", "DECIMAL(8,2)"), ("DISCOUNT_PCT", "DECIMAL(3,0)"),
                                   ("STATUS", "VARCHAR(12)"), ("CREATED_AT", "TIMESTAMP"), ("SHIPPED_AT", "TIMESTAMP"),
                                   ("RATING", "DECIMAL(1,0)"), ("REVIEW_TEXT", "VARCHAR(500)"), ("CURRENCY", "CHAR(3)"),
                                   ("GIFT_WRAP", "BOOLEAN")], rows)
    rows = []
    epoch = int(dt.datetime(2025, 3, 1, tzinfo=dt.timezone.utc).timestamp())
    for i in range(1, 5001):
        rows.append([i, f"dev-{rng.randint(1, 50):04d}", epoch + i * 60 + rng.randint(0, 59),
                     f"{rng.gauss(21, 3):.3f}", rng.randint(20, 90), rng.randint(0, 100), rng.choice([200, 200, 200, 400, 500]),
                     rng.choice(["1.2.0", "1.2.1", "1.3.0", "1.3.2", "2.0.0", "2.0.1"]),
                     f"{rng.uniform(47.0, 55.0):.6f}", f"{rng.uniform(6.0, 15.0):.6f}"])
    tables["IOT.SENSOR_READINGS"] = ([("READING_ID", "DECIMAL(18,0)"), ("DEVICE_ID", "VARCHAR(10)"),
                                      ("EPOCH_TS", "DECIMAL(12,0)"), ("TEMPERATURE", "DOUBLE"), ("HUMIDITY", "DECIMAL(3,0)"),
                                      ("BATTERY_PCT", "DECIMAL(3,0)"), ("STATUS_CODE", "DECIMAL(3,0)"),
                                      ("FIRMWARE", "VARCHAR(8)"), ("LATITUDE", "DOUBLE"), ("LONGITUDE", "DOUBLE")], rows)
    rows = []
    titles = [f"{level} {area}" for level in ("Junior", "Senior", "Lead", "Principal", "Staff")
              for area in ("Engineer", "Analyst", "Designer", "Accountant", "Recruiter", "Consultant", "Scientist",
                           "Manager", "Support Agent", "Sales Rep", "Writer", "Architect")]
    for i in range(1, 801):
        hired = dt.date(2005, 1, 1) + dt.timedelta(days=rng.randint(0, 7000))
        rows.append([f"E{i:05d}", rng.choice(["Engineering", "Finance", "Sales", "Marketing", "People", "Support"]),
                     rng.choice(titles), hired.strftime("%d.%m.%Y"), rng.randint(30000, 150000),
                     rng.randint(1, 60) if i > 60 else "", (dt.date(2026, 1, 1) - hired).days // 365,
                     rng.choice(["yes", "no"]), f"{rng.randint(10, 50) / 10:.1f}",
                     f"DE{rng.randint(10, 99)} {rng.randint(1000, 9999)} {rng.randint(1000, 9999)} {rng.randint(1000, 9999)} "
                     f"{rng.randint(1000, 9999)} {rng.randint(10, 99)}"])
    tables["HR.EMPLOYEES"] = ([("EMP_NO", "VARCHAR(6)"), ("DEPARTMENT", "VARCHAR(20)"), ("JOB_TITLE", "VARCHAR(30)"),
                               ("HIRE_DATE", "VARCHAR(10)"), ("SALARY", "DECIMAL(7,0)"), ("MANAGER_ID", "DECIMAL(6,0)"),
                               ("YEARS_OF_SERVICE", "DECIMAL(2,0)"), ("REMOTE", "VARCHAR(3)"),
                               ("PERFORMANCE_SCORE", "DECIMAL(2,1)"), ("IBAN", "VARCHAR(34)")], rows)
    rows = []
    states = ["AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA", "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA",
              "ME", "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ", "NM", "NY", "NC", "ND", "OH", "OK",
              "OR", "PA", "RI", "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY"]
    months = [f"{m}-{y}" for y in (2019, 2020, 2021) for m in ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug",
                                                                 "Sep", "Oct", "Nov", "Dec")]
    for i in range(1, 3001):
        rows.append([i, rng.randrange(1000, 40001, 25), rng.choice([36, 36, 60]), f"{rng.uniform(5, 28):.2f}",
                     rng.choice("ABCDEFG"), rng.choice(["< 1 year", "1 year"] + [f"{n} years" for n in range(2, 10)] + ["10+ years"]),
                     rng.choice(["RENT", "OWN", "MORTGAGE"]), f"{rng.uniform(15000, 250000):.2f}",
                     rng.choice(["debt_consolidation", "credit_card", "home_improvement", "car", "medical", "moving",
                                 "vacation", "wedding", "house", "major_purchase", "small_business", "renewable_energy",
                                 "educational", "other"]),
                     rng.choice(states), f"{rng.uniform(0, 40):.2f}", int(rng.random() < 0.18), rng.choice(months)])
    tables["FIN.LOANS"] = ([("LOAN_ID", "DECIMAL(9,0)"), ("AMOUNT_REQUESTED", "DECIMAL(9,0)"), ("TERM_MONTHS", "DECIMAL(2,0)"),
                            ("INTEREST_RATE", "DECIMAL(5,2)"), ("GRADE", "CHAR(1)"), ("EMP_LENGTH", "VARCHAR(10)"),
                            ("HOME_OWNERSHIP", "VARCHAR(10)"), ("ANNUAL_INCOME", "DECIMAL(10,2)"), ("PURPOSE", "VARCHAR(20)"),
                            ("ADDR_STATE", "CHAR(2)"), ("DTI", "DECIMAL(5,2)"), ("DEFAULTED", "DECIMAL(1,0)"),
                            ("ISSUE_MONTH", "VARCHAR(8)")], rows)
    return tables


def held_out_tables() -> dict[str, tuple[list[tuple[str, str]], list[list[Any]]]]:
    rng = random.Random(7041)
    tables = {}
    agents = [f"Mozilla/5.0 ({os_}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/{v}.0 Safari/537.36"
              for os_ in ("Windows NT 10.0; Win64; x64", "Macintosh; Intel Mac OS X 10_15_7", "X11; Linux x86_64",
                          "iPhone; CPU iPhone OS 17_0 like Mac OS X", "Linux; Android 14") for v in range(118, 124)]
    rows = []
    for i in range(1, 4001):
        sent = dt.datetime(2024, 3, 1) + dt.timedelta(minutes=rng.randint(0, 200000))
        opened = rng.random() < 0.3
        rows.append([i, rng.choice([f"{s} Sale {y}" for s in ("Spring", "Summer", "Autumn", "Winter") for y in (2023, 2024, 2025)]),
                     rng.choice(["email", "social", "search", "display"]), sent.strftime("%Y-%m-%dT%H:%M:%SZ"),
                     int(opened), "true" if opened and rng.random() < 0.4 else "false",
                     f"{rng.uniform(0, 400):.2f}" if opened else "0.00", rng.choice(agents),
                     rng.choice(["DE", "FR", "NL", "BE", "AT", "CH", "IT", "ES", "PL", "SE", "DK", "NO", "FI", "IE", "PT"]),
                     rng.randint(0, 3600), rng.choice(["newsletter", "facebook", "google", "instagram", "partner"])])
    tables["MKT.CAMPAIGN_EVENTS"] = ([("eventId", "DECIMAL(9,0)"), ("campaignName", "VARCHAR(40)"), ("channel", "VARCHAR(10)"),
                                      ("sentAt", "VARCHAR(20)"), ("opened", "DECIMAL(1,0)"), ("clicked", "VARCHAR(5)"),
                                      ("revenueEur", "DECIMAL(8,2)"), ("userAgent", "VARCHAR(200)"),
                                      ("countryCode", "CHAR(2)"), ("sessionSeconds", "DECIMAL(5,0)"),
                                      ("utmSource", "VARCHAR(20)")], rows)
    rows = []
    drivers = [f"{rng.choice(FIRST)} {rng.choice(LAST)}" for _ in range(40)]
    for i in range(1, 3001):
        sent = dt.date(2024, 1, 1) + dt.timedelta(days=rng.randint(0, 360))
        delivered = sent + dt.timedelta(days=rng.randint(1, 6)) if rng.random() < 0.9 else None
        rows.append([f"SHP/2024/{i:06d}", rng.choice([f"WH-{c}-0{n}" for c in ("Berlin", "Leipzig", "Hamburg", "Munich") for n in (1, 2)]),
                     f"{rng.randint(1000, 99999):05d}", rng.choice(["DHL", "DPD", "GLS", "UPS", "Hermes"]),
                     f"{rng.uniform(0.2, 30):.2f}", rng.randint(1, 10), sent.strftime("%m/%d/%Y"),
                     delivered.strftime("%m/%d/%Y") if delivered else "", rng.choice("YYYN"), rng.choice(drivers),
                     _sentence(rng, 3, 8) if rng.random() < 0.2 else ""])
    tables["LOGISTICS.SHIPMENTS"] = ([("SHIPMENT_REF", "VARCHAR(16)"), ("ORIGIN_WAREHOUSE", "VARCHAR(16)"),
                                      ("DEST_POSTCODE", "VARCHAR(5)"), ("CARRIER", "VARCHAR(8)"), ("WEIGHT_KG", "DECIMAL(5,2)"),
                                      ("PARCELS", "DECIMAL(2,0)"), ("DISPATCHED_ON", "VARCHAR(10)"),
                                      ("DELIVERED_ON", "VARCHAR(10)"), ("ON_TIME", "CHAR(1)"), ("DRIVER_NAME", "VARCHAR(40)"),
                                      ("COMMENTS", "VARCHAR(200)")], rows)
    rows = []
    codes = [f"{l}{rng.randint(10, 99)}.{rng.randint(0, 9)}" for l in "ABCEFGIJKMNR" for _ in range(3)]
    doctors = [f"Dr. {name}" for name in LAST]
    for i in range(1, 2501):
        patient = rng.randint(1, 800)
        rows.append([i, patient, (dt.date(2023, 1, 1) + dt.timedelta(days=rng.randint(0, 700))).isoformat(),
                     rng.choice(codes), rng.randint(95, 175), rng.randint(48, 120), rng.choice(["TRUE", "FALSE"]),
                     f"{rng.uniform(17, 38):.1f}", rng.choice(doctors), _sentence(rng, 6, 18) if rng.random() < 0.6 else "",
                     f"patient{patient}@mail.example.org"])
    tables["CLINIC.VISITS"] = ([("VISIT_NO", "DECIMAL(9,0)"), ("PATIENT_ID", "DECIMAL(9,0)"), ("VISIT_DATE", "DATE"),
                                ("DIAGNOSIS_CODE", "VARCHAR(8)"), ("SYSTOLIC_BP", "DECIMAL(3,0)"), ("HEART_RATE", "DECIMAL(3,0)"),
                                ("SMOKER", "BOOLEAN"), ("BMI", "DECIMAL(4,1)"), ("DOCTOR", "VARCHAR(30)"),
                                ("NOTES", "VARCHAR(400)"), ("PATIENT_EMAIL", "VARCHAR(60)")], rows)
    rows = []
    managers = {n: f"{rng.choice(FIRST)} {rng.choice(LAST)}" for n in range(1, 11)}
    for day in range(365):
        for store in range(1, 11):
            rows.append([store, (dt.date(2025, 1, 1) + dt.timedelta(days=day)).isoformat(), rng.randint(200, 3000),
                         f"{rng.uniform(2000, 60000):.2f}", rng.randint(8, 12),
                         rng.choice(["sunny", "cloudy", "rain", "snow", "storm"]), int(rng.random() < 0.15),
                         ["North", "South", "East", "West"][store % 4], managers[store], "EUR"])
    tables["RETAIL.STORES_DAILY"] = ([("STORE_NR", "DECIMAL(3,0)"), ("BUSINESS_DAY", "DATE"), ("FOOTFALL", "DECIMAL(5,0)"),
                                      ("TURNOVER", "DECIMAL(10,2)"), ("OPEN_HOURS", "DECIMAL(2,0)"), ("WEATHER", "VARCHAR(8)"),
                                      ("PROMO_ACTIVE", "DECIMAL(1,0)"), ("REGION", "VARCHAR(5)"), ("MANAGER", "VARCHAR(40)"),
                                      ("CURRENCY_CODE", "CHAR(3)")], rows)
    rows = []
    countries = ["US", "CA", "GB", "DE", "FR", "NL", "SE", "NO", "DK", "FI", "ES", "IT", "PT", "PL", "CZ", "AT", "CH",
                 "IE", "BE", "AU", "NZ", "JP", "KR", "SG", "IN", "BR", "MX", "AR", "ZA", "IL"]
    for i in range(1, 2001):
        started = dt.date(2022, 1, 1) + dt.timedelta(days=rng.randint(0, 900))
        cancelled = (dt.datetime.combine(started, dt.time(9)) + dt.timedelta(days=rng.randint(30, 400), minutes=rng.randint(0, 900))
                     if rng.random() < 0.3 else None)
        plan = rng.choice(["free", "pro", "team", "enterprise"])
        seats = 1 if plan == "free" else rng.randint(2, 200)
        rows.append(["{:08x}-{:04x}-4{:03x}-a{:03x}-{:012x}".format(rng.getrandbits(32), rng.getrandbits(16), rng.getrandbits(12),
                                                                   rng.getrandbits(12), rng.getrandbits(48)),
                     rng.randint(1, 1500), plan, seats, f"{seats * rng.choice([0, 12, 15, 25]):.2f}", started.isoformat(),
                     cancelled.isoformat(sep=" ") if cancelled else "", "TRUE" if cancelled else "FALSE",
                     rng.choice(countries), f"REF-{rng.getrandbits(20):05X}" if rng.random() < 0.4 else "",
                     rng.randint(0, 10) if rng.random() < 0.5 else ""])
    tables["SAAS.SUBSCRIPTIONS"] = ([("subscription_uuid", "VARCHAR(36)"), ("account_id", "DECIMAL(9,0)"), ("plan", "VARCHAR(12)"),
                                     ("seats", "DECIMAL(4,0)"), ("mrr_usd", "DECIMAL(9,2)"), ("started", "DATE"),
                                     ("cancelled_at", "TIMESTAMP"), ("churned", "BOOLEAN"), ("billing_country", "CHAR(2)"),
                                     ("referral_code", "VARCHAR(10)"), ("nps", "DECIMAL(2,0)")], rows)
    return tables


# --- scoring ---------------------------------------------------------------------------------------------------------
def _answers(value: Any) -> tuple:
    return value if isinstance(value, tuple) else (value,)


def drafts() -> dict[str, dict[str, Any]]:
    found = {}
    for table, (columns, rows) in {**kit_tables(), **synthetic_tables(), **held_out_tables()}.items():
        profile = profiling.profile_rows(columns, rows, table)
        found[table] = drafting.draft(profile, table.lower().replace(".", "_"))
    return found


def score(docs: dict[str, dict[str, Any]], gold: dict[str, dict[str, Any]] | None = None) -> dict[str, Any]:
    misses, slot_misses = [], []
    roles = slots = right_roles = right_slots = preferred = 0
    wrong_low = wrong = high = high_right = 0
    flagged, expected = set(), set()
    answers = GOLD if gold is None else gold
    for table, expected_table in answers.items():
        doc = docs[table]
        for column, answer in expected_table["roles"].items():
            entry = doc["columns"][column]
            ok = entry["role"] in _answers(answer)
            roles += 1
            right_roles += ok
            preferred += entry["role"] == _answers(answer)[0]
            if entry["confidence"] == "high":
                high += 1
                high_right += ok
            if not ok:
                wrong += 1
                wrong_low += entry["confidence"] == "low"
                misses.append({"table": table, "column": column, "drafted": entry["role"], "confidence": entry["confidence"],
                               "evidence": entry["evidence"], "expected": list(_answers(answer))})
        for slot, answer in expected_table["slots"].items():
            slots += 1
            got = doc["slots"].get(slot)
            if got in _answers(answer):
                right_slots += 1
            else:
                slot_misses.append({"table": table, "slot": slot, "drafted": got, "expected": list(_answers(answer))})
        flagged |= {(table, c) for c, e in doc["columns"].items() if e.get("sensitive")}
        expected |= {(table, c) for c in expected_table.get("sensitive", [])}
    hit = len(flagged & expected)
    return {"tables": len(answers), "columns": roles,
            "roles": round(right_roles / roles, 3), "roles_preferred": round(preferred / roles, 3),
            "slots": round(right_slots / slots, 3),
            "sensitive_recall": round(hit / len(expected), 3) if expected else 1.0,
            "sensitive_precision": round(hit / len(flagged), 3) if flagged else 1.0,
            "caught": round(wrong_low / wrong, 3) if wrong else 1.0,
            "high_right": round(high_right / high, 3) if high else 1.0,
            "misses": misses, "slot_misses": slot_misses,
            "sensitive_missed": sorted(f"{t}.{c}" for t, c in expected - flagged),
            "sensitive_extra": sorted(f"{t}.{c}" for t, c in flagged - expected)}


def report(result: dict[str, Any]) -> str:
    lines = [f"{result['tables']} tables, {result['columns']} columns",
             f"  roles right      {result['roles']:.1%}   (the preferred role {result['roles_preferred']:.1%})",
             f"  slots right      {result['slots']:.1%}",
             f"  sensitive        recall {result['sensitive_recall']:.1%}, precision {result['sensitive_precision']:.1%}",
             f"  wrong, marked low {result['caught']:.1%}   (high-confidence roles right: {result['high_right']:.1%})"]
    if result["misses"]:
        lines.append("\nroles drafted wrong:")
        lines += [f"  {m['table']}.{m['column']}: {m['drafted']} ({m['confidence']}; {m['evidence']}) - expected "
                  f"{' or '.join(m['expected'])}" for m in result["misses"]]
    if result["slot_misses"]:
        lines.append("\nslots drafted wrong:")
        lines += [f"  {m['table']} {m['slot']}: {m['drafted']} - expected {' or '.join(str(e) for e in m['expected'])}"
                  for m in result["slot_misses"]]
    for key, label in (("sensitive_missed", "sensitive, not marked"), ("sensitive_extra", "marked sensitive, is not")):
        if result[key]:
            lines.append(f"\n{label}: {', '.join(result[key])}")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    docs = drafts()
    results = {"tuned": score(docs), "held_out": score(docs, HELD_OUT), "held_out_first": HELD_OUT_FIRST}
    if args.json:
        print(json.dumps(results, indent=2))
    else:
        print("The tables the rules were written against:\n" + report(results["tuned"]))
        print("\nHeld out (written after the rules, never tuned to):\n" + report(results["held_out"]))
        first = HELD_OUT_FIRST
        print(f"  their first run: roles {first['roles']:.1%}, slots {first['slots']:.1%}, sensitive recall "
              f"{first['sensitive_recall']:.1%} - missed: {'; '.join(first['missed'])}")
    if args.check:
        low = [(name, k, results[name][k], floor) for name in ("tuned", "held_out") for k, floor in FLOORS.items()
               if results[name][k] < floor]
        for name, key, got, floor in low:
            print(f"FAIL {name} {key} {got:.1%} is under its floor {floor:.0%}")
        return 1 if low else 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
