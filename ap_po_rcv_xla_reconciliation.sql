/*════════════════════════════════════════════════════════════════════════════
  AP ↔ PO/Receipt XLA Reconciliation  —  APR-26, Ledger 1
  ─────────────────────────────────────────────────────────────────────────
  Covers TWO match scenarios:

  A. 3-WAY RECEIPT MATCH  (rcv_transaction_id IS NOT NULL)
     • AP XLA  (Payables)        : segment1 = '102'  ← CTE ap_xla
     • RCV XLA (Cost Management) : segment1 = '101'  ← CTE rcv_xla
     • Link: aid.rcv_transaction_id = rrsl.rcv_transaction_id

  B. 2-WAY PO MATCH — Expense lines  (rcv_transaction_id IS NULL)
     Both sides live inside the SAME Payables XLA event:
     • AP LIABILITY line  (Payables) : segment1 = '102'  ← CTE ap_xla
     • AP CHARGE/EXPENSE line (Payables): segment1 = '101' ← CTE ap_xla_2way
     • Link: same ae_header_id + invoice_distribution_id
     Typical EBS setup: Expense PO lines, 2-Way match,
                        Accrue at Receipt = No, Invoice Match Option = PO

  Output flag  PO_RCV_SOURCE tells you which path was used per row.
════════════════════════════════════════════════════════════════════════════*/
WITH
/*──────────────────────────────────────────────────────────────────────────
  1. AP INVOICE XLA LINES  —  segment1 = '102'  (AP liability / accrual)
     Application : Payables
     Period      : APR-26, Ledger 1
     Both 3-way (rcv_transaction_id NOT NULL) and 2-way (NULL) included.
     The LIABILITY line for 2-way match and the ACCRUAL-CLEARING line for
     3-way match both land on segment1='102' and are both linked via
     xdl.source_distribution_type = 'AP_INV_DIST'.
──────────────────────────────────────────────────────────────────────────*/
ap_xla AS (
    SELECT
        -- Invoice header
        aia.invoice_id,
        aia.invoice_num,
        aia.invoice_date,
        aia.invoice_amount,
        aia.invoice_currency_code,
        aia.vendor_id,
        aia.vendor_site_id,
        aia.org_id,
        aia.payment_status_flag,            -- N=Unpaid, P=Partial, Y=Fully Paid
        -- Distribution
        aid.invoice_distribution_id,
        aid.distribution_line_number,
        aid.line_type_lookup_code                AS dist_type,
        aid.amount                               AS dist_amount,
        aid.po_distribution_id,
        aid.rcv_transaction_id,
        CASE
            WHEN aid.rcv_transaction_id IS NOT NULL THEN 'RECEIPT (3-WAY)'
            WHEN aid.po_distribution_id IS NOT NULL THEN 'PO (2-WAY)'
        END                                      AS match_type,
        -- XLA header
        xah.ae_header_id,
        xah.accounting_date                      AS ap_acctg_date,
        xah.period_name                          AS ap_period_name,
        xah.je_category_name                     AS ap_je_category,
        xah.gl_transfer_status_code              AS ap_gl_transfer_status,
        xah.gl_transfer_date                     AS ap_gl_transfer_date,
        xah.accounting_entry_status_code         AS ap_xla_status,
        xah.description                          AS ap_header_desc,
        -- XLA event
        xe.event_type_code                       AS ap_event_type,
        xe.event_status_code                     AS ap_event_status,
        xe.process_status_code                   AS ap_process_status,
        -- XLA line
        xal.ae_line_num                          AS ap_ae_line_num,
        xal.accounting_class_code                AS ap_acctg_class,
        xal.gl_sl_link_table                     AS ap_sl_link_table,
        -- Amounts (unrounded from xdl — more precise than xal)
        xdl.unrounded_accounted_dr               AS ap_accounted_dr,
        xdl.unrounded_accounted_cr               AS ap_accounted_cr,
        xdl.event_class_code                     AS ap_event_class,
        xdl.source_distribution_type             AS ap_dist_xla_type,
        -- Account
        gcc.concatenated_segments                AS ap_account,
        gcc.segment1                             AS ap_segment1,
        gcc.segment2                             AS ap_segment2,
        gcc.segment3                             AS ap_segment3,
        gcc.segment4                             AS ap_segment4,
        gcc.segment5                             AS ap_segment5,
        gcc.segment6                             AS ap_segment6,
        gcc.segment7                             AS ap_segment7,
        -- Application
        fav.application_name                     AS ap_application,
        xte.entity_code                          AS ap_entity_code,
        xah.application_id                       AS ap_application_id
    FROM   apps.xla_ae_headers                xah
    JOIN   apps.xla_ae_lines                  xal
        ON  xal.ae_header_id   = xah.ae_header_id
        AND xal.application_id = xah.application_id
    JOIN   apps.xla_transaction_entities_upg  xte
        ON  xte.entity_id      = xah.entity_id
        AND xte.application_id = xah.application_id
    JOIN   apps.xla_distribution_links        xdl
        ON  xdl.ae_header_id   = xah.ae_header_id
        AND xdl.event_id       = xah.event_id
        AND xdl.ae_line_num    = xal.ae_line_num
        AND xdl.application_id = xah.application_id
    JOIN   apps.xla_events                    xe
        ON  xe.entity_id       = xte.entity_id
        AND xe.event_id        = xdl.event_id
    JOIN   apps.ap_invoice_distributions_all  aid
        ON  aid.invoice_distribution_id = xdl.source_distribution_id_num_1
    JOIN   apps.ap_invoices_all               aia
        ON  aia.invoice_id   = aid.invoice_id
        AND aia.invoice_id   = xte.source_id_int_1
        AND aia.invoice_num  = xte.transaction_number
    JOIN   apps.gl_code_combinations_kfv      gcc
        ON  gcc.code_combination_id = xal.code_combination_id
    JOIN   apps.fnd_application_vl            fav
        ON  fav.application_id = xah.application_id
    JOIN   apps.gl_ledgers                    gl
        ON  gl.ledger_id       = xah.ledger_id
    JOIN   apps.gl_periods                    gp
        ON  gp.period_set_name        = gl.period_set_name
        AND gp.period_name            = 'APR-26'
        AND gp.adjustment_period_flag = 'N'
    WHERE  fav.application_name              = 'Payables'
    AND    xdl.source_distribution_type      = 'AP_INV_DIST'
    AND    xte.entity_code                   = 'AP_INVOICES'
    AND    xal.gl_sl_link_table IN ('APECL', 'XLAJEL')
    AND    xah.ledger_id                     = 1
    AND    xah.accounting_date BETWEEN gp.start_date AND gp.end_date
    AND    gcc.segment1                      = '102'
    AND   (aid.rcv_transaction_id IS NOT NULL OR aid.po_distribution_id IS NOT NULL)
    AND    aid.line_type_lookup_code NOT IN ('AWT', 'PREPAY')
    AND    NVL(aid.reversal_flag, 'N')       = 'N'
),

