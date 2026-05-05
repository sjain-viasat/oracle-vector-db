# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A two-script RAG (Retrieval-Augmented Generation) pipeline that lets users query Oracle EBS R12 schema knowledge in plain English via a local web chat interface.

## Development Setup & Commands

```bash
# Create venv (first time only, or after moving the folder)
python -m venv venv

# Activate
venv\Scripts\activate        # Windows cmd
venv\Scripts\Activate.ps1   # PowerShell

# Install dependencies
pip install pandas chromadb anthropic flask

# Set API key (required before running chat)
$env:ANTHROPIC_API_KEY = "sk-..."   # PowerShell
set ANTHROPIC_API_KEY=sk-...        # cmd

# Step 1 — Load EBS schema CSV into ChromaDB (run once; re-run to reload)
python 1_load_ebs_data.py

# Step 2 — Start the chat web server
python 2_ebs_chat.py
# then open http://localhost:5000
```

## Architecture

### Two-script pipeline

**`1_load_ebs_data.py`** (run once)
- Reads `ebs_all_schemas.csv` — a flat export of `ALL_TAB_COLUMNS` for 14 EBS schemas
- `build_documents()` groups rows by `OWNER + TABLE_NAME` and collapses each table into one text document (schema, columns, types, nullable, column comments)
- Embeds via ChromaDB's `DefaultEmbeddingFunction` (all-MiniLM-L6-v2 — **downloads ~90 MB on first run**)
- **Re-running drops and recreates the collection** — there is no incremental update
- Persists to `chromadb/` (SQLite-backed) at `CHROMA_DB_PATH`

**`2_ebs_chat.py`** (Flask web server)
- **Server is stateless** — the client (browser JS) maintains conversation history and sends the full history array on every `/chat` POST
- On each `/chat` request: embeds the question → cosine-similarity search → retrieves top `TOP_K` table documents from ChromaDB
- Injects retrieved table definitions + `EBS_ENV_CONTEXT` into Claude's system prompt
- Calls `claude-sonnet-4-20250514` via the Anthropic API
- Returns `{ response, tables_used }` — `tables_used` is the list of ChromaDB document IDs (format: `OWNER.TABLE_NAME`)
- The HTML template is rendered as a Python string literal inside `2_ebs_chat.py` (no separate template files)

### Hardcoded paths — must update when moving
Both scripts have **absolute Windows paths** at the top that must be updated:
- `CSV_FILE` in `1_load_ebs_data.py`
- `CHROMA_DB_PATH` in both scripts (must match — same `chromadb/` folder)

### Key config constants

| Constant | File | Purpose |
|---|---|---|
| `CSV_FILE` | loader | Path to `ebs_all_schemas.csv` |
| `CHROMA_DB_PATH` | both | Path to `chromadb/` data folder |
| `COLLECTION_NAME` | both | ChromaDB collection — must match between scripts |
| `TOP_K` | chat | Tables retrieved per query (default 8) |
| `MAX_HISTORY` | chat | Conversation turns sent from browser per request (default 10) |
| `PORT` | chat | Web server port (default 5000) |

### Data flow
```
ebs_all_schemas.csv
      │
      ▼
1_load_ebs_data.py  →  chromadb/chroma.sqlite3
                              │
                              ▼
                       2_ebs_chat.py  ←→  Anthropic API (Claude)
                              │
                              ▼
                       http://localhost:5000
```

## SQL Files

The repo contains Oracle SQL for AP↔PO/Receipt reconciliation. These are run directly against the EBS database (not through the chat interface).

**`ap_po_rcv_xla_reconciliation.sql`** — Contains two statements:
1. **Main reconciliation** — matches AP XLA lines (`segment1='102'`) against RCV/PO XLA lines (`segment1='101'`) for APR-26, Ledger 1. Covers 3-way receipt match (Cost Management) and 2-way PO match (Payables). Filters out fully paid invoices and fully invoiced PO shipments.
2. **Reverse account detection** — same structure but segment filters swapped (`segment1='101'` on AP side, `segment1='102'` on RCV side) to detect mis-posted entries.

**`ap_po_rcv_xla_reconciliation_Rcpt101_Inv102.sql`** — Standalone version of the reverse account query.

**`Queries.sql`** — Utility queries for exploring EBS schema metadata (table/column counts by owner, GL XLA temp table categorisation, full `ALL_TAB_COLUMNS` extract used to build `ebs_all_schemas.csv`).

