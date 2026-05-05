"""
EBS R12 Knowledge Base Loader
==============================
Run this ONCE to load your EBS table definitions into ChromaDB.
After this, run 2_ebs_chat.py to start chatting.

Usage:
    python 1_load_ebs_data.py
"""

import os
import sys
import pandas as pd
import chromadb
from chromadb.utils import embedding_functions
import time

# ─────────────────────────────────────────────
# CONFIGURATION — edit these if needed
# ─────────────────────────────────────────────
CSV_FILE        = r"C:\Users\sjain\Downloads\LP\oracle-vector-db\ebs_all_schemas.csv"
CHROMA_DB_PATH  = r"C:\Users\sjain\Downloads\LP\oracle-vector-db\chromadb"
COLLECTION_NAME = "ebs_r12_tables"
BATCH_SIZE      = 100   # documents per batch — safe for ChromaDB
# ─────────────────────────────────────────────


def load_csv(path):
    print(f"\n📂 Loading CSV: {path}")
    try:
        df = pd.read_csv(path, dtype=str, encoding="utf-8", on_bad_lines="skip", engine="python")
    except UnicodeDecodeError:
        df = pd.read_csv(path, dtype=str, encoding="latin-1", on_bad_lines="skip", engine="python")

    df.columns = [c.strip().upper() for c in df.columns]
    df = df.fillna("")

    print(f"   ✅ Loaded {len(df):,} rows across {df['TABLE_NAME'].nunique():,} tables "
          f"from {df['OWNER'].nunique()} schemas")
    return df


def build_documents(df):
    """
    Group columns by OWNER + TABLE_NAME and build one text document per table.
    Each document contains everything the LLM needs to write SQL for that table.
    """
    print("\n🔨 Building documents (one per table)...")
    docs, ids, metas = [], [], []

    grouped = df.groupby(["OWNER", "TABLE_NAME"])
    total   = len(grouped)

    for i, ((owner, table), grp) in enumerate(grouped, 1):
        # Build column list
        col_lines = []
        for _, row in grp.iterrows():
            parts = [f"  - {row['COLUMN_NAME']} ({row['DATA_TYPE']}"]
            if row.get("DATA_LENGTH"):
                parts[0] += f"({row['DATA_LENGTH']})"
            parts[0] += ")"
            if row.get("NULLABLE") == "N":
                parts[0] += " NOT NULL"
            if row.get("COLUMN_COMMENT"):
                parts[0] += f" -- {row['COLUMN_COMMENT']}"
            col_lines.append(parts[0])

        table_comment = grp["TABLE_COMMENT"].iloc[0] if "TABLE_COMMENT" in grp.columns else ""

        text = f"""Schema: {owner}
Table: {table}
{f'Description: {table_comment}' if table_comment else ''}
Columns:
{chr(10).join(col_lines)}
"""
        doc_id = f"{owner}.{table}"
        docs.append(text)
        ids.append(doc_id)
        metas.append({
            "owner":       owner,
            "table_name":  table,
            "description": table_comment,
            "column_count": str(len(grp))
        })

        if i % 1000 == 0:
            print(f"   ... processed {i:,} / {total:,} tables")

    print(f"   ✅ Built {len(docs):,} documents")
    return docs, ids, metas


def load_into_chromadb(docs, ids, metas):
    print(f"\n🗄️  Connecting to ChromaDB at: {CHROMA_DB_PATH}")
    os.makedirs(CHROMA_DB_PATH, exist_ok=True)

    client = chromadb.PersistentClient(path=CHROMA_DB_PATH)

    # Drop existing collection if re-loading
    existing = [c.name for c in client.list_collections()]
    if COLLECTION_NAME in existing:
        print(f"   ⚠️  Collection '{COLLECTION_NAME}' exists — deleting and reloading...")
        client.delete_collection(COLLECTION_NAME)

    # Use default embedding function (no API key needed)
    ef = embedding_functions.DefaultEmbeddingFunction()
    collection = client.create_collection(
        name=COLLECTION_NAME,
        embedding_function=ef,
        metadata={"hnsw:space": "cosine"}
    )

    total   = len(docs)
    batches = (total + BATCH_SIZE - 1) // BATCH_SIZE
    print(f"   📦 Loading {total:,} documents in {batches} batches of {BATCH_SIZE}...")

    start = time.time()
    for b in range(batches):
        s = b * BATCH_SIZE
        e = min(s + BATCH_SIZE, total)
        collection.add(
            documents=docs[s:e],
            ids=ids[s:e],
            metadatas=metas[s:e]
        )
        pct  = (b + 1) / batches * 100
        elapsed = time.time() - start
        eta  = (elapsed / (b + 1)) * (batches - b - 1)
        print(f"   Batch {b+1:>4}/{batches} ({pct:5.1f}%)  "
              f"elapsed {elapsed:5.0f}s  ETA {eta:5.0f}s")

    total_time = time.time() - start
    print(f"\n   ✅ Loaded {total:,} documents in {total_time:.0f}s")
    return collection


def verify(collection):
    print("\n🔍 Verification — test search: 'gl periods open closed status'")
    results = collection.query(query_texts=["gl periods open closed status"], n_results=5)
    print("   Top matches:")
    for doc_id, meta in zip(results["ids"][0], results["metadatas"][0]):
        print(f"     • {doc_id}  ({meta.get('column_count','?')} columns)")


def summary(df, collection):
    print("\n" + "═" * 55)
    print("  ✅  EBS Knowledge Base Ready!")
    print("═" * 55)
    print(f"  Schemas loaded : {df['OWNER'].nunique()}")
    print(f"  Tables loaded  : {df['TABLE_NAME'].nunique():,}")
    print(f"  Total columns  : {len(df):,}")
    print(f"  ChromaDB path  : {CHROMA_DB_PATH}")
    print("═" * 55)
    print("\n  Next step → run:  python 2_ebs_chat.py\n")


def main():
    print("═" * 55)
    print("  EBS R12 Knowledge Base Loader")
    print("═" * 55)

    # Check CSV exists
    if not os.path.exists(CSV_FILE):
        print(f"\n❌ CSV not found: {CSV_FILE}")
        print("   Please update CSV_FILE path at the top of this script.")
        sys.exit(1)

    df              = load_csv(CSV_FILE)
    docs, ids, metas = build_documents(df)
    collection      = load_into_chromadb(docs, ids, metas)
    verify(collection)
    summary(df, collection)


if __name__ == "__main__":
    main()