/*──────────────────────────────────────────────────────────────────────────
  2. AP XLA — PO CHARGE/EXPENSE SIDE  (2-WAY MATCH ONLY)
     Application : Payables  (same application as ap_xla)
     Filter      : segment1 = '101'  — PO charge / expense account
                   rcv_transaction_id IS NULL — 2-way, no receipt
     These are the ITEM/CHARGE lines in the SAME Payables XLA event as
     the segment1='102' LIABILITY line captured in CTE 1.
     Joined in main query on ae_header_id + invoice_distribution_id.
     No separate period filter needed — implicit via ae_header_id join
     to ap_xla, but applied here for query efficiency.
──────────────────────────────────────────────────────────────────────────*/
ap_xla_2way AS (
    SELECT
        aid.invoice_distribution_id,
        xah.ae_header_id,
        xah.accounting_date                      AS po2_acctg_date,
        xah.period_name                          AS po2_period_name,
        xah.je_category_name                     AS po2_je_category,
        xah.gl_transfer_status_code              AS po2_gl_transfer_status,
        xah.gl_transfer_date                     AS po2_gl_transfer_date,
        xah.accounting_entry_status_code         AS po2_xla_status,
        xe.event_type_code                       AS po2_event_type,
        xe.event_status_code                     AS po2_event_status,
        xe.process_status_code                   AS po2_process_status,
        xal.ae_line_num                          AS po2_ae_line_num,
        xal.accounting_class_code                AS po2_acctg_class,
        xdl.unrounded_accounted_dr               AS po2_accounted_dr,
        xdl.unrounded_accounted_cr               AS po2_accounted_cr,
        xdl.event_class_code                     AS po2_event_class,
        gcc.concatenated_segments                AS po2_account,
        gcc.segment1                             AS po2_segment1,
        gcc.segment2                             AS po2_segment2,
        gcc.segment3                             AS po2_segment3,
        gcc.segment4                             AS po2_segment4,
        gcc.segment5                             AS po2_segment5,
        gcc.segment6                             AS po2_segment6,
        gcc.segment7                             AS po2_segment7,
        fav.application_name                     AS po2_application
    FROM   apps.xla_ae_headers                xah
    JOIN   apps.xla_ae_lines                  xal
        ON  xal.ae_header_id   = xah.ae_header_id
        AND xal.application_id = xah.application_id
    JOIN   apps.xla_transaction_entities_upg  xte
        ON  xte.entity_id      = xah.entity_id
        AND xte.application_id = xah.application_id
    JOIN   apps.xla_distribution_links        xdl
        ON  xdl.ae_header_id   = xah.ae_header_id
        AND xdl.event_id       = xah.event_id
        AND xdl.ae_line_num    = xal.ae_line_num
        AND xdl.application_id = xah.application_id
    JOIN   apps.xla_events                    xe
        ON  xe.entity_id       = xte.entity_id
        AND xe.event_id        = xdl.event_id
    JOIN   apps.ap_invoice_distributions_all  aid
        ON  aid.invoice_distribution_id = xdl.source_distribution_id_num_1
        AND aid.rcv_transaction_id IS NULL          -- 2-way only: no receipt
    JOIN   apps.ap_invoices_all               aia
        ON  aia.invoice_id   = aid.invoice_id
        AND aia.invoice_id   = xte.source_id_int_1
        AND aia.invoice_num  = xte.transaction_number
    JOIN   apps.gl_code_combinations_kfv      gcc
        ON  gcc.code_combination_id = xal.code_combination_id
    JOIN   apps.fnd_application_vl            fav
        ON  fav.application_id = xah.application_id
    JOIN   apps.gl_ledgers                    gl
        ON  gl.ledger_id       = xah.ledger_id
    JOIN   apps.gl_periods                    gp
        ON  gp.period_set_name        = gl.period_set_name
        AND gp.period_name            = 'APR-26'
        AND gp.adjustment_period_flag = 'N'
    WHERE  fav.application_name              = 'Payables'
    AND    xdl.source_distribution_type      = 'AP_INV_DIST'
    AND    xte.entity_code                   = 'AP_INVOICES'
    AND    xal.gl_sl_link_table IN ('APECL', 'XLAJEL')
    AND    xah.ledger_id                     = 1
    AND    xah.accounting_date BETWEEN gp.start_date AND gp.end_date
    AND    gcc.segment1                      = '101'
    AND    aid.line_type_lookup_code NOT IN ('AWT', 'PREPAY')
    AND    NVL(aid.reversal_flag, 'N')       = 'N'
),

