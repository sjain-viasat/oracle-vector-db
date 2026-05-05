/*----------------------------------------------------------------------------
  REVERSE ACCOUNT RECONCILIATION  —  APR-26, Ledger 1
  -------------------------------------------------------------------------
  Detects SWAPPED account postings:
    • Receipt (RCV XLA / Cost Management) posted to segment1 = '102'
      (normal is '101' — Receiving Accrual / Uninvoiced Receipts)
    • AP Invoice  (AP XLA  / Payables)    posted to segment1 = '101'
      (normal is '102' — AP Liability / Accrual Clearing)

  Two paths, mirroring the main query:
    A. 3-WAY:  RCV XLA on seg1='102'  ?  AP XLA on seg1='101'
    B. 2-WAY:  AP liability line on seg1='101'  ?  AP charge line on seg1='102'

  Both sides must be found (INNER-style logic in WHERE) so only true
  cross-posted pairs appear — not isolated mis-coded lines.
----------------------------------------------------------------------------*/
WITH
/*--------------------------------------------------------------------------
  1. AP XLA — segment1 = '101'  (REVERSED; normal is '102')
--------------------------------------------------------------------------*/
ap_xla_rev AS (
    SELECT
        aia.invoice_id,
        aia.invoice_num,
        aia.invoice_date,
        aia.invoice_amount,
        aia.invoice_currency_code,
        aia.payment_status_flag,
        aia.vendor_id,
        aia.vendor_site_id,
        aia.org_id,
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
        xah.ae_header_id,
        xah.accounting_date                      AS ap_acctg_date,
        xah.period_name                          AS ap_period_name,
        xah.je_category_name                     AS ap_je_category,
        xah.gl_transfer_status_code              AS ap_gl_transfer_status,
        xah.gl_transfer_date                     AS ap_gl_transfer_date,
        xah.accounting_entry_status_code         AS ap_xla_status,
        xah.description                          AS ap_header_desc,
        xe.event_type_code                       AS ap_event_type,
        xe.event_status_code                     AS ap_event_status,
        xe.process_status_code                   AS ap_process_status,
        xal.ae_line_num                          AS ap_ae_line_num,
        xal.accounting_class_code                AS ap_acctg_class,
        xdl.unrounded_accounted_dr               AS ap_accounted_dr,
        xdl.unrounded_accounted_cr               AS ap_accounted_cr,
        xdl.event_class_code                     AS ap_event_class,
        xdl.source_distribution_type             AS ap_dist_xla_type,
        gcc.concatenated_segments                AS ap_account,
        gcc.segment1                             AS ap_segment1,
        gcc.segment2                             AS ap_segment2,
        gcc.segment3                             AS ap_segment3,
        gcc.segment4                             AS ap_segment4,
        gcc.segment5                             AS ap_segment5,
        gcc.segment6                             AS ap_segment6,
        gcc.segment7                             AS ap_segment7,
        fav.application_name                     AS ap_application
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
    AND    gcc.segment1                      = '101'   -- reversed: AP hitting 101
    AND   (aid.rcv_transaction_id IS NOT NULL OR aid.po_distribution_id IS NOT NULL)
    AND    aid.line_type_lookup_code NOT IN ('AWT', 'PREPAY')
    AND    NVL(aid.reversal_flag, 'N')       = 'N'
),

/*--------------------------------------------------------------------------
  2. AP XLA 2-WAY CHARGE — segment1 = '102'  (REVERSED; normal is '101')
     The expense/charge line in a 2-way PO match that should hit '101'
     but was posted to '102' instead.
--------------------------------------------------------------------------*/
ap_xla_2way_rev AS (
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
        AND aid.rcv_transaction_id IS NULL          -- 2-way only
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
    AND    gcc.segment1                      = '102'   -- reversed: charge hitting 102
    AND    aid.line_type_lookup_code NOT IN ('AWT', 'PREPAY')
    AND    NVL(aid.reversal_flag, 'N')       = 'N'
),

/*--------------------------------------------------------------------------
  3. RCV XLA — segment1 = '102'  (REVERSED; normal is '101')
     Receipt posted to 102 instead of the Receiving Accrual account (101).
     No period restriction — receipt may pre-date the invoice period.
--------------------------------------------------------------------------*/
rcv_xla_rev AS (
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
        fav.application_name                     AS rcv_application
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
        AND rrsl.accounting_event_id = xte.source_id_int_2
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
    AND    gcc.segment1                      = '102'   -- reversed: receipt hitting 102
),

