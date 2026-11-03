CREATE OR REPLACE PROCEDURE PLM.PUBLIC.SP_BUILD_MDM_CHANGELOG("DATABASE_NAME" VARCHAR, "SCHEMA_NAME" VARCHAR, "TABLE_NAME" VARCHAR, "CHANGELOG_DB" VARCHAR, "DELETED" BOOLEAN DEFAULT FALSE)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS '
# Version 1.4.0
# Original Build: 2025/12/09 DATA-8666 BK
# Description: This procedure takes parameters of DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, and CHANGELOG_DB 
#   to identify new or changed records in specific tables enabled for change tracking via the "CHANGELOG_FLAG"
#   in the DAF_METADATA.PUBLIC.ETL_PERSIST_LAYER_CONFIG. All new records or column level changes are 
#   captured in the MDM_CHANGELOG_TBL.
# Last Update: 2025/12/17 DATA-8514 BK - Enhancements to Changelog (Populate Change, Change %, Error handling for CHANGELOG_FLAG not enabled)
# Last Update: 2026/01/27 Bug fix BK - Update Change % to be a NUMBER not VARCHAR
# Last update: 2026/02/11 DATA-8515 GL - Adding PKs INVENTORY_ITEM_ID, FOB_ID and handle missing watermark column, variable def_metadata_table added to test changes that only lives in DEV and new column changelog_last_run to handle fake NEW recors when is the first time execution, and  new excluded columns from items table
# Last update: 2026/03/09 DATA-8516 GL - New parameter DELETE added to run process to identify deleted records in specific tables enabled for change tracking via the "CHANGELOG_FLAG" 
# Last update: 2026/04/15 DATA-8961 GL - Update when column = DELETED and NEW_VALUE = Y to RECORD_TYPE = DELETE


def run(session, DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, CHANGELOG_DB, DELETED):

    # --- Constants ---
    # Normalize params once
    DATABASE_NAME = DATABASE_NAME.upper()
    SCHEMA_NAME   = SCHEMA_NAME.upper()
    TABLE_NAME    = TABLE_NAME.upper()
    CHANGELOG_DB  = CHANGELOG_DB.upper()

    full_table_name = f"{DATABASE_NAME}.{SCHEMA_NAME}.{TABLE_NAME}"
    changelog_table = f"{CHANGELOG_DB}.{SCHEMA_NAME}.MDM_CHANGELOG_TBL"
    full_table_name_temp = f"{DATABASE_NAME}.WORKING.{TABLE_NAME}_FULL_TEMP"
    cols_to_exclude = [''LAST_UPDATE'', ''CREATED_BY'', ''CREATE_DATE'', ''UPDATE_DATE'', ''SCD_START_DATE'', ''SCD_END_DATE'', ''SCD_ACTIVE_FLAG'', ''ROW_HASH'',''LAST_UPDATE_DATE_11I'',''CREATION_DATE'',''LAST_UPDATE_DATE'']
    cols_to_exclude_change_diff = [''DISPLAY_ORDER'', ''UPDATE_USER'']
    change_expr = {}
    change_pct_expr = {}

    if CHANGELOG_DB == ''PLM'':
        def_metadata_table= ''DAF_METADATA''
    else:
        def_metadata_table= ''DAF_METADATA_DEV''