/*──────────────────────────────────────────────────────────────────────────
  3. RECEIPT (COST MANAGEMENT) XLA LINES  —  segment1 = '101'
     Application : Cost Management
     Filter      : je_category = 'Receiving', je_source = 'Purchasing'
     No period restriction — receipt may pre-date the invoice period.
     Link to AP  : rrsl.rcv_transaction_id = aid.rcv_transaction_id (main query)
     Link to XTE : xte.SOURCE_ID_INT_2 = rrsl.accounting_event_id  (NOT int_1)
──────────────────────────────────────────────────────────────────────────*/
rcv_xla AS (
    SELECT
        rrsl.rcv_transaction_id,
        TO_NUMBER(rrsl.reference3)               AS rcv_po_distribution_id,
        TO_NUMBER(rrsl.reference2)               AS rcv_po_header_id,
        rt.receipt_num,
        rt.receipt_date,
        xah.ae_header_id                         AS rcv_ae_header_id,
        xah.accounting_date                      AS rcv_acctg_date,
        xah.period_name                          AS rcv_period_name,
        xah.je_category_name                     AS rcv_je_category,
        xah.gl_transfer_status_code              AS rcv_gl_transfer_status,
        xah.gl_transfer_date                     AS rcv_gl_transfer_date,
        xah.accounting_entry_status_code         AS rcv_xla_status,
        xah.description                          AS rcv_header_desc,
        xe.event_type_code                       AS rcv_event_type,
        xe.event_status_code                     AS rcv_event_status,
        xe.process_status_code                   AS rcv_process_status,
        xal.ae_line_num                          AS rcv_ae_line_num,
        xal.accounting_class_code                AS rcv_acctg_class,
        xdl.unrounded_accounted_dr               AS rcv_accounted_dr,
        xdl.unrounded_accounted_cr               AS rcv_accounted_cr,
        xdl.event_class_code                     AS rcv_event_class,
        xdl.source_distribution_type             AS rcv_dist_xla_type,
        gcc.concatenated_segments                AS rcv_account,
        gcc.segment1                             AS rcv_segment1,
        gcc.segment2                             AS rcv_segment2,
        gcc.segment3                             AS rcv_segment3,
        gcc.segment4                             AS rcv_segment4,
        gcc.segment5                             AS rcv_segment5,
        gcc.segment6                             AS rcv_segment6,
        gcc.segment7                             AS rcv_segment7,
        fav.application_name                     AS rcv_application,
        xte.entity_code                          AS rcv_entity_code,
        xah.application_id                       AS rcv_application_id
    FROM   apps.xla_ae_headers                xah
    JOIN   apps.xla_ae_lines                  xal
        ON  xal.ae_header_id   = xah.ae_header_id
        AND xal.application_id = xah.application_id
    JOIN   apps.xla_transaction_entities_upg  xte
        ON  xte.entity_id      = xah.entity_id
        AND xte.application_id = xah.application_id
    JOIN   apps.xla_distribution_links        xdl
        ON  xdl.ae_header_id   = xah.ae_header_id
        AND xdl.event_id       = xah.event_id
        AND xdl.ae_line_num    = xal.ae_line_num
        AND xdl.application_id = xah.application_id
    JOIN   apps.xla_events                    xe
        ON  xe.entity_id       = xte.entity_id
        AND xe.event_id        = xdl.event_id
    JOIN   apps.RCV_RECEIVING_SUB_LEDGER      rrsl
        ON  rrsl.rcv_sub_ledger_id   = xdl.source_distribution_id_num_1
        AND rrsl.accounting_event_id = xte.source_id_int_2     -- int_2, not int_1
    JOIN   apps.RCV_VRC_TXS_VENDINT_V         rt
        ON  rt.transaction_id        = rrsl.rcv_transaction_id
    JOIN   apps.gl_code_combinations_kfv      gcc
        ON  gcc.code_combination_id  = xal.code_combination_id
    JOIN   apps.fnd_application_vl            fav
        ON  fav.application_id       = xah.application_id
    JOIN   apps.gl_ledgers                    gl
        ON  gl.ledger_id             = xah.ledger_id
    WHERE  fav.application_name              = 'Cost Management'
    AND    xdl.source_distribution_type      = 'RCV_RECEIVING_SUB_LEDGER'
    AND    xah.je_category_name              = 'Receiving'
    AND    rrsl.je_source_name               = 'Purchasing'
    AND    xah.ledger_id                     = 1
    AND    rrsl.set_of_books_id              = 1
    AND    rrsl.chart_of_accounts_id         = gl.chart_of_accounts_id
    AND    gcc.segment1                      = '101'
),