/*--------------------------------------------------------------------------
  4. PO HEADER / LINE / SHIPMENT / DISTRIBUTION DETAIL  (same as main query)
--------------------------------------------------------------------------*/
po_detail_rev AS (
    SELECT
        pod.po_distribution_id,
        pha.segment1                             AS po_number,
        pla.line_num                             AS po_line_num,
        pla.item_description                     AS po_item_desc,
        plla.shipment_num                        AS po_shipment_num,
        pod.distribution_num                     AS po_dist_num,
        pod.destination_type_code,
        plla.receipt_required_flag,
        plla.accrue_on_receipt_flag
    FROM   apps.po_distributions_all    pod
    JOIN   apps.po_line_locations_all   plla
        ON  plla.line_location_id = pod.line_location_id
    JOIN   apps.po_lines_all            pla
        ON  pla.po_line_id        = plla.po_line_id
        AND pla.po_header_id      = plla.po_header_id
    JOIN   apps.po_headers_all          pha
        ON  pha.po_header_id      = pod.po_header_id
)

/*----------------------------------------------------------------------------
  MAIN SELECT — REVERSED ACCOUNTS
  Grain: AP distribution × AP XLA line (seg1=101) × RCV/PO XLA line (seg1=102)
  Both sides must be found; isolated mis-coded lines are excluded.
  ap_segment1_actual = '101'  (wrong — should be '102')
  po_rcv_seg1_actual = '102'  (wrong — should be '101')
----------------------------------------------------------------------------*/
SELECT
    -- -- Supplier ---------------------------------------------------------
    sup.vendor_name                                               AS supplier_name,
    ss.vendor_site_code                                           AS supplier_site,

    -- -- Invoice Header ----------------------------------------------------
    ax.invoice_num,
    ax.invoice_date,
    ax.invoice_amount,
    ax.invoice_currency_code,
    ax.org_id,

    -- -- AP Distribution ---------------------------------------------------
    ax.invoice_distribution_id,
    ax.distribution_line_number                                   AS dist_line_num,
    ax.dist_type,
    ax.dist_amount,
    ax.match_type,

    -- -- Match source (reversed label) -------------------------------------
    CASE
        WHEN rx.rcv_transaction_id IS NOT NULL      THEN 'COST_MGMT (3-WAY) — ACCTS REVERSED'
        WHEN p2.invoice_distribution_id IS NOT NULL THEN 'PAYABLES (2-WAY) — ACCTS REVERSED'
    END                                                           AS po_rcv_source,

    -- -- PO Reference ------------------------------------------------------
    NVL(pd.po_number,       pd_rcv.po_number)                    AS po_number,
    NVL(pd.po_line_num,     pd_rcv.po_line_num)                  AS po_line_num,
    NVL(pd.po_shipment_num, pd_rcv.po_shipment_num)              AS po_shipment_num,
    NVL(pd.po_dist_num,     pd_rcv.po_dist_num)                  AS po_dist_num,
    NVL(pd.po_item_desc,    pd_rcv.po_item_desc)                 AS po_item_desc,
    NVL(pd.receipt_required_flag, pd_rcv.receipt_required_flag)  AS receipt_required_flag,
    NVL(pd.accrue_on_receipt_flag,pd_rcv.accrue_on_receipt_flag) AS accrue_on_receipt_flag,

    -- -- Receipt (3-way only) ----------------------------------------------
    rx.receipt_num,
    rx.receipt_date,

    -- -----------------------------------------------------------------------
    -- AP XLA SIDE  —  segment1 = '101'  (WRONG; expected '102')
    -- -----------------------------------------------------------------------
    ax.ap_acctg_date,
    ax.ap_period_name,
    ax.ap_je_category,
    ax.ap_event_type,
    ax.ap_event_class,
    ax.ap_ae_line_num,
    ax.ap_acctg_class,
    ax.ap_account,
    ax.ap_segment1                                               AS ap_segment1_actual,  -- will show '101'
    ax.ap_segment2,
    ax.ap_segment3,
    ax.ap_segment4,
    ax.ap_segment5,
    ax.ap_segment6,
    ax.ap_segment7,
    ax.ap_accounted_dr,
    ax.ap_accounted_cr,
    (NVL(ax.ap_accounted_dr, 0) - NVL(ax.ap_accounted_cr, 0))  AS ap_gl_net,
    ax.ap_gl_transfer_status,
    ax.ap_gl_transfer_date,
    ax.ap_xla_status,
    ax.ap_event_status,
    ax.ap_process_status,
    ax.ap_application,

    -- -----------------------------------------------------------------------
    -- RCV / PO XLA SIDE  —  segment1 = '102'  (WRONG; expected '101')
    -- -----------------------------------------------------------------------
    COALESCE(rx.rcv_acctg_date,          p2.po2_acctg_date)     AS po_rcv_acctg_date,
    COALESCE(rx.rcv_period_name,         p2.po2_period_name)    AS po_rcv_period_name,
    COALESCE(rx.rcv_je_category,         p2.po2_je_category)    AS po_rcv_je_category,
    COALESCE(rx.rcv_event_type,          p2.po2_event_type)     AS po_rcv_event_type,
    COALESCE(rx.rcv_event_class,         p2.po2_event_class)    AS po_rcv_event_class,
    COALESCE(rx.rcv_ae_line_num,         p2.po2_ae_line_num)    AS po_rcv_ae_line_num,
    COALESCE(rx.rcv_acctg_class,         p2.po2_acctg_class)    AS po_rcv_acctg_class,
    COALESCE(rx.rcv_account,             p2.po2_account)        AS po_rcv_account,
    COALESCE(rx.rcv_segment1,            p2.po2_segment1)       AS po_rcv_seg1_actual,  -- will show '102'
    COALESCE(rx.rcv_segment2,            p2.po2_segment2)       AS po_rcv_seg2,
    COALESCE(rx.rcv_segment3,            p2.po2_segment3)       AS po_rcv_seg3,
    COALESCE(rx.rcv_segment4,            p2.po2_segment4)       AS po_rcv_seg4,
    COALESCE(rx.rcv_segment5,            p2.po2_segment5)       AS po_rcv_seg5,
    COALESCE(rx.rcv_segment6,            p2.po2_segment6)       AS po_rcv_seg6,
    COALESCE(rx.rcv_segment7,            p2.po2_segment7)       AS po_rcv_seg7,
    COALESCE(rx.rcv_accounted_dr,        p2.po2_accounted_dr)   AS po_rcv_accounted_dr,
    COALESCE(rx.rcv_accounted_cr,        p2.po2_accounted_cr)   AS po_rcv_accounted_cr,
    ( NVL(COALESCE(rx.rcv_accounted_dr,  p2.po2_accounted_dr), 0)
    - NVL(COALESCE(rx.rcv_accounted_cr,  p2.po2_accounted_cr), 0)) AS po_rcv_gl_net,
    COALESCE(rx.rcv_gl_transfer_status,  p2.po2_gl_transfer_status) AS po_rcv_gl_transfer_status,
    COALESCE(rx.rcv_gl_transfer_date,    p2.po2_gl_transfer_date)   AS po_rcv_gl_transfer_date,
    COALESCE(rx.rcv_xla_status,          p2.po2_xla_status)     AS po_rcv_xla_status,
    COALESCE(rx.rcv_event_status,        p2.po2_event_status)   AS po_rcv_event_status,
    COALESCE(rx.rcv_process_status,      p2.po2_process_status) AS po_rcv_process_status,
    COALESCE(rx.rcv_application,         p2.po2_application)    AS po_rcv_application