The SQL CTE pattern in the reconciliation files: `ap_xla` → `ap_xla_2way` → `rcv_xla` → `po_detail` → main SELECT. The `po_detail` CTE is aliased twice (`pd` for direct PO dist link, `pd_rcv` for 3-way edge case via `RRSL.reference3`).

---

# Oracle EBS R12 AI Assistant — Context

## Environment

| Property | Value |
|---|---|
| EBS Version | R12.1.3 |
| Primary Ledger | *(fill in your ledger name)* |
| Period Set Name | *(fill in your period set name)* |
| Currency | *(fill in e.g. USD)* |
| Operating Units | *(fill in your OU names)* |
| DB Version | Oracle 11g |

---

## Schemas in Use

| Schema | Module | Notes |
|---|---|---|
| APPS | Core EBS | Main schema — most base tables |
| GL | General Ledger | Real tables ~367; exclude XLA_GLT_% (70k+ temp tables — noise) |
| AP | Accounts Payable | |
| AR | Accounts Receivable | |
| INV | Inventory | |
| ONT | Order Management | |
| PO | Purchasing | |
| PA | Project Accounting | |
| HR | Human Resources | |
| HXT | HXT Time & Labor | |
| OKL | Oracle Lease Management | |
| OKC | Oracle Contracts Core | |
| FA | Fixed Assets | |
| BOM | BOM / Calendar | Working day calendars live here |
| VSCON | Custom Schema | Company-specific customisations |

> **Excluded:** GMS (Grants Management) — not in use
> **GL Warning:** `all_tables` under GL owner contains 70,577 temp tables named `XLA_GLT_%` — always exclude with `AND table_name NOT LIKE 'XLA_GLT_%'` when querying GL schema metadata

---

## Modules in Use

- GL — General Ledger
- AP — Accounts Payable
- AR — Accounts Receivable
- INV — Inventory / Item Master
- OM — Order Management (schema: ONT)
- PO — Purchasing
- PA — Project Accounting
- OTL — Time & Labor (schema: HXT)
- HR — Human Resources
- PAY — Payroll
- OKL — Oracle Lease Management
- OKC — Oracle Contracts Core
- FA — Fixed Assets

---

## Key SQL Rules

1. Always qualify table names with schema (e.g. `APPS.GL_PERIODS` or `GL.GL_PERIODS`)
2. Multi-org tables ending in `_ALL` — always filter by `ORG_ID`
3. Use bind variables (`:parameter`) instead of hardcoded values
4. SQL must be Oracle 11g / EBS R12 compatible
5. When joining tables always explain the join condition
6. Flag potentially slow queries and suggest indexes or hints
7. If unsure which table to use, present options with explanation

---

## Business Day / Calendar Logic

- Working day calendars are stored in `BOM_CALENDAR_DATES`
- `SEQ_NUM IS NOT NULL` = working/business day
- `SEQ_NUM IS NULL` = non-working day (weekend or holiday)
- Holiday exceptions stored in `BOM_CALENDAR_EXCEPTIONS` (`EXCEPTION_TYPE = 2` = non-working)
- Calendar linked to org via `MTL_PARAMETERS.CALENDAR_CODE` and `MTL_PARAMETERS.CALENDAR_EXCEPTION_SET_ID`
- Do NOT use `exception_set_id = 0` — use the value from `MTL_PARAMETERS.CALENDAR_EXCEPTION_SET_ID` for the relevant org
- Weekend check: `TO_CHAR(date, 'DY', 'NLS_DATE_LANGUAGE=AMERICAN') IN ('SAT','SUN')`

### Business Day Classification Logic
```sql
CASE
  WHEN TO_CHAR(bcd.calendar_date,'DY','NLS_DATE_LANGUAGE=AMERICAN')
       IN ('SAT','SUN') AND bcd.seq_num IS NOT NULL  THEN 'Special Working Day'
  WHEN TO_CHAR(bcd.calendar_date,'DY','NLS_DATE_LANGUAGE=AMERICAN')
       IN ('SAT','SUN')                              THEN 'Weekend'
  WHEN bcd.seq_num IS NULL                           THEN 'Holiday'
  ELSE                                                    'Business Day'
END
```

---

## GL Key Tables