/*──────────────────────────────────────────────────────────────────────────
  4. PO HEADER / LINE / SHIPMENT / DISTRIBUTION DETAIL
     Joined twice in main query:
       pd       — direct: ax.po_distribution_id (2-way match + most 3-way)
       pd_rcv   — via RRSL.reference3 (edge case 3-way where AP dist has
                  no direct po_distribution_id but receipt links to PO)
──────────────────────────────────────────────────────────────────────────*/
po_detail AS (
    SELECT
        pod.po_distribution_id,
        pha.segment1                             AS po_number,
        pla.line_num                             AS po_line_num,
        pla.item_description                     AS po_item_desc,
        plla.shipment_num                        AS po_shipment_num,
        pod.distribution_num                     AS po_dist_num,
        pod.destination_type_code,
        pod.destination_organization_id,
        pod.code_combination_id                  AS po_charge_account_ccid,
        pod.accrual_account_id,
        plla.receipt_required_flag,
        plla.accrue_on_receipt_flag,
        plla.quantity_billed,
        plla.quantity                                    AS quantity_ordered,
        plla.amount_billed,
        plla.amount                                      AS amount_ordered
    FROM   apps.po_distributions_all    pod
    JOIN   apps.po_line_locations_all   plla
        ON  plla.line_location_id = pod.line_location_id
    JOIN   apps.po_lines_all            pla
        ON  pla.po_line_id        = plla.po_line_id
        AND pla.po_header_id      = plla.po_header_id
    JOIN   apps.po_headers_all          pha
        ON  pha.po_header_id      = pod.po_header_id
)