FROM   ap_xla_rev                                ax

-- Supplier
JOIN   apps.ap_suppliers                         sup
    ON  sup.vendor_id      = ax.vendor_id
JOIN   apps.ap_supplier_sites_all                ss
    ON  ss.vendor_id       = ax.vendor_id
    AND ss.vendor_site_id  = ax.vendor_site_id

-- -- 3-WAY: RCV on '102' (reversed) --------------------------------------
LEFT JOIN rcv_xla_rev                            rx
    ON  rx.rcv_transaction_id = ax.rcv_transaction_id

-- -- 2-WAY: AP charge/expense on '102' (reversed), same Payables event ---
LEFT JOIN ap_xla_2way_rev                        p2
    ON  p2.ae_header_id            = ax.ae_header_id
    AND p2.invoice_distribution_id = ax.invoice_distribution_id
    AND ax.rcv_transaction_id IS NULL

-- -- PO detail path 1: direct po_distribution_id --------------------------
LEFT JOIN po_detail_rev                          pd
    ON  pd.po_distribution_id = ax.po_distribution_id

-- -- PO detail path 2: via RRSL.reference3 (3-way edge case) -------------
LEFT JOIN po_detail_rev                          pd_rcv
    ON  pd_rcv.po_distribution_id = rx.rcv_po_distribution_id
    AND ax.po_distribution_id IS NULL

-- -- Both sides must be present (reversed 101 AP + reversed 102 RCV/PO) --
WHERE (   rx.rcv_transaction_id     IS NOT NULL
       OR p2.invoice_distribution_id IS NOT NULL )

ORDER BY
    sup.vendor_name,
    ax.invoice_num,
    ax.distribution_line_number,
    ax.ap_ae_line_num,
    COALESCE(rx.rcv_ae_line_num, p2.po2_ae_line_num)
;
