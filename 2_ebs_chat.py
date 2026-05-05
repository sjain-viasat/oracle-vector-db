"""
EBS R12 AI Assistant — Chat Interface
=======================================
Runs a local web chat interface in your browser.

Usage:
    python 2_ebs_chat.py
Then open:
    http://localhost:5000

Requirements:
    pip install anthropic chromadb pandas flask
"""

import os
import json
import anthropic
import chromadb
from chromadb.utils import embedding_functions
from flask import Flask, request, jsonify, render_template_string

# ─────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────
CHROMA_DB_PATH  = r"C:\Users\sjain\Downloads\LP\oracle-vector-db\chromadb"
COLLECTION_NAME = "ebs_r12_tables"
TOP_K           = 8      # number of relevant tables to retrieve per query
MAX_HISTORY     = 10     # conversation turns to keep in memory
PORT            = 5000
# ─────────────────────────────────────────────

# ── EBS Environment Context (edit to match your instance) ──────────────────
EBS_ENV_CONTEXT = """
You are an Oracle EBS R12.1.3 SQL expert assistant.

Environment details:
- EBS Version      : R12.1.3
- Key Schemas      : APPS, GL, AP, AR, INV, ONT, PO, PA, HR, HXT, OKL, OKC, FA, BOM, VSCON
- Custom Schema    : VSCON (company-specific customisations)
- Modules in use   : GL, AP, AR, INV, OM, PO, PA (Project Accounting), OTL, HR, OKL, OKC, FA

Rules you must follow:
1. Always qualify table names with their owner/schema (e.g. APPS.GL_PERIODS or GL.GL_PERIODS)
2. For multi-org tables ending in _ALL, always remind the user to filter by ORG_ID
3. Always use bind variables (:parameter) instead of hardcoded values where appropriate
4. If a table has a WHO column (CREATED_BY, LAST_UPDATED_BY etc.), mention it if relevant
5. When joining tables, always explain the join condition
6. Flag if a query might be slow and suggest indexes or hints
7. If unsure which table to use, present options and explain the difference
8. Always write SQL that is compatible with Oracle 11g / EBS R12
"""