/*════════════════════════════════════════════════════════════════════════════
  MAIN SELECT
  ─────────────────────────────────────────────────────────────────────────
  Grain: AP distribution × AP XLA line (seg1=102) × PO/RCV XLA line (seg1=101)

  PO_RCV_SOURCE column shows which path applied:
    'COST_MGMT (3-WAY)' — receipt exists; RCV XLA from Cost Management
    'PAYABLES (2-WAY)'  — no receipt; PO charge line from Payables XLA

  Both sides must exist → only rows with the '101' counter-entry appear.

  Key filtering columns for analysis:
    AP_SEGMENT1   — should be '102' for all rows
    PO_RCV_SEG1   — should be '101' for all rows; confirm with filter
    MATCH_TYPE     — 'RECEIPT (3-WAY)' or 'PO (2-WAY)'
════════════════════════════════════════════════════════════════════════════*/
SELECT
    -- ── Supplier ─────────────────────────────────────────────────────────
    sup.vendor_name                                               AS supplier_name,
    ss.vendor_site_code                                           AS supplier_site,

    -- ── Invoice Header ────────────────────────────────────────────────────
    ax.invoice_num,
    ax.invoice_date,
    ax.invoice_amount,
    ax.invoice_currency_code,
    ax.org_id,

    -- ── AP Distribution ───────────────────────────────────────────────────
    ax.invoice_distribution_id,
    ax.distribution_line_number                                   AS dist_line_num,
    ax.dist_type,
    ax.dist_amount,
    ax.match_type,

    -- ── Match source indicator ────────────────────────────────────────────
    CASE
        WHEN rx.rcv_transaction_id IS NOT NULL  THEN 'COST_MGMT (3-WAY)'
        WHEN p2.invoice_distribution_id IS NOT NULL THEN 'PAYABLES (2-WAY)'
    END                                                           AS po_rcv_source,

    -- ── PO Reference ──────────────────────────────────────────────────────
    -- Direct from AP dist; falls back via RRSL.reference3 for 3-way edge case
    NVL(pd.po_number,       pd_rcv.po_number)                    AS po_number,
    NVL(pd.po_line_num,     pd_rcv.po_line_num)                  AS po_line_num,
    NVL(pd.po_shipment_num, pd_rcv.po_shipment_num)              AS po_shipment_num,
    NVL(pd.po_dist_num,     pd_rcv.po_dist_num)                  AS po_dist_num,
    NVL(pd.po_item_desc,    pd_rcv.po_item_desc)                 AS po_item_desc,
    NVL(pd.receipt_required_flag, pd_rcv.receipt_required_flag)  AS receipt_required_flag,
    NVL(pd.accrue_on_receipt_flag,pd_rcv.accrue_on_receipt_flag) AS accrue_on_receipt_flag,

    -- ── Receipt (3-way only; NULL for 2-way) ─────────────────────────────
    rx.receipt_num,
    rx.receipt_date,

    -- ═══════════════════════════════════════════════════════════════════════
    -- AP XLA SIDE  —  segment1 = '102'
    -- ═══════════════════════════════════════════════════════════════════════
    ax.ap_acctg_date,
    ax.ap_period_name,
    ax.ap_je_category,
    ax.ap_event_type,
    ax.ap_event_class,
    ax.ap_ae_line_num,
    ax.ap_acctg_class,
    ax.ap_account,
    ax.ap_segment1,
    ax.ap_segment2,
    ax.ap_segment3,
    ax.ap_segment4,
    ax.ap_segment5,
    ax.ap_segment6,
    ax.ap_segment7,
    ax.ap_accounted_dr,
    ax.ap_accounted_cr,
    (NVL(ax.ap_accounted_dr, 0) - NVL(ax.ap_accounted_cr, 0))   AS ap_gl_net,
    ax.ap_gl_transfer_status,
    ax.ap_gl_transfer_date,
    ax.ap_xla_status,
    ax.ap_event_status,
    ax.ap_process_status,
    ax.ap_application,

    -- ═══════════════════════════════════════════════════════════════════════
    -- PO / RECEIPT XLA SIDE  —  segment1 = '101'
    -- 3-way → Cost Management RCV columns (rx.*)
    -- 2-way → Payables charge/expense columns (p2.*)
    -- ═══════════════════════════════════════════════════════════════════════
    COALESCE(rx.rcv_acctg_date,          p2.po2_acctg_date)      AS po_rcv_acctg_date,
    COALESCE(rx.rcv_period_name,         p2.po2_period_name)     AS po_rcv_period_name,
    COALESCE(rx.rcv_je_category,         p2.po2_je_category)     AS po_rcv_je_category,
    COALESCE(rx.rcv_event_type,          p2.po2_event_type)      AS po_rcv_event_type,
    COALESCE(rx.rcv_event_class,         p2.po2_event_class)     AS po_rcv_event_class,
    COALESCE(rx.rcv_ae_line_num,         p2.po2_ae_line_num)     AS po_rcv_ae_line_num,
    COALESCE(rx.rcv_acctg_class,         p2.po2_acctg_class)     AS po_rcv_acctg_class,
    COALESCE(rx.rcv_account,             p2.po2_account)         AS po_rcv_account,
    COALESCE(rx.rcv_segment1,            p2.po2_segment1)        AS po_rcv_seg1,
    COALESCE(rx.rcv_segment2,            p2.po2_segment2)        AS po_rcv_seg2,
    COALESCE(rx.rcv_segment3,            p2.po2_segment3)        AS po_rcv_seg3,
    COALESCE(rx.rcv_segment4,            p2.po2_segment4)        AS po_rcv_seg4,
    COALESCE(rx.rcv_segment5,            p2.po2_segment5)        AS po_rcv_seg5,
    COALESCE(rx.rcv_segment6,            p2.po2_segment6)        AS po_rcv_seg6,
    COALESCE(rx.rcv_segment7,            p2.po2_segment7)        AS po_rcv_seg7,
    COALESCE(rx.rcv_accounted_dr,        p2.po2_accounted_dr)    AS po_rcv_accounted_dr,
    COALESCE(rx.rcv_accounted_cr,        p2.po2_accounted_cr)    AS po_rcv_accounted_cr,
    ( NVL(COALESCE(rx.rcv_accounted_dr,  p2.po2_accounted_dr), 0)
    - NVL(COALESCE(rx.rcv_accounted_cr,  p2.po2_accounted_cr), 0)) AS po_rcv_gl_net,
    COALESCE(rx.rcv_gl_transfer_status,  p2.po2_gl_transfer_status) AS po_rcv_gl_transfer_status,
    COALESCE(rx.rcv_gl_transfer_date,    p2.po2_gl_transfer_date)   AS po_rcv_gl_transfer_date,
    COALESCE(rx.rcv_xla_status,          p2.po2_xla_status)      AS po_rcv_xla_status,
    COALESCE(rx.rcv_event_status,        p2.po2_event_status)    AS po_rcv_event_status,
    COALESCE(rx.rcv_process_status,      p2.po2_process_status)  AS po_rcv_process_status,
    COALESCE(rx.rcv_application,         p2.po2_application)     AS po_rcv_application