| Table | Purpose |
|---|---|
| `GL_PERIODS` | Accounting periods — STATUS: O=Open, C=Closed, F=Future, N=Never Opened |
| `GL_LEDGERS` | Ledger definitions |
| `GL_SETS_OF_BOOKS` | Legacy Set of Books (older R12 setups) |
| `GL_CODE_COMBINATIONS` | Chart of accounts — account code combinations |
| `GL_JE_HEADERS` | Journal entry headers |
| `GL_JE_LINES` | Journal entry lines |
| `GL_BALANCES` | Account balances |
| `GL_DATE_PERIOD_MAP` | Maps each date to a GL period |

### Find Period Set Name
```sql
SELECT name, period_set_name, currency_code
FROM gl_ledgers
WHERE ledger_category_code = 'PRIMARY';
```

---

## AP Key Tables

| Table | Purpose |
|---|---|
| `AP_INVOICES_ALL` | Invoice headers (filter by ORG_ID); `payment_status_flag`: N=Unpaid, P=Partial, Y=Fully Paid |
| `AP_INVOICE_LINES_ALL` | Invoice lines |
| `AP_INVOICE_DISTRIBUTIONS_ALL` | Invoice distributions |
| `AP_CHECKS_ALL` | Payment checks |
| `AP_PAYMENT_SCHEDULES_ALL` | Payment schedules |
| `AP_SUPPLIERS` | Supplier master (formerly PO_VENDORS) |
| `AP_SUPPLIER_SITES_ALL` | Supplier sites |

---

## AR Key Tables

| Table | Purpose |
|---|---|
| `RA_CUSTOMER_TRX_ALL` | Transaction headers (invoices, credit memos) |
| `RA_CUSTOMER_TRX_LINES_ALL` | Transaction lines |
| `AR_CASH_RECEIPTS_ALL` | Cash receipts |
| `AR_RECEIVABLE_APPLICATIONS_ALL` | Receipt applications |
| `HZ_PARTIES` | Party master (customers, suppliers, people) |
| `HZ_CUST_ACCOUNTS` | Customer accounts |

---

## INV Key Tables

| Table | Purpose |
|---|---|
| `MTL_SYSTEM_ITEMS_B` | Item master |
| `MTL_PARAMETERS` | Org parameters incl. calendar_code, calendar_exception_set_id |
| `MTL_MATERIAL_TRANSACTIONS` | Material transactions |
| `MTL_ONHAND_QUANTITIES_DETAIL` | Onhand stock |
| `MTL_ITEM_CATEGORIES` | Item-category assignments |
| `MTL_CATEGORIES_B` | Category definitions |

---

## PO Key Tables

| Table | Purpose |
|---|---|
| `PO_HEADERS_ALL` | Purchase order headers |
| `PO_LINES_ALL` | PO lines |
| `PO_LINE_LOCATIONS_ALL` | Shipment schedules; `quantity_billed` vs `quantity` indicates invoicing completeness |
| `PO_DISTRIBUTIONS_ALL` | PO distributions |
| `PO_RELEASES_ALL` | Blanket releases |
| `PO_REQUISITION_HEADERS_ALL` | Requisition headers |
| `PO_REQUISITION_LINES_ALL` | Requisition lines |

---

## OM Key Tables (Schema: ONT)

| Table | Purpose |
|---|---|
| `OE_ORDER_HEADERS_ALL` | Sales order headers |
| `OE_ORDER_LINES_ALL` | Sales order lines |
| `OE_TRANSACTION_TYPES_ALL` | Order/line transaction types |
| `OE_ORDER_HOLDS_ALL` | Order holds |

---

## PA Key Tables (Project Accounting)

| Table | Purpose |
|---|---|
| `PA_PROJECTS_ALL` | Project definitions |
| `PA_TASKS` | Project tasks |
| `PA_EXPENDITURES_ALL` | Expenditure batches |
| `PA_EXPENDITURE_ITEMS_ALL` | Expenditure item detail |
| `PA_AGREEMENTS_ALL` | Project agreements |
| `PA_DRAFT_INVOICES_ALL` | Project invoices |
| `PA_BUDGET_VERSIONS` | Project budgets |

---

## HR Key Tables

