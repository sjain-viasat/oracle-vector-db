# Oracle EBS R12 AI Assistant

A local RAG (Retrieval-Augmented Generation) pipeline that lets you query Oracle EBS R12 schema knowledge in plain English via a browser chat interface.

Ask questions like:
- *"Which tables store AP invoice distributions and how do they link to GL?"*
- *"Write a query to find all open POs for a supplier that haven't been fully invoiced."*
- *"What columns in AP_INVOICES_ALL track payment status?"*

---

## How It Works

```
ebs_all_schemas.csv  →  ChromaDB (local vector store)  →  Flask chat UI  →  Claude (Anthropic API)
```

1. **`1_load_ebs_data.py`** reads your EBS schema CSV (`ALL_TAB_COLUMNS` export), embeds every table's column definitions, and stores them in a local ChromaDB vector database.
2. **`2_ebs_chat.py`** runs a Flask web server. Each question is embedded, matched against the vector store, and the top matching table definitions are injected into Claude's context before answering.

The server is stateless — conversation history is maintained in the browser and sent with each request.

---

## Setup

### Prerequisites

- Python 3.10+
- An [Anthropic API key](https://console.anthropic.com/)

### Install

```bash
python -m venv venv

# Activate (Windows cmd)
venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt
```

> On first run, ChromaDB downloads the `all-MiniLM-L6-v2` embedding model (~90 MB).

### Configure paths

Both scripts have absolute paths at the top that must match your local setup:

| Script | Constant | What to set |
|---|---|---|
| `1_load_ebs_data.py` | `CSV_FILE` | Full path to `ebs_all_schemas.csv` |
| `1_load_ebs_data.py` | `CHROMA_DB_PATH` | Path to the `chromadb/` folder |
| `2_ebs_chat.py` | `CHROMA_DB_PATH` | Must match the loader path above |

### Set your API key

```bash
# Windows cmd
set ANTHROPIC_API_KEY=sk-...

# PowerShell
$env:ANTHROPIC_API_KEY = "sk-..."
```

---

## Usage

**Step 1 — Load the schema (run once):**

```bash
python 1_load_ebs_data.py
```

This drops and recreates the ChromaDB collection from the CSV. Re-run any time the CSV is updated.

**Step 2 — Start the chat interface:**

```bash
python 2_ebs_chat.py
```

Open [http://localhost:5000](http://localhost:5000) in your browser.

---

## Generating `ebs_all_schemas.csv`

Run this query against your Oracle EBS database and export the results to CSV:

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

> The GL schema contains ~70k temp tables named `XLA_GLT_%` — the `NOT` filter above excludes them.

---

## SQL Files

| File | Purpose |
|---|---|
| `Queries.sql` | Utility queries for exploring EBS schema metadata |

---

## Configuration Reference

| Constant | File | Default | Purpose |
|---|---|---|---|
| `CSV_FILE` | loader | *(absolute path)* | Path to `ebs_all_schemas.csv` |
| `CHROMA_DB_PATH` | both | *(absolute path)* | Path to ChromaDB data folder |
| `COLLECTION_NAME` | both | `ebs_r12_tables` | Must match between scripts |
| `TOP_K` | chat | `8` | Tables retrieved per query |
| `MAX_HISTORY` | chat | `10` | Conversation turns sent per request |
| `PORT` | chat | `5000` | Web server port |

---

## Schemas Covered

`APPS` · `GL` · `AP` · `AR` · `INV` · `ONT` · `PO` · `PA` · `HR` · `HXT` · `OKL` · `OKC` · `FA` · `BOM` · `VSCON`