FROM   ap_xla                                   ax

-- Supplier
JOIN   apps.ap_suppliers                        sup
    ON  sup.vendor_id      = ax.vendor_id
JOIN   apps.ap_supplier_sites_all               ss
    ON  ss.vendor_id       = ax.vendor_id
    AND ss.vendor_site_id  = ax.vendor_site_id

-- ── 3-WAY: RCV / Cost Management XLA (segment1='101') ────────────────────
LEFT JOIN rcv_xla                               rx
    ON  rx.rcv_transaction_id = ax.rcv_transaction_id

-- ── 2-WAY: AP charge/expense XLA line (segment1='101', same Payables event)
LEFT JOIN ap_xla_2way                           p2
    ON  p2.ae_header_id             = ax.ae_header_id
    AND p2.invoice_distribution_id  = ax.invoice_distribution_id
    AND ax.rcv_transaction_id IS NULL           -- only activate for 2-way rows

-- ── PO detail path 1: direct po_distribution_id on AP dist ───────────────
LEFT JOIN po_detail                             pd
    ON  pd.po_distribution_id = ax.po_distribution_id

-- ── PO detail path 2: via RRSL.reference3 (3-way edge case) ──────────────
LEFT JOIN po_detail                             pd_rcv
    ON  pd_rcv.po_distribution_id = rx.rcv_po_distribution_id
    AND ax.po_distribution_id IS NULL