# ── HTML Chat Interface ────────────────────────────────────────────────────
HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>EBS R12 AI Assistant</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600&family=Syne:wght@400;600;800&display=swap');

  :root {
    --bg:        #0d0f14;
    --surface:   #161a23;
    --border:    #252c3a;
    --accent:    #e8a020;
    --accent2:   #3d7fff;
    --text:      #d4dbe8;
    --muted:     #5a6478;
    --user-bg:   #1a2235;
    --ai-bg:     #13171f;
    --code-bg:   #0a0c10;
    --radius:    10px;
  }

  * { box-sizing: border-box; margin: 0; padding: 0; }

  body {
    background: var(--bg);
    color: var(--text);
    font-family: 'Syne', sans-serif;
    height: 100vh;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }

  /* ── Header ── */
  header {
    padding: 14px 24px;
    background: var(--surface);
    border-bottom: 1px solid var(--border);
    display: flex;
    align-items: center;
    gap: 14px;
    flex-shrink: 0;
  }
  .logo {
    width: 36px; height: 36px;
    background: var(--accent);
    border-radius: 8px;
    display: flex; align-items: center; justify-content: center;
    font-size: 18px; font-weight: 800; color: #000;
  }
  .header-text h1 { font-size: 15px; font-weight: 800; letter-spacing: .04em; }
  .header-text p  { font-size: 11px; color: var(--muted); margin-top: 1px; }
  .status-dot {
    margin-left: auto;
    display: flex; align-items: center; gap: 6px;
    font-size: 11px; color: var(--muted);
  }
  .dot {
    width: 7px; height: 7px; border-radius: 50%;
    background: #2ecc71; animation: pulse 2s infinite;
  }
  @keyframes pulse {
    0%,100% { opacity:1; } 50% { opacity:.4; }
  }

  /* ── Schema badges ── */
  .schema-bar {
    padding: 8px 24px;
    background: var(--surface);
    border-bottom: 1px solid var(--border);
    display: flex; gap: 6px; flex-wrap: wrap;
    flex-shrink: 0;
  }
  .badge {
    padding: 2px 8px; border-radius: 4px;
    font-size: 10px; font-family: 'JetBrains Mono', monospace;
    font-weight: 600; letter-spacing: .06em;
    background: var(--border); color: var(--muted);
    border: 1px solid transparent;
    cursor: default;
    transition: all .15s;
  }
  .badge:hover { color: var(--accent); border-color: var(--accent); }

  /* ── Messages ── */
  #messages {
    flex: 1;
    overflow-y: auto;
    padding: 24px;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }
  #messages::-webkit-scrollbar { width: 4px; }
  #messages::-webkit-scrollbar-track { background: transparent; }
  #messages::-webkit-scrollbar-thumb { background: var(--border); border-radius: 2px; }

  .msg { display: flex; gap: 12px; max-width: 900px; animation: fadeIn .2s ease; }
  @keyframes fadeIn { from { opacity:0; transform:translateY(6px); } to { opacity:1; transform:none; } }

  .msg.user  { align-self: flex-end; flex-direction: row-reverse; }
  .msg.ai    { align-self: flex-start; }

  .avatar {
    width: 32px; height: 32px; border-radius: 8px;
    display: flex; align-items: center; justify-content: center;
    font-size: 14px; flex-shrink: 0; margin-top: 2px;
  }
  .msg.user .avatar { background: var(--accent2); }
  .msg.ai   .avatar { background: var(--accent); color: #000; font-weight: 800; }

  .bubble {
    padding: 12px 16px;
    border-radius: var(--radius);
    font-size: 14px; line-height: 1.65;
    max-width: calc(100% - 48px);
  }
  .msg.user .bubble {
    background: var(--user-bg);
    border: 1px solid var(--border);
    border-top-right-radius: 2px;
  }
  .msg.ai .bubble {
    background: var(--ai-bg);
    border: 1px solid var(--border);
    border-top-left-radius: 2px;
  }

  /* ── Code blocks ── */
  .bubble pre {
    background: var(--code-bg);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 14px;
    margin: 10px 0;
    overflow-x: auto;
    font-family: 'JetBrains Mono', monospace;
    font-size: 12.5px;
    line-height: 1.6;
    color: #a8d8a8;
    position: relative;
  }
  .bubble code {
    font-family: 'JetBrains Mono', monospace;
    font-size: 12.5px;
    background: var(--code-bg);
    padding: 1px 5px;
    border-radius: 3px;
    color: #a8d8a8;
  }
  .bubble pre code { background: none; padding: 0; }

  .copy-btn {
    position: absolute; top: 8px; right: 8px;
    background: var(--border); border: none;
    color: var(--muted); font-size: 10px;
    padding: 3px 8px; border-radius: 4px;
    cursor: pointer; font-family: 'Syne', sans-serif;
    transition: all .15s;
  }
  .copy-btn:hover { background: var(--accent); color: #000; }

  /* ── Tables chip ── */
  .tables-used {
    margin-top: 10px;
    padding: 8px 10px;
    background: #0d1520;
    border: 1px solid #1e2d45;
    border-radius: 6px;
    font-size: 11px;
    color: var(--muted);
  }
  .tables-used span { color: var(--accent2); font-family: 'JetBrains Mono', monospace; }

  /* ── Thinking indicator ── */
  .thinking {
    display: flex; align-items: center; gap: 8px;
    color: var(--muted); font-size: 13px; padding: 4px 0;
  }
  .dots span {
    display: inline-block; width: 5px; height: 5px;
    background: var(--accent); border-radius: 50%; margin: 0 1px;
    animation: bounce .8s infinite;
  }
  .dots span:nth-child(2) { animation-delay: .15s; }
  .dots span:nth-child(3) { animation-delay: .30s; }
  @keyframes bounce {
    0%,80%,100% { transform:translateY(0); }
    40%          { transform:translateY(-6px); }
  }

  /* ── Welcome ── */
  .welcome {
    text-align: center; padding: 40px 20px; color: var(--muted);
  }
  .welcome h2 { font-size: 22px; color: var(--text); margin-bottom: 8px; font-weight: 800; }
  .welcome p  { font-size: 13px; line-height: 1.7; max-width: 500px; margin: 0 auto 24px; }
  .suggestions { display: flex; flex-wrap: wrap; gap: 8px; justify-content: center; }
  .suggestion {
    padding: 8px 14px; border-radius: 20px;
    border: 1px solid var(--border);
    background: var(--surface);
    font-size: 12px; cursor: pointer;
    transition: all .15s; color: var(--text);
    font-family: 'Syne', sans-serif;
  }
  .suggestion:hover { border-color: var(--accent); color: var(--accent); }

  /* ── Input bar ── */
  .input-bar {
    padding: 16px 24px;
    background: var(--surface);
    border-top: 1px solid var(--border);
    display: flex; gap: 10px; align-items: flex-end;
    flex-shrink: 0;
  }
  #input {
    flex: 1;
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 12px 16px;
    color: var(--text);
    font-family: 'Syne', sans-serif;
    font-size: 14px;
    resize: none;
    min-height: 48px; max-height: 160px;
    outline: none;
    transition: border-color .15s;
    line-height: 1.5;
  }
  #input:focus { border-color: var(--accent); }
  #input::placeholder { color: var(--muted); }

  #send {
    background: var(--accent);
    border: none; border-radius: var(--radius);
    width: 48px; height: 48px;
    cursor: pointer; font-size: 18px;
    transition: all .15s; flex-shrink: 0;
    display: flex; align-items: center; justify-content: center;
  }
  #send:hover   { background: #f0b030; transform: scale(1.05); }
  #send:active  { transform: scale(.97); }
  #send:disabled { background: var(--border); cursor: not-allowed; transform: none; }

  .clear-btn {
    background: none; border: 1px solid var(--border);
    border-radius: var(--radius); padding: 0 14px; height: 48px;
    color: var(--muted); cursor: pointer; font-size: 11px;
    font-family: 'Syne', sans-serif; transition: all .15s;
    flex-shrink: 0;
  }
  .clear-btn:hover { border-color: #e74c3c; color: #e74c3c; }

  .hint { font-size: 10px; color: var(--muted); text-align: center; padding: 4px 0 0; flex-shrink: 0; }
</style>
</head>
<body>

<header>
  <div class="logo">E</div>
  <div class="header-text">
    <h1>EBS R12 AI Assistant</h1>
    <p>Oracle E-Business Suite R12.1.3 · Powered by Claude</p>
  </div>
  <div class="status-dot"><div class="dot"></div> Connected</div>
</header>

<div class="schema-bar">
  <span style="font-size:10px;color:var(--muted);margin-right:4px;line-height:22px;">SCHEMAS:</span>
  {% for s in ['APPS','GL','AP','AR','INV','ONT','PO','PA','HR','HXT','OKL','OKC','FA','BOM','VSCON'] %}
  <div class="badge">{{ s }}</div>
  {% endfor %}
</div>

<div id="messages">
  <div class="welcome">
    <h2>EBS Knowledge Base Ready</h2>
    <p>Ask me anything about Oracle EBS R12 — tables, SQL queries, joins, module logic, or data troubleshooting. I'll find the relevant tables and write precise SQL for your environment.</p>
    <div class="suggestions">
      <div class="suggestion" onclick="sendSuggestion(this)">Business days in current GL period</div>
      <div class="suggestion" onclick="sendSuggestion(this)">AP invoices pending approval</div>
      <div class="suggestion" onclick="sendSuggestion(this)">AR outstanding receivables by customer</div>
      <div class="suggestion" onclick="sendSuggestion(this)">PO headers with open lines</div>
      <div class="suggestion" onclick="sendSuggestion(this)">Project expenditures by task</div>
      <div class="suggestion" onclick="sendSuggestion(this)">Employee assignments in HR</div>
      <div class="suggestion" onclick="sendSuggestion(this)">Inventory onhand quantities</div>
      <div class="suggestion" onclick="sendSuggestion(this)">OKL lease contracts expiring soon</div>
    </div>
  </div>
</div>

<div class="input-bar">
  <textarea id="input" placeholder="Ask about EBS tables, SQL queries, joins, module logic..." rows="1"></textarea>
  <button class="clear-btn" onclick="clearChat()">Clear</button>
  <button id="send" onclick="sendMessage()">➤</button>
</div>
<div class="hint">Enter to send · Shift+Enter for new line</div>

<script>
const messagesEl = document.getElementById('messages');
const inputEl    = document.getElementById('input');
const sendBtn    = document.getElementById('send');
let history      = [];

// Auto-resize textarea
inputEl.addEventListener('input', () => {
  inputEl.style.height = 'auto';
  inputEl.style.height = Math.min(inputEl.scrollHeight, 160) + 'px';
});

inputEl.addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
});