| Table | Purpose |
|---|---|
| `PER_ALL_PEOPLE_F` | People (date-tracked) |
| `PER_ALL_ASSIGNMENTS_F` | Assignments (date-tracked) |
| `PER_ALL_POSITIONS` | Position definitions |
| `HR_ALL_ORGANIZATION_UNITS` | Organizations / departments |
| `PAY_ALL_PAYROLLS_F` | Payroll definitions |
| `PAY_PAYROLL_ACTIONS` | Payroll runs |
| `PAY_ASSIGNMENT_ACTIONS` | Assignment-level payroll actions |
| `PAY_RUN_RESULTS` | Payroll element run results |

---

## OKL Key Tables (Lease Management)

| Table | Purpose |
|---|---|
| `OKL_K_HEADERS_FULL_V` | Lease contract headers (view) |
| `OKC_K_HEADERS_ALL_B` | Contract headers base table |
| `OKC_K_LINES_B` | Contract lines |

---

## FA Key Tables (Fixed Assets)

| Table | Purpose |
|---|---|
| `FA_ADDITIONS_B` | Asset additions |
| `FA_ASSET_HISTORY` | Asset history |
| `FA_BOOKS` | Asset book details |
| `FA_DEPRN_SUMMARY` | Depreciation summary |
| `FA_LOCATIONS` | Asset locations |

---

## Vector Database Setup

This EBS environment uses a **local ChromaDB vector database** on Windows at:
```
C:\Users\sjain\Downloads\LP\oracle-vector-db\chromadb
```

- **Collection:** `ebs_r12_tables`
- **Content:** All table + column definitions extracted from `ALL_TAB_COLUMNS` for the schemas above
- **Loader script:** `1_load_ebs_data.py`
- **Chat interface:** `2_ebs_chat.py` → http://localhost:5000
- **Embedding:** ChromaDB `DefaultEmbeddingFunction` (all-MiniLM-L6-v2; downloads ~90 MB on first run)
- **LLM:** `claude-sonnet-4-20250514` via Anthropic API

### Extraction Query Used
```sql
SELECT atc.owner, atc.table_name, atc.column_name,
       atc.data_type, atc.data_length, atc.data_precision,
       atc.nullable, atc.column_id,
       tcom.comments AS table_comment,
       ccom.comments AS column_comment
FROM all_tab_columns atc
JOIN all_tables at2
    ON  at2.owner = atc.owner AND at2.table_name = atc.table_name
LEFT JOIN all_tab_comments tcom
    ON  tcom.owner = atc.owner AND tcom.table_name = atc.table_name
LEFT JOIN all_col_comments ccom
    ON  ccom.owner = atc.owner AND ccom.table_name = atc.table_name
    AND ccom.column_name = atc.column_name
WHERE atc.owner IN (
    'APPS','GL','AP','AR','INV','ONT','PO',
    'PA','HR','HXT','OKL','OKC','FA','BOM','VSCON'
)
AND at2.num_rows > 0
AND NOT (atc.owner = 'GL' AND atc.table_name LIKE 'XLA_GLT_%')
ORDER BY atc.owner, atc.table_name, atc.column_id;
```

---

## Notes & Gotchas

- **GL XLA Temp Tables:** GL owner contains 70,577 temp tables named `XLA_GLT_%` — always exclude them from any metadata queries
- **Date-tracked HR tables:** Always join with `SYSDATE BETWEEN effective_start_date AND effective_end_date`
- **Multi-org:** All `_ALL` tables require `ORG_ID` filter — get it from `MO_GLOBAL.GET_CURRENT_ORG_ID()` or `FND_PROFILE.VALUE('ORG_ID')`
- **VSCON schema:** Custom company tables — treat column comments as the primary source of truth for business meaning
- **OTL schema is HXT:** Time & Labor physical schema is `HXT`, not `OTL`
- **AP payment_status_flag:** `N`=Unpaid, `P`=Partial, `Y`=Fully Paid — filter `!= 'Y'` to exclude cleared invoices
- **PO fully invoiced check:** `NVL(plla.quantity_billed,0) >= plla.quantity` on `PO_LINE_LOCATIONS_ALL`; amount-based service lines (quantity IS NULL) need a separate `amount_billed >= amount` check
- **XLA linking for receipts:** `xte.source_id_int_2` (not `int_1`) holds the `accounting_event_id` for Cost Management RCV entities
- **ChromaDB re-load:** `1_load_ebs_data.py` drops and fully recreates the collection on every run — no incremental updates