-- ── BOTH XLA sides (102 AP + 101 PO/RCV) must exist ─────────────────────
WHERE (   rx.rcv_transaction_id     IS NOT NULL   -- 3-way path satisfied
       OR p2.invoice_distribution_id IS NOT NULL ) -- 2-way path satisfied

-- ── Exclude fully paid invoices (nothing open on the AP side) ─────────────
AND ax.payment_status_flag != 'Y'

-- ── Exclude fully invoiced PO shipments (qty_billed >= qty_ordered) ────────
-- Partial invoices (qty_billed < qty_ordered) still appear.
-- Amount-based service lines (quantity_ordered IS NULL) are not excluded here;
-- add a similar NVL(amount_billed,0) >= NVL(amount_ordered,0) check if needed.
AND NOT (
       NVL(NVL(pd.quantity_ordered, pd_rcv.quantity_ordered), 0) > 0
   AND NVL(NVL(pd.quantity_billed,  pd_rcv.quantity_billed),  0)
           >= NVL(NVL(pd.quantity_ordered, pd_rcv.quantity_ordered), 0)
)

ORDER BY
    sup.vendor_name,
    ax.invoice_num,
    ax.distribution_line_number,
    ax.ap_ae_line_num,
    COALESCE(rx.rcv_ae_line_num, p2.po2_ae_line_num)
;