function sendSuggestion(el) {
  inputEl.value = el.textContent;
  sendMessage();
}

function clearChat() {
  history = [];
  messagesEl.innerHTML = '';
  appendWelcome();
}

function appendWelcome() {
  messagesEl.innerHTML = `
    <div class="welcome">
      <h2>Chat Cleared</h2>
      <p>Start a new EBS question below.</p>
    </div>`;
}

function scrollBottom() {
  messagesEl.scrollTop = messagesEl.scrollHeight;
}

function addMessage(role, html, tables) {
  // Remove welcome on first message
  const welcome = messagesEl.querySelector('.welcome');
  if (welcome) welcome.remove();

  const div = document.createElement('div');
  div.className = `msg ${role}`;

  const avatar = role === 'user'
    ? '<div class="avatar">👤</div>'
    : '<div class="avatar">E</div>';

  let tablesHtml = '';
  if (tables && tables.length) {
    tablesHtml = `<div class="tables-used">
      📋 Tables searched: ${tables.map(t => `<span>${t}</span>`).join(', ')}
    </div>`;
  }

  div.innerHTML = `
    ${avatar}
    <div class="bubble">${html}${tablesHtml}</div>`;

  // Add copy buttons to code blocks
  div.querySelectorAll('pre').forEach(pre => {
    const btn = document.createElement('button');
    btn.className = 'copy-btn';
    btn.textContent = 'Copy';
    btn.onclick = () => {
      navigator.clipboard.writeText(pre.innerText.replace('Copy','').trim());
      btn.textContent = 'Copied!';
      setTimeout(() => btn.textContent = 'Copy', 2000);
    };
    pre.style.position = 'relative';
    pre.appendChild(btn);
  });

  messagesEl.appendChild(div);
  scrollBottom();
  return div;
}

