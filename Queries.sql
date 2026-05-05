SELECT 
    atc.owner,
    COUNT(DISTINCT atc.table_name) AS table_count,
    COUNT(*)                       AS total_columns
FROM all_tab_columns atc
JOIN all_tables at2
    ON  at2.owner      = atc.owner
    AND at2.table_name = atc.table_name
WHERE atc.owner IN (
    'APPS','GL','AP','AR','INV','ONT','PO',
    'PA','HR','PAY','OTL','HXT','OKL','OKC',
    'FA','BOM','VSCON'
)
GROUP BY atc.owner
ORDER BY table_count DESC;


select *
from all_tables
where owner = 'GL'
and table_name not like 'XLA_GLT_%'

XLA_GLT_1109994

SELECT 
    CASE 
        WHEN table_name LIKE 'XLA_GLT_%'  THEN 'XLA Temp Tables'
        WHEN table_name LIKE 'XLA_%'       THEN 'XLA Other'
        WHEN table_name LIKE '%$%'         THEN 'System/IOT Tables'
        WHEN table_name LIKE 'SYS_%'       THEN 'System Tables'
        ELSE                                    'Real GL Tables'
    END                         AS table_category,
    COUNT(*)                    AS table_count
FROM all_tables
WHERE owner = 'GL'
GROUP BY 
    CASE 
        WHEN table_name LIKE 'XLA_GLT_%'  THEN 'XLA Temp Tables'
        WHEN table_name LIKE 'XLA_%'       THEN 'XLA Other'
        WHEN table_name LIKE '%$%'         THEN 'System/IOT Tables'
        WHEN table_name LIKE 'SYS_%'       THEN 'System Tables'
        ELSE                                    'Real GL Tables'
    END
ORDER BY table_count DESC;



SELECT 
    atc.owner,
    atc.table_name,
    atc.column_name,
    atc.data_type,
    atc.data_length,
    atc.data_precision,
    atc.nullable,
    atc.column_id,
    tcom.comments  AS table_comment,
    ccom.comments  AS column_comment
FROM all_tab_columns atc
JOIN all_tables at2
    ON  at2.owner      = atc.owner
    AND at2.table_name = atc.table_name
LEFT JOIN all_tab_comments tcom
    ON  tcom.owner      = atc.owner
    AND tcom.table_name = atc.table_name
LEFT JOIN all_col_comments ccom
    ON  ccom.owner       = atc.owner
    AND ccom.table_name  = atc.table_name
    AND ccom.column_name = atc.column_name
WHERE atc.owner IN (
    'APPS','GL','AP','AR','INV','ONT','PO',
    'PA','HR','HXT','OKL','OKC',
    'FA','BOM','VSCON'
)
AND at2.num_rows > 0
AND NOT (atc.owner = 'GL' AND atc.table_name LIKE 'XLA_GLT_%')
ORDER BY atc.owner, atc.table_name, atc.column_id;