# --- Get Other Variables ---
    # Get columns from DAF Config table to populate source_system_name and watermark_col
    daf_cols = session.sql(f"""
        SELECT 
            source_info:source_system_name::string AS "source_system_name"
            ,watermark:column::string AS "watermark_column"
            ,changelog_flag AS "changelog_flag"
        	,changelog_last_run AS "changelog_last_run"
        FROM {def_metadata_table}.PUBLIC.ETL_PERSIST_LAYER_CONFIG
        WHERE persist_table_name = ''{TABLE_NAME}''
    """).collect()[0]
    source_system_name = daf_cols["source_system_name"]
    watermark_col = daf_cols["watermark_column"]
    changelog_flag = daf_cols["changelog_flag"]
    changelog_last_run = daf_cols["changelog_last_run"]

    # Handle missing watermark column - default to SCD_START_DATE
    if watermark_col is None or watermark_col == '''':
        watermark_col = ''SCD_START_DATE''

    # Ensure CHANGELOG_FLAG = TRUE, if it is not then error and exit the SP 
    if changelog_flag == False:
        alert_sql = f"""CALL SNOWALERT.PUBLIC.TEAMS_ALERT_SNOWFLAKE_TEMPLATE(
            ''Error in SP_BUILD_MDM_CHANGELOG - Changelog Flag not enabled for table'',
            ''The following table was provided as a parameter but does not have the Changelog Flag set to TRUE in ETL_PERSIST_LAYER_CONFIG table'',
            ''Alert Time'', CURRENT_TIMESTAMP(),
            ''Table To Check'', ''{full_table_name}'',
            ''Severity'', ''High'',
            ''Error Code'', ''CHANGELOG_FLAG_FALSE''
        );"""
        session.sql(alert_sql).collect()
        raise ValueError(f"Changelog Flag not enabled for table {full_table_name}")
    
       # Get max_change_date from Changelog or CHANGELOG_LAST_RUN from config, default to ''1900-01-01'' if both are null
    # Use raw cursor to bypass Snowpark schema analysis issues
    cursor = session.connection.cursor()
    changelog_last_run_sql = f"''{changelog_last_run}''" if changelog_last_run else "NULL"
    cursor.execute(f"""
        SELECT 
            COALESCE(
                GREATEST(
                    (SELECT MAX(change_date) FROM {changelog_table} WHERE table_name = ''{TABLE_NAME}''),
                    {changelog_last_run_sql}
                ),
                ''1900-01-01 00:00:00''
            ) AS max_change_date
    """)
    max_change_date = cursor.fetchone()[0]
    cursor.close()

    # --- Get Table PK ---
    # Look up table''s primary key for TABLE_PK field
    pk_df = session.sql(
        f"SHOW PRIMARY KEYS IN TABLE {full_table_name}"
    ).collect()

    # If the table does not have a PK, send an alert and exit SP
    # Otherwise set the variable
    if len(pk_df) == 0:
        alert_sql = f"""CALL SNOWALERT.PUBLIC.TEAMS_ALERT_SNOWFLAKE_TEMPLATE(
            ''Error in SP_BUILD_MDM_CHANGELOG - No PK Found for table'',
            ''Please specify a PK for the following table so it can be processed in the Changelog'',
            ''Alert Time'', CURRENT_TIMESTAMP(),
            ''Table To Check'', ''{full_table_name}'',
            ''Severity'', ''High'',
            ''Error Code'', ''NO_PK_FOUND''
        );"""
        session.sql(alert_sql).collect()
        raise ValueError(f"No primary key found for table {full_table_name}")
    table_pk_col = pk_df[0][''column_name'']
    
    # --- Set Up Column List ---
    # Get tracked columns (not the key, not in excluded, not starting with SK_ (our surrogate key))
    cols_df = session.sql(f"""
        SELECT 
            column_name
            ,data_type
        FROM {DATABASE_NAME}.INFORMATION_SCHEMA.COLUMNS
        WHERE table_schema = ''{SCHEMA_NAME}''
          AND table_name = ''{TABLE_NAME}''
          AND column_name NOT IN ({'', ''.join([f"''{c}''" for c in cols_to_exclude + [table_pk_col]])})
          AND NOT REGEXP_LIKE(column_name, ''^SK_.*'')  
    """).collect()

    # Tuple list to be used later... c = column, dt = data_type
    tracked_cols = [(row["COLUMN_NAME"], row["DATA_TYPE"]) for row in cols_df]

    # Does table have SKU? For populating SKU field (even if not the PK)
    # If SKU exists, use it directly. Otherwise, only populate SKU when the PK column itself is named ''SKU''
    has_sku = any(col == "SKU" for col, _ in tracked_cols)
    if has_sku:
        sku_expr = "CAST(SKU AS VARCHAR)"
    else:
        sku_expr = f"CASE WHEN ''{table_pk_col}'' = ''SKU'' THEN CAST({table_pk_col} AS VARCHAR) ELSE NULL END"

    ##Validates flag if SP was triggered by changelog job or deleted changelog job 
    ## If it wasn''t runs UPDATES/NEW records
    if not DELETED:
        # Build wide select of columns including old value and new value with LAG function + change/change pct expressions
        select_exprs = [table_pk_col]
        for c, dt in tracked_cols:
                # Add new value
                select_exprs.append(c)
        
                # Add old value
                select_exprs.append(f"""
                CASE
                    -- Only set PREV if there is actually a previous row to compare
                    WHEN LAG({c}) OVER (PARTITION BY {table_pk_col} ORDER BY SCD_START_DATE) IS NOT NULL
                         AND {c} IS DISTINCT FROM LAG({c}) OVER (PARTITION BY {table_pk_col} ORDER BY SCD_START_DATE)
                    THEN TO_VARCHAR(LAG({c}) OVER (PARTITION BY {table_pk_col} ORDER BY SCD_START_DATE))
                    -- If the previous row is NULL but current value is not, capture that change
                    WHEN LAG({c}) OVER (PARTITION BY {table_pk_col} ORDER BY SCD_START_DATE) IS NULL
                         AND {c} IS NOT NULL
                    THEN TO_VARCHAR(LAG({c}) OVER (PARTITION BY {table_pk_col} ORDER BY SCD_START_DATE))
                    ELSE ''NO CHANGE''
                END AS PREV_{c}
                """)

                # Build change/change percent expressions (only if the column is Numeric or Timestamp/Date, doesn''t end with _ID, and isn''t in the excluded fields)
                if c.strip().upper() in cols_to_exclude_change_diff or c.upper().endswith(''_ID''):
                        change_expr[c] = "NULL"
                        change_pct_expr[c] = "NULL" 
                elif dt.startswith(("NUMBER", "FLOAT")):
                    change_expr[c] = f"""CASE WHEN {c}::FLOAT IS NOT NULL AND PREV_{c}::FLOAT IS NOT NULL
                                    THEN TO_VARCHAR(
                                             ({c}::FLOAT) - (PREV_{c}::FLOAT)
                                         )
                                         ELSE NULL END"""
                    change_pct_expr[c] = f"""CASE WHEN ({c}::FLOAT) IS NOT NULL AND (PREV_{c}::FLOAT) IS NOT NULL
                                     AND NULLIF(PREV_{c}::FLOAT, 0) IS NOT NULL
                                THEN ROUND((({c}::FLOAT) - (PREV_{c}::FLOAT))
                                             / (PREV_{c}::FLOAT), 4)
                                ELSE NULL END"""
                elif dt.startswith("TIMESTAMP"):
                    change_expr[c] = f"""CASE WHEN {c} IS NOT NULL AND PREV_{c} IS NOT NULL
                                    THEN TO_VARCHAR(
                                             DATEDIFF(''day'',
                                                 PREV_{c},
                                                 {c}
                                             )
                                         ) || '' days''
                                    ELSE NULL END"""
                    change_pct_expr[c] = "NULL"
                elif dt.startswith("DATE"):
                    change_expr[c] = f"""CASE WHEN TRY_TO_DATE({c}) IS NOT NULL AND TRY_TO_DATE(PREV_{c}) IS NOT NULL
                                    THEN TO_VARCHAR(
                                             DATEDIFF(''day'',
                                                 TRY_TO_DATE(PREV_{c}),
                                                 TRY_TO_DATE({c})
                                             )
                                         ) || '' days''
                                    ELSE NULL END"""
                    change_pct_expr[c] = "NULL"
                else:
                    change_expr[c] = "NULL"
                    change_pct_expr[c] = "NULL"

        # Calculate record type: New (the first version of each PK) or Updated
        select_exprs.append(f"""
            CASE WHEN LAG({table_pk_col}) OVER (PARTITION BY {table_pk_col} ORDER BY SCD_START_DATE) IS NULL 
                THEN ''NEW'' 
                ELSE ''UPDATE'' 
            END AS RECORD_TYPE
            """
        )

        # Create comma separate list of the columns to use in the SELECT
        wide_select_cols = ", ".join(select_exprs)

        # --- Build SQL query ---
        # Build wide_sql of all the tracked columns, plus additional calculated fields
        # Left join on existing records so we only process new/changed records 
        wide_sql = f"""
            WITH existing_records AS (
                SELECT DISTINCT {table_pk_col} AS TABLE_PK
                FROM {changelog_table}
                WHERE table_name = ''{TABLE_NAME}''
            )
            SELECT 
                t.* 
            FROM (
                SELECT DISTINCT
                    {wide_select_cols} 
                    ,{table_pk_col} AS TABLE_PK
                            ,COALESCE({watermark_col}, CURRENT_TIMESTAMP()) AS CHANGE_DATE 
                    ,''{source_system_name}'' AS SYSTEM_OF_CHANGE
                    ,CURRENT_TIMESTAMP() AS LOAD_DATE
                    ,{watermark_col} AS WATERMARK_COL
                FROM {full_table_name}
            )t      
            LEFT JOIN existing_records e
                ON t.TABLE_PK = e.TABLE_PK
            WHERE e.TABLE_PK IS NULL                    -- Gets NEW records
                OR t.WATERMARK_COL > ''{max_change_date}''  -- Gets UPDATED records
        """
    
        # Check if there are records to load... 
        # If no records, exit the SP
        # Use raw cursor to bypass Snowpark schema analysis issues
        check_cursor = session.connection.cursor()
        check_cursor.execute(f"SELECT COUNT(*) FROM ({wide_sql}) LIMIT 1")
        row_count = check_cursor.fetchone()[0]
        check_cursor.close()
        if row_count == 0:
            return f"No new or changed PKs to load for {full_table_name}"

        # If records then continue on to unpivot... 
        # Unpivot to create one row per changed column for updates and handle new rows separately    
        unpivot_selects = []

        # Append the Updated records to track column-level changes
        for c, dt in tracked_cols:
            unpivot_selects.append(
            f"""
            SELECT DISTINCT
                CHANGELOG_SEQ.NEXTVAL AS CHANGE_ID,
                ''{TABLE_NAME}'' AS TABLE_NAME,
                ''{table_pk_col}'' AS TABLE_PK,
                CASE WHEN ''{table_pk_col}'' = ''PRODUCT_ID'' THEN CAST({table_pk_col} AS VARCHAR) ELSE NULL END AS PRODUCT_ID,
                CASE WHEN ''{table_pk_col}'' = ''ITEM_ID'' THEN CAST({table_pk_col} AS VARCHAR) ELSE NULL END AS ITEM_ID,
                {sku_expr} AS SKU,
                ''{c}'' AS COLUMN_NAME,
                TO_VARCHAR(PREV_{c}) AS OLD_VALUE,
                TO_VARCHAR({c}) AS NEW_VALUE,
                {change_expr[c]} AS CHANGE,
                {change_pct_expr[c]} AS CHANGE_PERCENT,
                RECORD_TYPE,
                CHANGE_DATE,
                SYSTEM_OF_CHANGE,
                LOAD_DATE,
                CASE WHEN ''{table_pk_col}'' = ''INVENTORY_ITEM_ID'' THEN CAST({table_pk_col} AS VARCHAR) ELSE NULL END AS INVENTORY_ITEM_ID,
                CASE WHEN ''{table_pk_col}'' = ''FOB_ID'' THEN CAST({table_pk_col} AS VARCHAR) ELSE NULL END AS FOB_ID
            FROM ({wide_sql})
            WHERE RECORD_TYPE = ''UPDATE''
               AND (PREV_{c} != ''NO CHANGE'' OR PREV_{c} IS NULL)
            """
        )

        # Append the New records to track record-level additions (column_name = ALL)
        # Skip on initial load (when max_change_date is 1900-01-01) to avoid logging all existing records as NEW
        if str(max_change_date) != ''1900-01-01 00:00:00'':
            unpivot_selects.append(
                f"""
                SELECT DISTINCT
                    CHANGELOG_SEQ.NEXTVAL AS CHANGE_ID,
                    ''{TABLE_NAME}'' AS TABLE_NAME,
                    ''{table_pk_col}'' AS TABLE_PK,
                    CASE WHEN ''{table_pk_col}'' = ''PRODUCT_ID'' THEN CAST({table_pk_col} AS VARCHAR) ELSE NULL END AS PRODUCT_ID,
                    CASE WHEN ''{table_pk_col}'' = ''ITEM_ID'' THEN CAST({table_pk_col} AS VARCHAR) ELSE NULL END AS ITEM_ID,
                    {sku_expr} AS SKU,
                    ''ALL'' AS COLUMN_NAME,
                    NULL AS OLD_VALUE,
                    NULL AS NEW_VALUE,
                    NULL AS CHANGE,
                    NULL AS CHANGE_PERCENT,
                    RECORD_TYPE,
                    CHANGE_DATE,
                    SYSTEM_OF_CHANGE,
                    LOAD_DATE,
                    CASE WHEN ''{table_pk_col}'' = ''INVENTORY_ITEM_ID'' THEN CAST({table_pk_col} AS VARCHAR) ELSE NULL END AS INVENTORY_ITEM_ID,
                    CASE WHEN ''{table_pk_col}'' = ''FOB_ID'' THEN CAST({table_pk_col} AS VARCHAR) ELSE NULL END AS FOB_ID
                FROM ({wide_sql})
                WHERE RECORD_TYPE = ''NEW''

                """
            )
    
    ## If it was runs DELETED records
    else:
        # --- Build SQL query ---
        # Build wide_sql to get records that are active in persist table and were deleted in FULL_TEMP table
        # Left join on existing records so we only process deleted records 
        extra_cols = ", SKU" if has_sku else ""
        extra_cols_select = ", t.SKU" if has_sku else ""

        wide_sql = f"""
            WITH existing_records AS (
                SELECT {table_pk_col}, {watermark_col}{extra_cols}
                FROM {full_table_name}
                WHERE scd_active_flag = TRUE            
            )
            SELECT t.{table_pk_col}
                    ,COALESCE(t.{watermark_col}, CURRENT_TIMESTAMP()) AS CHANGE_DATE 
                    ,''{source_system_name}'' AS SYSTEM_OF_CHANGE
                    ,CURRENT_TIMESTAMP() AS LOAD_DATE
                    ,t.{watermark_col} AS WATERMARK_COL
                    {extra_cols_select}
            FROM existing_records t
            LEFT JOIN {full_table_name_temp} e
                ON t.{table_pk_col} = e.{table_pk_col}
            WHERE e.{table_pk_col} IS NULL                    -- Gets DELETED records
        """

        # Check if there are records to load... 
        # If no records, exit the SP
        # Use raw cursor to bypass Snowpark schema analysis issues
        check_cursor = session.connection.cursor()
        check_cursor.execute(f"SELECT COUNT(*) FROM ({wide_sql}) LIMIT 1")
        row_count = check_cursor.fetchone()[0]
        check_cursor.close()
        if row_count == 0:
            return f"No deleted PKs to load for {full_table_name}"

        # If records then continue on to unpivot... 
     
        # Append the New records to track record-level additions (column_name = ALL) 
        unpivot_selects = []
       
        unpivot_selects.append(
                f"""
                SELECT 
                    CHANGELOG_SEQ.NEXTVAL AS CHANGE_ID,
                    ''{TABLE_NAME}'' AS TABLE_NAME,
                    ''{table_pk_col}'' AS TABLE_PK,
                    CASE WHEN ''{table_pk_col}'' = ''PRODUCT_ID'' THEN CAST({table_pk_col} AS VARCHAR) ELSE NULL END AS PRODUCT_ID,
                    CASE WHEN ''{table_pk_col}'' = ''ITEM_ID'' THEN CAST({table_pk_col} AS VARCHAR) ELSE NULL END AS ITEM_ID,
                    {sku_expr} AS SKU,
                    ''ALL'' AS COLUMN_NAME,
                    NULL AS OLD_VALUE,
                    NULL AS NEW_VALUE,
                    NULL AS CHANGE,
                    NULL AS CHANGE_PERCENT,
                    ''DELETE'' AS RECORD_TYPE,
                    CHANGE_DATE,
                    SYSTEM_OF_CHANGE,
                    LOAD_DATE,
                    CASE WHEN ''{table_pk_col}'' = ''INVENTORY_ITEM_ID'' THEN CAST({table_pk_col} AS VARCHAR) ELSE NULL END AS INVENTORY_ITEM_ID,
                    CASE WHEN ''{table_pk_col}'' = ''FOB_ID'' THEN CAST({table_pk_col} AS VARCHAR) ELSE NULL END AS FOB_ID
                FROM ({wide_sql})

                """
            )	

    # Combine into full UNION query
    unpivot_sql = f"{'' UNION ALL ''.join(unpivot_selects)}"

    # --- Load Changelog ---
    # Append to MDM_CHANGELOG_TBL 
    append_sql = f"""
        INSERT INTO {changelog_table} (
            CHANGE_ID, TABLE_NAME, TABLE_PK, PRODUCT_ID, ITEM_ID, SKU, COLUMN_NAME,
            OLD_VALUE, NEW_VALUE, CHANGE, CHANGE_PERCENT, RECORD_TYPE, CHANGE_DATE, SYSTEM_OF_CHANGE, LOAD_DATE,
            INVENTORY_ITEM_ID, FOB_ID
        )
        SELECT
            s.CHANGE_ID, s.TABLE_NAME, s.TABLE_PK, s.PRODUCT_ID, s.ITEM_ID, s.SKU, s.COLUMN_NAME,
            s.OLD_VALUE, s.NEW_VALUE, s.CHANGE, s.CHANGE_PERCENT, s.RECORD_TYPE, s.CHANGE_DATE, s.SYSTEM_OF_CHANGE, s.LOAD_DATE,
            s.INVENTORY_ITEM_ID, s.FOB_ID
        FROM ({unpivot_sql}) AS s
    """
    append_cursor = session.connection.cursor()
    append_cursor.execute(append_sql)
    insert_count = append_cursor.rowcount
    append_cursor.close()

    # Update when column = DELETED and NEW_VALUE = Y to RECORD_TYPE = DELETE 
    config_cursor = session.connection.cursor()
    config_cursor.execute(f"""
        UPDATE {changelog_table}
        SET RECORD_TYPE = ''DELETE''
        WHERE COLUMN_NAME = ''DELETED''
        AND NEW_VALUE = ''Y''
        AND RECORD_TYPE = ''UPDATE''
    """)
    config_cursor.close()  

    if DELETED:
        # Update active records in persist table to deleted
        update_cursor = session.connection.cursor()
        update_cursor.execute(f"""
            UPDATE {full_table_name} tgt SET
            tgt.deleted = true,
            tgt.scd_active_flag = false,
            tgt.scd_end_date = CURRENT_TIMESTAMP()
            FROM (
                SELECT t.{table_pk_col}
                FROM {full_table_name} t
                LEFT JOIN {full_table_name_temp} e
                    ON t.{table_pk_col} = e.{table_pk_col}
               WHERE e.{table_pk_col} IS NULL
                AND t.scd_active_flag = TRUE
            ) src
            WHERE tgt.{table_pk_col} = src.{table_pk_col}
        """)
        update_cursor.close()
        
    # Update last run timestamp in config table
    config_cursor = session.connection.cursor()
    config_cursor.execute(f"""
        UPDATE {def_metadata_table}.PUBLIC.ETL_PERSIST_LAYER_CONFIG 
        SET CHANGELOG_LAST_RUN = CURRENT_TIMESTAMP()
        WHERE persist_table_name = ''{TABLE_NAME}''
    """)
    config_cursor.close()  

    return f"Changes captured successfully for {full_table_name}. {insert_count} record(s) inserted." 
';