function addThinking() {
  const div = document.createElement('div');
  div.className = 'msg ai';
  div.id = 'thinking';
  div.innerHTML = `
    <div class="avatar">E</div>
    <div class="bubble">
      <div class="thinking">
        Searching EBS knowledge base
        <div class="dots"><span></span><span></span><span></span></div>
      </div>
    </div>`;
  messagesEl.appendChild(div);
  scrollBottom();
}

function formatResponse(text) {
  // Convert markdown-ish SQL blocks
  text = text.replace(/```sql([\s\S]*?)```/gi, '<pre><code>$1</code></pre>');
  text = text.replace(/```([\s\S]*?)```/g, '<pre><code>$1</code></pre>');
  text = text.replace(/`([^`]+)`/g, '<code>$1</code>');
  // Bold
  text = text.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
  // Line breaks
  text = text.replace(/\n/g, '<br>');
  return text;
}

async function sendMessage() {
  const text = inputEl.value.trim();
  if (!text || sendBtn.disabled) return;

  inputEl.value = '';
  inputEl.style.height = 'auto';
  sendBtn.disabled = true;

  addMessage('user', text.replace(/</g,'&lt;').replace(/>/g,'&gt;'));
  history.push({ role: 'user', content: text });

  addThinking();

  try {
    const res = await fetch('/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ message: text, history: history.slice(-{{ max_history }}) })
    });

    document.getElementById('thinking')?.remove();

    if (!res.ok) throw new Error(`Server error: ${res.status}`);

    const data = await res.json();
    if (data.error) throw new Error(data.error);

    addMessage('ai', formatResponse(data.response), data.tables_used);
    history.push({ role: 'assistant', content: data.response });

  } catch (err) {
    document.getElementById('thinking')?.remove();
    addMessage('ai', `<span style="color:#e74c3c">⚠️ Error: ${err.message}</span>`);
  }

  sendBtn.disabled = false;
  inputEl.focus();
}
</script>
</body>
</html>
"""

# ── Flask App ──────────────────────────────────────────────────────────────
app = Flask(__name__)

# Load ChromaDB once at startup
print("🔌 Connecting to ChromaDB...")
_client     = chromadb.PersistentClient(path=CHROMA_DB_PATH)
_ef         = embedding_functions.DefaultEmbeddingFunction()
_collection = _client.get_collection(name=COLLECTION_NAME, embedding_function=_ef)
_claude     = anthropic.Anthropic()
print(f"✅ Connected — {_collection.count():,} table documents loaded")


def retrieve_tables(question: str, k: int = TOP_K) -> tuple[list[str], list[str]]:
    """Semantic search — return relevant table docs and their IDs."""
    results = _collection.query(query_texts=[question], n_results=k)
    docs    = results["documents"][0]
    ids     = results["ids"][0]
    return docs, ids


@app.route("/")
def index():
    return render_template_string(HTML, max_history=MAX_HISTORY)


@app.route("/chat", methods=["POST"])
def chat():
    data    = request.json
    message = data.get("message", "").strip()
    history = data.get("history", [])

    if not message:
        return jsonify({"error": "Empty message"}), 400

    try:
        # 1. Retrieve relevant tables
        table_docs, table_ids = retrieve_tables(message)

        # 2. Build context block
        context = "\n\n---\n\n".join(table_docs)

        # 3. System prompt = env context + retrieved table definitions
        system_prompt = f"""{EBS_ENV_CONTEXT}

The following EBS table definitions are relevant to the user's question.
Use ONLY these tables when writing SQL — do not invent table or column names.

=== RELEVANT TABLE DEFINITIONS ===
{context}
=== END TABLE DEFINITIONS ===

If none of the retrieved tables seem relevant, say so and ask the user to clarify the module or table area.
"""

        # 4. Build message history (exclude the current message — it's already in history)
        messages = [m for m in history if m["role"] in ("user", "assistant")]
        # Ensure last message is the current one
        if not messages or messages[-1]["content"] != message:
            messages.append({"role": "user", "content": message})

        # 5. Call Claude
        response = _claude.messages.create(
            model      = "claude-sonnet-4-20250514",
            max_tokens = 2048,
            system     = system_prompt,
            messages   = messages
        )

        answer = response.content[0].text

        return jsonify({
            "response":   answer,
            "tables_used": table_ids
        })

    except Exception as e:
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    print("\n" + "═" * 55)
    print("  EBS R12 AI Assistant")
    print("═" * 55)
    print(f"  Open in browser → http://localhost:{PORT}")
    print("  Press Ctrl+C to stop")
    print("═" * 55 + "\n")
    app.run(debug=False, port=PORT)
