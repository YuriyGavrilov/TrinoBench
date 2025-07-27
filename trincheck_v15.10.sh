#!/bin/bash

# =============================================================================
# TrinoBench v15.10 - Enhanced Trino Performance Testing Tool
# =============================================================================
# Major improvements:
# 1. Corrected Iceberg metadata extraction using element_at and TRY_CAST for numerical properties.
# 2. Implemented retry mechanism for trino-cli queries (on transient errors).
# 3. Suppressed "WARNING: Unable to create a system terminal" messages.
# 4. Improved table existence check.
# 5. Enhanced error handling and detailed logging.
# 6. FIXED: Re-added missing 'table_row_count' function and ensured correct function order.
# 7. FIXED: Corrected syntax error (missing 'fi' and incorrect bracket) in 'get_available_scale_factors'.
# =============================================================================

# ----------------------------
# Global Settings
# ----------------------------
TRINO_HOST="http://localhost:8880"
TRINO_USER="trino"
TRINO_PASSWORD=""
RESULTS_FILE="benchmark_results.csv"
LOG_FILE="benchmark.log"
TPCDS_CATALOG="tpcds" # Source catalog for initial data
QUERIES_DIR="queries"
MAX_RETRIES=3        # Max attempts for query execution on retriable errors
PATTERN="i_bench_"   # Default pattern for catalog selection
QUERY_TIMEOUT=1800   # Query timeout in seconds (not directly enforced by CLI, but for conceptual understanding)
DEBUG_MODE=false

# --- Ensure JAVA_HOME is set for trino-cli -----------------------------
# This block is crucial for trino-cli to work, especially on macOS.
if [[ -z "${JAVA_HOME}" ]]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if [[ -x "/usr/libexec/java_home" ]]; then
            export JAVA_HOME=$(/usr/libexec/java_home)
            if $DEBUG_MODE; then
                # Log to file, avoid tee for debug unless explicit
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: JAVA_HOME set to: $JAVA_HOME (via /usr/libexec/java_home)" >> "$LOG_FILE"
            fi
        fi
    fi
fi

if [[ -z "${JAVA_HOME}" ]]; then
    echo -e "\033[31m[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:\033[0m JAVA_HOME environment variable is not set. trino-cli might fail to launch." | tee -a "$LOG_FILE"
    echo -e "\033[31m[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:\033[0m Please ensure JAVA_HOME points to your JDK installation." | tee -a "$LOG_FILE"
    # Do NOT exit here, let test_trino_connection handle the CLI failure later.
fi
# -----------------------------------------------------------------------------

# ----------------------------
# Logging and Utility Functions
# ----------------------------
log() {
    local msg="$1"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    # Use tee for all messages to ensure they go to stdout/stderr AND log file
    echo -e "\033[32m[$timestamp]\033[0m $msg" | tee -a "$LOG_FILE"
}

error() {
    local msg="$1"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "\033[31m[$timestamp] ERROR:\033[0m $msg" | tee -a "$LOG_FILE" >&2 # Send errors to stderr
}

debug() {
    if $DEBUG_MODE; then
        local msg="$1"
        local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
        # Debug messages only go to log file by default, unless using tee for special cases
        echo -e "\033[33m[$timestamp] DEBUG:\033[0m $msg" >> "$LOG_FILE"
    fi
}

get_timestamp_ms() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # 'gdate' for macOS is from coreutils (brew install coreutils)
        # falling back to perl for milliseconds if gdate is not available
        if command -v gdate &> /dev/null; then
            printf "%d\n" "$(gdate +%s%3N)"
        else
            perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'
        fi
    else
        # For Linux/other Unix-like, 'date +%s%3N' is standard
        date +%s%3N
    fi
}

# Test Trino connection and CLI availability
test_trino_connection() {
    log "Performing Trino connection and CLI tests..."
    
    if ! command -v curl &> /dev/null; then
        error "Error: 'curl' command not found. Please install curl to enable HTTP endpoint checks."
        return 1
    fi

    local http_status=$(curl -s -o /dev/null -w "%{http_code}" "$TRINO_HOST/v1/info" 2>/dev/null)
    debug "HTTP status for $TRINO_HOST/v1/info: $http_status"
    
    if [[ "$http_status" != "200" ]]; then
        error "Error: Trino HTTP endpoint ($TRINO_HOST/v1/info) not accessible. HTTP status: $http_status."
        return 1
    fi
    
    if ! command -v trino-cli &> /dev/null; then
        error "Error: 'trino-cli' command not found. Please ensure it's installed and in your system's PATH."
        return 1
    fi

    debug "Attempting basic query with trino-cli for connection test..."
    local test_output_full=""
    local cli_cmd_base=(trino-cli --server "$TRINO_HOST" --user "$TRINO_USER" --output-format TSV)

    local password_export=""
    if [[ -n "$TRINO_PASSWORD" ]]; then
        password_export="TRINO_PASSWORD=$TRINO_PASSWORD" # No need to escape if using single quotes below
        cli_cmd_base+=(--password)
    fi

    # Suppress terminal warning for this specific test
    test_output_full=$( eval "$password_export" TERM=dumb "${cli_cmd_base[@]}" <<< "SHOW CATALOGS" 2>&1 | \
                         awk '!/WARNING: Unable to create a system terminal/' )
    local cli_exit_code=$?
    
    debug "trino-cli test command exit code: $cli_exit_code"
    debug "trino-cli test command output (stdout+stderr): $test_output_full"

    if [[ "$cli_exit_code" -ne 0 ]]; then
        error "Error: 'trino-cli' failed to execute a basic 'SHOW CATALOGS' query. Exit code: $cli_exit_code"
        error "CLI output contains (filtered): $test_output_full"
        error "Please check Trino server status, user credentials, and network connectivity."
        error "Also ensure JAVA_HOME is correctly set for the script's environment if CLI issues persist."
        return 1
    fi
    
    log "Trino connection and CLI test successful."
    return 0
}

# trino_query: Executes a Trino CLI query with retries and output filtering.
trino_query() {
    local query="$1"
    local catalog="${2:-}"
    local schema="${3:-}"
    
    local cmd_parts=(trino-cli --server "$TRINO_HOST" --user "$TRINO_USER" --output-format TSV)
    
    local password_export=""
    if [[ -n "$TRINO_PASSWORD" ]]; then
        local esc_password="${TRINO_PASSWORD//\'/\'\\\'\'}" # Escape single quotes for bash eval
        password_export="TRINO_PASSWORD='$esc_password'"
        cmd_parts+=(--password)
    fi
    
    [[ -n "$catalog" ]] && cmd_parts+=(--catalog "$catalog")
    [[ -n "$schema" ]] && cmd_parts+=(--schema "$schema")

    local attempt=0
    local exit_code=1 # Initialize with a failed state
    local raw_output=""
    local filtered_output=""
    
    while [[ $attempt -lt $MAX_RETRIES ]]; do
        attempt=$((attempt + 1))
        # Log query short form and attempt number to debug log
        debug "Executing query (first 100 chars): ${query:0:100}... (Attempt ${attempt}/${MAX_RETRIES})"
        debug "Full trino-cli command (eval portion): eval $password_export TERM=dumb ${cmd_parts[@]} <<< '$query'"
        
        # Execute command. CRITICAL: TERM=dumb and 2>&1 AFTER eval, BEFORE the pipe
        # This sends all stdout and stderr to the pipe, which awk then processes.
        raw_output=$( eval "$password_export" TERM=dumb "${cmd_parts[@]}" <<< "$query" 2>&1 )
        exit_code=$?
        
        # Filter common Trino CLI startup/info messages and the terminal warning using awk
        filtered_output=$(echo "$raw_output" | awk '
            !/^\s*$/ && 
            !/org\.jline\.utils\.Log/ && 
            !/^Query/ && 
            !/^For more information/ && 
            !/^Trino CLI version/ && 
            !/^Connected to/ && 
            !/^To learn more about Trino/ && 
            !/^CREATE TABLE: [0-9]+ rows/ && # Filter this specific message from CTAS
            !/^(\.\.\.|---)/ && # Filter separator lines like '---' or '...' in formatted output
            !/WARNING: Unable to create a system terminal/ { print } # Suppress annoying terminal warning
        ')
        
        # Finally, remove ALL double quotes (") which Trino CLI sometimes adds around values (even numbers) in TSV
        # This is CRUCIAL for numbers to be recognized. This must be the LAST filter after awk.
        filtered_output=$(echo "$filtered_output" | sed 's/"//g')

        debug "Raw trino-cli output lines: $(echo "$raw_output" | wc -l)"
        debug "Filtered trino-cli output lines: $(echo "$filtered_output" | wc -l). Exit code: $exit_code"
        
        if [[ $exit_code -eq 0 ]]; then
            debug "Query successful on attempt ${attempt}."
            echo "$filtered_output"
            return 0 # Success, exit function
        else
            error "Query failed on attempt ${attempt} with exit code: $exit_code."
            error "CLI Output (raw, possibly with warnings/errors):"
            echo "$raw_output" | while IFS= read -r line; do error "  $line"; done # Log raw output for debugging errors

            # Check if it's a specific 'Task not accessed' error that should be retried
            if echo "$raw_output" | grep -q "Task .* has not been accessed since"; then
                error "Detected 'Task not accessed' error. Retrying in 5 seconds..."
                debug "Sleeping for 5 seconds before retry..."
                sleep 5
            else
                # For other errors (syntax, permissions, specific data issues), no point in retrying
                error "Non-retriable error detected. Not retrying."
                echo "$filtered_output" # Return whatever filtered result we got (likely empty)
                return $exit_code # Return the last known exit code
            fi
        fi
    done

    # If loop finishes, all retries failed
    error "Query failed after ${MAX_RETRIES} attempts. Last known exit code: $exit_code."
    echo "$filtered_output" # Return whatever filtered result we got (likely empty)
    return $exit_code # Return the last known exit code
}

# ----------------------------
# Data Retrieval Functions
# ----------------------------

get_compression_catalogs() {
    local catalogs_raw=$(trino_query "SHOW CATALOGS")
    if [[ $? -eq 0 && -n "$catalogs_raw" ]]; then
        # Filter by pattern and remove any quotes
        echo "$catalogs_raw" | grep -E "$PATTERN" | sed 's/^"\|"$//g'
    else
        error "Failed to retrieve catalogs list from Trino. Ensure Trino is running and accessible."
        return 1
    fi
}

get_available_scale_factors() {
    # Check if TPCDS_CATALOG exists in SHOW CATALOGS output
    local catalogs_list=$(trino_query "SHOW CATALOGS")
    if [[ $? -ne 0 || -z "$catalogs_list" || ! $(echo "$catalogs_list" | grep -q "^${TPCDS_CATALOG}$"; echo $?) -eq 0 ]]; then # Check for exact catalog name (no quotes)
        error "TPC-DS source catalog '$TPCDS_CATALOG' does not exist or is not accessible! Please ensure it's configured in Trino."
        return 1
    fi

    local schemas=$(trino_query "SHOW SCHEMAS FROM $TPCDS_CATALOG" "$TPCDS_CATALOG")
    if [[ $? -eq 0 && -n "$schemas" ]]; then
        # Filter for sfXX schemas and remove quotes
        echo "$schemas" | grep -E '^sf[0-9]+$' | sed 's/^"\|"$//g' # Assuming trino_query removed quotes
    else
        error "Failed to retrieve scale factors from $TPCDS_CATALOG. Ensure TPC-DS data is loaded into '$TPCDS_CATALOG'."
        return 1
    fi # <--- ДОБАВЛЕНО: закрывающий 'fi' для ветки 'if [[ $? -eq 0 && -n "$schemas" ]]'
}

# table_row_count (THIS FUNCTION REMAINS UNCHANGED FROM PREVIOUS SUGGESTION)
# It relies on trino_query providing a clean numeric string.
table_row_count() {
    local catalog="$1"
    local schema="$2"
    local table="$3"
    
    local result
    result=$(trino_query "SELECT count(*) FROM ${catalog}.\"${schema}\".\"${table}\"" "$catalog" "$schema")
    
    # Remove all non-numeric characters (like quotes and spaces)
    local count=$(echo "$result" | tr -cd '[:digit:]') # -c complements the set, -d deletes
    
    if [[ -n "$count" && "$count" =~ ^[0-9]+$ ]]; then # Also check that count is not empty
        echo "$count"
    else
        debug "Warning: Failed to get valid row count for $catalog.\"$schema\".$table. Raw result from trino_query: '$result'. Cleaned count: '$count'. Assuming 0."
        echo "0"
    fi
}

get_worker_count() {
    # Query to get active worker nodes (coordinator=false)
    local query="SELECT count(*) FROM system.runtime.nodes WHERE coordinator = false AND state = 'active'"
    
    local result=$(trino_query "$query" "system" "runtime") # trino_query now handles warnings/retries
    local exit_code=$?
    
    if [[ $exit_code -eq 0 && -n "$result" ]]; then
        local workers=$(echo "$result" | tr -d -c '[:digit:]') # Remove non-digits
        
        if [[ "$workers" =~ ^[0-9]+$ ]]; then
            debug "Successfully extracted worker count: $workers"
            echo "$workers"
            return 0
        fi
    else
        debug "Could not determine worker count. Raw result from trino_query: '$result' (exit code: $exit_code)"
        echo "0" # Default to 0 if unable to determine
        return 1
    fi
}

# Generates S3 path based on operation type and catalogs/schema
get_s3_path() {
    local type="$1"          # "base" for direct, "cross" for cross-copy
    local target_catalog="$2"
    local scale_factor="$3"
    local source_catalog="${4:-}" # Optional, used for "cross" type
    
    local schema_name=""

    if [[ "$type" == "base" ]]; then
        schema_name="$scale_factor"
    elif [[ "$type" == "cross" && -n "$source_catalog" ]]; then
        schema_name="${scale_factor}_from_${source_catalog}"
    else
        error "Error: Invalid input for get_s3_path type: '$type'"
        return 1
    fi

    echo "s3a://test/ice/${target_catalog}/${schema_name}"
}

# Parses a query range string into an array of query names
parse_query_range() {
    local range="$1"
    local queries=()
    
    IFS=',' read -ra parts <<< "$range"
    for part in "${parts[@]}"; do
        if [[ $part =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start_q=${BASH_REMATCH[1]}
            local end_q=${BASH_REMATCH[2]}
            if (( start_q > end_q )); then
                log "Warning: Inverted query range detected '$part', processing as $end_q-$start_q."
                local temp=$start_q; start_q=$end_q; end_q=$temp;
            fi
            for ((i=start_q; i<=end_q; i++)); do
                queries+=("q$(printf '%02d' $i)")
            done # <--- DO NOT REMOVE THIS 'done'
        elif [[ $part =~ ^[0-9]+$ ]]; then
            queries+=("q$(printf '%02d' $part)")
        else
            log "Warning: Invalid query format '$part' in range, skipping."
        fi
    done
    # Sort and get unique entries
    IFS=$'\n' sorted_queries=($(sort -u <<<"${queries[*]}"))
    unset IFS
    echo "${sorted_queries[@]}"
}

# Discover available SQL queries in the QUERIES_DIR
get_available_queries() {
    if [[ ! -d "$QUERIES_DIR" ]]; then
        error "Error: Queries directory '$QUERIES_DIR' not found. Please ensure it exists and contains .sql files."
        return 1
    fi
    
    local queries=()
    for query_file in "$QUERIES_DIR"/*.sql; do
        if [[ -f "$query_file" ]]; then
            queries+=("$(basename "$query_file" .sql)")
        fi
    done
    # Sort for consistent order
    IFS=$'\n' sorted_queries=($(sort <<<"${queries[*]}"))
    unset IFS
    echo "${sorted_queries[@]}"
}

# Counts rows from the output of trino_query (assuming TSV output of a single column/value)
count_result_rows() {
    local output="$1"
    
    if [[ -z "$output" ]]; then
        echo "0"
        return
    fi
    # Use grep -v to filter out empty lines; wc -l to count remaining lines.
    # tr -d '[:space:]' to remove any whitespace from wc output.
    local line_count=$(echo "$output" | grep -v '^[[:space:]]*$' | wc -l | tr -d '[:space:]')
    echo "$line_count"
}

# ----------------------------
# Metadata Functions (Iceberg specific)
# ----------------------------

# Retrieves a specific property from the last snapshot summary for an Iceberg table
# This function is now generalized to get any property from the 'summary' map.
get_iceberg_snapshot_property() {
    local catalog="$1"
    local schema="$2"
    local table="$3"
    local property_key="$4" # e.g., 'total-records', 'added-files-size'
    local trino_type="$5" # e.g., 'BIGINT', 'VARCHAR' - for TRY_CAST

    # Corrected method: element_at returns VARCHAR, then TRY_CAST that VARCHAR to the desired type.
    # The property_key (e.g., 'total-records') is a literal string and does not need special escaping here.
    local query="SELECT TRY_CAST(element_at(summary, '${property_key}') AS ${trino_type}) FROM \"${catalog}\".\"${schema}\".\"${table}\$snapshots\" ORDER BY committed_at DESC LIMIT 1"

    debug "Attempting to retrieve Iceberg metadata property '${property_key}' from ${catalog}.\"${schema}\".\"${table}\$snapshots\" with query: $query"
    local result
    result=$(trino_query "$query" "$catalog" "$schema")
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
      error "Failed to retrieve Iceberg metadata property '${property_key}' for ${catalog}.\"${schema}\".\"${table}\$snapshots\"."
      # The trino_query itself should have logged CLI output for the error
      echo "0" # Return 0 for numerical properties on query failure, or empty for others
      return 1 # Indicate failure
    fi

    # trino_query should already have cleaned the result (removed quotes).
    # If TRY_CAST returned NULL, 'result' will be empty or "NULL" string from trino_query.
    if [[ -z "$result" || "$result" == "NULL" ]]; then
      debug "Iceberg property '${property_key}' not found or is NULL for ${catalog}.\"${schema}\".\"${table}\$snapshots\"."
      # Return default for numerical properties, empty string for varchar/json.
      if [[ "$trino_type" == "BIGINT" ]]; then
          echo "0"
      else
          echo "" # For non-numeric types, return empty string for NULL
      fi
    else
        debug "Extracted Iceberg property '${property_key}': $result"
        echo "$result"
    fi
    return 0
}

# The `parse_iceberg_metadata` function is no longer needed as `get_iceberg_snapshot_property`
# directly returns the scalar value. Remove any calls to it.

# table_exists: Checks if a table exists in a given schema using SHOW TABLES.
table_exists() {
    local catalog="$1"
    local schema="$2"
    local table="$3"
    
    debug "Checking existence of table: ${catalog}.\"${schema}\".\"${table}\" using SHOW TABLES"

    local raw_tables_output
    # Use trino_query to get the list of tables in the schema from the specific catalog/schema
    raw_tables_output=$(trino_query "SHOW TABLES FROM ${catalog}.\"${schema}\"" "$catalog" "$schema")
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        error "Error retrieving tables for ${catalog}.\"${schema}\": SHOW TABLES query failed with exit code $exit_code."
        debug "Raw output from SHOW TABLES command (error case): $raw_tables_output"
        return 1 # Query itself failed, not just that table doesn't exist
    fi

    debug "Raw output from SHOW TABLES for ${catalog}.\"${schema}\":"
    debug "$raw_tables_output" # This output is already filtered by trino_query for warnings/info

    # trino_query should have removed outer quotes. So we match the exact table name.
    # Use grep -iq: -i for case-insensitive, -q for quiet (no output)
    if echo "$raw_tables_output" | grep -iq "^${table}$"; then
        debug "Table ${catalog}.\"${schema}\".\"${table}\" EXISTS."
        return 0 # Table exists
    else
        debug "Table ${catalog}.\"${schema}\".\"${table}\" DOES NOT EXIST."
        return 1 # Table does not exist
    fi
}

# ----------------------------
# Benchmark Core Functions
# ----------------------------

# Unified function for copying data between Trino tables
do_table_copy_operation() {
    local source_cat="$1"
    local source_sch="$2"
    local target_cat="$3"
    local target_sch="$4"
    local op_type="$5"  # "copy" for base, "cross_copy" for cross-catalog
    
    log "Starting ${op_type} operation: from ${source_cat}.\"${source_sch}\" to ${target_cat}.\"${target_sch}\""

    local tables_output=$(trino_query "SHOW TABLES FROM ${source_cat}.\"${source_sch}\"" "$source_cat" "$source_sch")
    if [[ $? -ne 0 ]]; then
        error "Failed to retrieve tables from source: ${source_cat}.\"${source_sch}\". Skipping this copy operation."
        return 1
    fi
    
    # Convert multi-line output to an array
    local tables=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && tables+=("$line")
    done <<< "$tables_output"
    
    if [[ ${#tables[@]} -eq 0 ]]; then
        log "No tables found in ${source_cat}.\"${source_sch}\" for ${op_type}."
        return 0
    fi
    
    log "Found ${#tables[@]} tables in source for ${op_type}."
    
    for table in "${tables[@]}"; do
        debug "Checking table: ${target_cat}.\"${target_sch}\".\"${table}\""
        if table_exists "$target_cat" "$target_sch" "$table"; then
            log "Skipping existing table: ${target_cat}.\"${target_sch}\".\"${table}\""
            continue
        fi
        
        log "Attempting to ${op_type} table: $table"
        local start_time=$(get_timestamp_ms)
        
        local copy_query="CREATE TABLE ${target_cat}.\"${target_sch}\".\"${table}\" AS 
                         SELECT * FROM ${source_cat}.\"${source_sch}\".\"${table}\""
        
        trino_query "$copy_query" "$target_cat" "$target_sch"
        local status=$?
        
        local end_time=$(get_timestamp_ms)
        local duration=$((end_time - start_time))
        
        if [[ $status -ne 0 ]]; then
            error "Failed to ${op_type} table $table. Duration: ${duration}ms."
            # Append error to results, operation=copy_failed
            printf "%s,%s,\"%s\",%s,%s,%d,%d,%s,%s,%s,%d,%s\n" \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$target_cat" "$target_sch" "$table" "${op_type}_failed" \
                "$duration" "0" "0" "0" "0" "$(get_worker_count)" "" >> "$RESULTS_FILE"
            continue # Continue to next table
        fi
        
        local row_count=$(table_row_count "$target_cat" "$target_sch" "$table")
        
        # Get Iceberg metadata using the improved function for exact numeric fields
        local total_records=$(get_iceberg_snapshot_property "$target_cat" "$target_sch" "$table" "total-records" "BIGINT")
        local total_files_size=$(get_iceberg_snapshot_property "$target_cat" "$target_sch" "$table" "total-files-size" "BIGINT")
        local total_data_files=$(get_iceberg_snapshot_property "$target_cat" "$target_sch" "$table" "total-data-files" "BIGINT")
        local worker_count=$(get_worker_count) # Re-fetch in case it changed over time, or just use cached for consistency

        log "${op_type} table $table completed: $row_count rows in ${duration}ms."
        log "  Iceberg Snapshot Metadata: total-records=$total_records, total-files-size=${total_files_size}B, total-data-files=$total_data_files."

        local cross_copy_info=""
        if [[ "$op_type" == "cross_copy" ]]; then
            cross_copy_info="${source_cat}->${target_cat}"
        fi

        # Write to results CSV
        printf "%s,%s,\"%s\",%s,%s,%d,%d,%d,%d,%d,%d,%s\n" \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$target_cat" "$target_sch" "$table" "$op_type" \
            "$duration" "$row_count" "$total_records" "$total_files_size" "$total_data_files" \
            "$worker_count" "$cross_copy_info" >> "$RESULTS_FILE"
    done
}

# Prepares (creates if not exists) a schema with given S3 location
prepare_schema() {
    local catalog="$1"
    local schema_name="$2"
    local s3_location="$3"

    log "Preparing schema: ${catalog}.\"${schema_name}\" at ${s3_location}"
    
    local catalog_list=$(trino_query "SHOW CATALOGS")
    if [[ $? -ne 0 || -z "$catalog_list" ]]; then
        error "Failed to get catalogs list. Cannot verify existence of catalog '$catalog'. CLI output: '$catalog_list'"
        return 1
    fi
    # Use grep for exact match after trino_query removes quotes
    if ! echo "$catalog_list" | grep -iq "^${catalog}$"; then
        error "Catalog '$catalog' does not exist! Cannot prepare schema '${schema_name}'. Available: $(echo "$catalog_list" | tr '\n' ' ')"
        return 1
    fi
    
    local schema_list=$(trino_query "SHOW SCHEMAS FROM ${catalog}" "$catalog")
    if [[ $? -ne 0 || -z "$schema_list" ]]; then
        error "Failed to get schemas from catalog '$catalog'. Cannot verify existence of schema '${schema_name}'. Raw output: ${schema_list}"
        return 1
    fi
    
    # Use grep for exact match (trino_query removed quotes)
    if ! echo "$schema_list" | grep -iq "^${schema_name}$"; then
        log "Creating schema ${catalog}.\"${schema_name}\" with location='${s3_location}'"
        local result=$(trino_query "CREATE SCHEMA ${catalog}.\"${schema_name}\" WITH (location = '${s3_location}')" "$catalog")
        if [[ $? -ne 0 ]]; then
            error "Failed to create schema ${catalog}.\"${schema_name}\" at location '${s3_location}'."
            error "Error details: $result"
            return 1
        fi
    else
        log "Schema ${catalog}.\"${schema_name}\" already exists."
    fi
    
    return 0
}

# Phase 1: Copies data from TPCDS to target catalogs
do_direct_copy_phase() {
    local target_catalog="$1"
    local scale_factor="$2"
    
    local target_schema_name="${scale_factor}"
    local s3_path=$(get_s3_path "base" "$target_catalog" "$scale_factor")
    
    if ! prepare_schema "$target_catalog" "$target_schema_name" "$s3_path"; then
        error "Failed to prepare schema for direct copy: ${target_catalog}.\"${target_schema_name}\". Skipping data copy."
        return 1
    fi
    
    do_table_copy_operation "$TPCDS_CATALOG" "$scale_factor" "$target_catalog" "$target_schema_name" "copy"
    return $?
}

# Executes benchmark queries
run_queries_phase() {
    local target_catalog="$1"
    local target_schema="$2"
    shift 2 # Shift arguments to get only the queries array
    local queries=("${@}") # Now 'queries' contains the array of query names
    
    local worker_count=$(get_worker_count)
    log "Running queries on ${target_catalog}.\"${target_schema}\" with $worker_count workers."
    
    if [[ ${#queries[@]} -eq 0 ]]; then
        log "No queries selected to run for ${target_catalog}.\"${target_schema}\"."
        return 0
    fi

    for query_name in "${queries[@]}"; do
        local query_file="$QUERIES_DIR/$query_name.sql"
        
        if [[ ! -f "$query_file" ]]; then
            error "Query file '$query_file' does not exist. Skipping query '$query_name'."
            # Record as failed in results
            printf "%s,%s,\"%s\",%s,%s,%d,%d,%s,%s,%s,%d,%s\n" \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$target_catalog" "$target_schema" "$query_name" \
                "query_file_not_found" "0" "0" "N/A" "N/A" "N/A" "$worker_count" "" >> "$RESULTS_FILE"
            continue
        fi
        
        log "Running query: $query_name"
        
        local raw_query_content
        raw_query_content=$(<"$query_file") || { error "Failed to read query file '$query_file'."; continue; }
        
        # Replace placeholders in query content
        local processed_query=$(echo "$raw_query_content" | sed \
            -e "s/\${database}/${target_catalog}/g" \
            -e "s/\${schema}/${target_schema}/g")
        
        local start_time=$(get_timestamp_ms)
        
        # Execute query for benchmarking
        local output=$(trino_query "$processed_query" "$target_catalog" "$target_schema")
        local status=$?
        
        local end_time=$(get_timestamp_ms)
        local duration=$((end_time - start_time))
        
        local rows=0
        local operation_status="query"
        
        if [[ $status -eq 0 ]]; then
            rows=$(count_result_rows "$output")
            log "Query $query_name completed: $rows rows in ${duration}ms."
        else
            operation_status="query_failed"
            error "Query $query_name failed with exit code $status. Duration: ${duration}ms."
        fi
        
        # Write to results CSV. Metadata fields (total_records, size, files) are N/A for query.
        printf "%s,%s,\"%s\",%s,%s,%d,%d,%s,%s,%s,%d,%s\n" \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$target_catalog" "$target_schema" "$query_name" \
            "$operation_status" "$duration" "$rows" "N/A" "N/A" "N/A" "$worker_count" "" >> "$RESULTS_FILE"
    done
}

# Phase 3: Performs cross-catalog data copying
do_cross_copy_phase() {
    local scale_factor="$1"
    shift # Shift scale_factor out
    local selected_catalogs=("${@}") # Now 'selected_catalogs' contains the array
    
    if [[ ${#selected_catalogs[@]} -lt 2 ]]; then
        log "Skipping cross-copy: Fewer than 2 catalogs selected. Minimum 2 needed for cross-copy operations."
        return 0
    fi

    log "--- Starting cross-copy phase for scale: $scale_factor ---"
    
    for source_cat in "${selected_catalogs[@]}"; do
        for target_cat in "${selected_catalogs[@]}"; do
            if [[ "$source_cat" == "$target_cat" ]]; then
                log "Skipping self-referencing cross-copy: $source_cat (source) -> $target_cat (target)."
                continue
            fi
            
            local source_schema_name="$scale_factor" 
            # Verify source schema exists before attempting to copy from it
            local source_schemas_output=$(trino_query "SHOW SCHEMAS FROM ${source_cat}" "$source_cat")
            if [[ $? -ne 0 || ! $(echo "$source_schemas_output" | grep -iq "^${source_schema_name}$"; echo $?) -eq 0 ]]; then
                error "Source schema ${source_cat}.\"${source_schema_name}\" does not exist or is not accessible! Skipping cross-copy from here."
                continue
            fi

            local target_schema_name="${scale_factor}_from_${source_cat}" 
            local s3_path=$(get_s3_path "cross" "$target_cat" "$scale_factor" "$source_cat")
            
            if ! prepare_schema "$target_cat" "$target_schema_name" "$s3_path"; then
                error "Failed to prepare cross-copy schema: ${target_cat}.\"${target_schema_name}\". Skipping copy."
                continue
            fi

            do_table_copy_operation "$source_cat" "$source_schema_name" "$target_cat" "$target_schema_name" "cross_copy"
        done
    done
}


# ----------------------------
# Argument Parsing
# ----------------------------

usage() {
    echo "TrinoBench v15.10 - Enhanced Trino Performance Testing Tool" # Updated usage version
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -s, --scale       Scale factors (comma separated, e.g., sf1,sf10)"
    echo "  -q, --queries     Query range (e.g., 1-5,10,15-20), or 'all' for all queries"
    echo "  -c, --catalogs    Catalog names (comma separated, e.g., i_bench_gzip,i_bench_zstd)"
    echo "  -p, --pattern     Catalog pattern (regex) to filter available catalogs (default: '$PATTERN')"
    echo "  -x, --cross       Enable cross-catalog data copying and associated queries"
    echo "  -P, --password    Trino password (if required)"
    echo "  -d, --debug       Enable debug logging (very verbose)"
    echo "  -h, --help        Show this help message and exit"
    echo ""
    echo "Examples:"
    echo "  $0 -s sf1,sf10 -q 1-5,10"
    echo "  $0 -c i_bench_gzip,i_bench_zstd -x"
    echo "  $0 --scale sf100 --queries all --cross"
    echo "  $0 --debug # Test Trino connection and exit"
    exit 0
}

# Initialize variables that store parsed options
selected_scales=()
selected_queries=()
selected_catalogs=()
cross_copy_enabled=false
query_range_input=""

# Parse command-line arguments (using the original while loop structure)
while (( "$#" )); do
    case "$1" in
        -s|--scale)
            if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                IFS=',' read -ra selected_scales <<< "$2"
                shift 2
            else
                error "Error: Argument for $1 is missing or starts with '-'. See --help."
                usage
            fi
            ;;
        -q|--queries)
            if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                query_range_input="$2"
                shift 2
            else
                error "Error: Argument for $1 is missing or starts with '-'. See --help."
                usage
            fi
            ;;
        -c|--catalogs)
            if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                IFS=',' read -ra selected_catalogs <<< "$2"
                shift 2
            else
                error "Error: Argument for $1 is missing or starts with '-'. See --help."
                usage
            fi
            ;;
        -p|--pattern)
            if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                PATTERN="$2"
                shift 2
            else
                # This case means -p was provided without a value, or it was the last arg.
                # The original logic allowed this, so maintaining.
                # If you want pattern to always require an argument, remove this 'else' branch.
                log "Using default catalog pattern: '$PATTERN' (no argument provided for -p, or argument is another option)."
                shift
            fi
            ;;
        -x|--cross)
            cross_copy_enabled=true
            shift
            ;;
        -P|--password)
            if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                TRINO_PASSWORD="$2"
                shift 2
            else
                error "Error: Argument for $1 is missing or starts with '-'. See --help."
                usage
            fi
            ;;
        -d|--debug)
            DEBUG_MODE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Error: Unknown option specified: $1. See --help."
            usage
            ;;
    esac
done

# ----------------------------
# Main Script Execution Logic
# ----------------------------

main() {
    # Initialize/clear log and results files
    echo "" > "$LOG_FILE" # Clears log file
    echo "timestamp,catalog,schema,object,operation,duration_ms,rows,total_records,total_files_size,total_data_files,worker_count,cross_copy_info" > "$RESULTS_FILE"
    
    log "=== TrinoBench v15.10 Starting ===" # Updated version to 15.10
    log "---------------------------------"
    
    if ! test_trino_connection; then
        error "Critical: Trino environment check failed. Exiting."
        exit 1
    fi
 
    # Special debug mode check for quick exit after connection test
    if $DEBUG_MODE && [[ -z "$query_range_input" && ${#selected_scales[@]} -eq 0 && ${#selected_catalogs[@]} -eq 0 ]]; then
        local workers=$(get_worker_count)
        log "Debug mode: Connection test and worker count ($workers) successful. No benchmark specified, exiting."
        exit 0
    fi

    local workers=$(get_worker_count)
    if [[ "$workers" -eq 0 ]]; then
        log "Warning: Could not determine valid worker count (got 0). Proceeding with 0 for logging."
    else
        log "Detected $workers Trino workers."
    fi
    
    local available_scales_str=$(get_available_scale_factors)
    if [[ $? -ne 0 ]]; then exit 1; fi # Error already logged by get_available_scale_factors
    local available_scales=($available_scales_str)

    if [[ ${#available_scales[@]} -eq 0 ]]; then
        error "Critical: No TPC-DS scale factors (e.g., sf1) found in '$TPCDS_CATALOG' or '$TPCDS_CATALOG' itself is missing. Please load TPC-DS data."
        exit 1
    fi

    local available_catalogs_str=$(get_compression_catalogs)
    if [[ $? -ne 0 ]]; then exit 1; fi # Error already logged by get_compression_catalogs
    local available_catalogs=($available_catalogs_str)

    if [[ ${#available_catalogs[@]} -eq 0 ]]; then
        error "Critical: No target catalogs found matching pattern '$PATTERN'. Please check Trino setup or pattern."
        exit 1
    fi
    
    local available_queries_str=$(get_available_queries)
    if [[ $? -ne 0 ]]; then exit 1; fi # Error already logged by get_available_queries
    local available_queries=($available_queries_str)

    if [[ ${#available_queries[@]} -eq 0 ]]; then
        error "Critical: No .sql query files found in '$QUERIES_DIR'. Please ensure query files are present."
        exit 1
    fi

    debug "Available scale factors: ${available_scales[*]}"
    debug "Available catalogs (matching pattern '$PATTERN'): ${available_catalogs[*]}"
    debug "Available queries count: ${#available_queries[@]}"
    
    # If user didn't select scales, use all available
    if [[ ${#selected_scales[@]} -eq 0 ]]; then
        selected_scales=("${available_scales[@]}")
    fi
    
    # If user didn't select catalogs, use all available
    if [[ ${#selected_catalogs[@]} -eq 0 ]]; then
        selected_catalogs=("${available_catalogs[@]}")
    fi
    
    # Determine which queries to run
    if [[ "$query_range_input" == "all" ]]; then
        selected_queries=("${available_queries[@]}")
    elif [[ -n "$query_range_input" ]]; then
        selected_queries=($(parse_query_range "$query_range_input"))
    else
        log "No specific queries ('-q' option) or 'all' keyword selected. Queries will be skipped."
        selected_queries=() # Explicitly set to empty array if no queries will run
    fi

    # Filter selected_scales against available_scales
    local final_scales=()
    for s in "${selected_scales[@]}"; do
        if [[ " ${available_scales[*]} " =~ " $s " ]]; then
            final_scales+=("$s")
        else
            log "Warning: Selected scale factor '$s' is not available. Skipping."
        fi
    done
    selected_scales=("${final_scales[@]}")
    
    # Filter selected_catalogs against available_catalogs
    local final_catalogs=()
    for c in "${selected_catalogs[@]}"; do
        if [[ " ${available_catalogs[*]} " =~ " $c " ]]; then
            final_catalogs+=("$c")
        else
            log "Warning: Selected catalog '$c' is not available or doesn't match pattern '$PATTERN'. Skipping."
        fi
    done
    selected_catalogs=("${final_catalogs[@]}")

    # Filter selected_queries against available_queries
    local final_queries=()
    if [[ ${#selected_queries[@]} -gt 0 ]]; then
        for q in "${selected_queries[@]}"; do
            if [[ " ${available_queries[*]} " =~ " $q " ]]; then
                final_queries+=("$q")
            else
                log "Warning: Query '$q' is not available (file not found in '$QUERIES_DIR'). Skipping."
            fi
        done
        selected_queries=("${final_queries[@]}")
    fi
    
    # Final validation on what will be run
    if [[ ${#selected_scales[@]} -eq 0 ]]; then
        error "Critical: No valid scale factors selected for benchmark or found available. Exiting."
        exit 1
    fi
    if [[ ${#selected_catalogs[@]} -eq 0 ]]; then
        error "Critical: No valid target catalogs selected for benchmark or found available. Exiting."
        exit 1
    fi
    if [[ -n "$query_range_input" ]] && [[ ${#selected_queries[@]} -eq 0 ]]; then
        error "Critical: No valid queries found for the specified range '$query_range_input'. Exiting."
        exit 1
    fi
    
    log "Benchmark Configuration Summary:"
    log "  Scale factors to process: ${selected_scales[*]}"
    log "  Target Catalogs to process: ${selected_catalogs[*]}"
    log "  Queries to run: ${selected_queries[@]:-} (Total: ${#selected_queries[@]})"
    log "  Cross-copy enabled: $cross_copy_enabled"
    log "  Results will be saved to: $RESULTS_FILE"
    log "  Logs will be saved to: $LOG_FILE"
    log "---------------------------------"

    # --- Main Benchmark Loop ---
    for scale in "${selected_scales[@]}"; do
        log "\n=== Processing Scale Factor: $scale ==="
        
        log "--- Phase 1: Direct Data Copy ---"
        for catalog in "${selected_catalogs[@]}"; do
            log "Copying data to ${catalog}.${scale} from ${TPCDS_CATALOG}.${scale}."
            do_direct_copy_phase "$catalog" "$scale"
        done
        
        if [[ ${#selected_queries[@]} -gt 0 ]]; then
            log "\n--- Phase 2: Query Execution on Direct Copies ---"
            for catalog in "${selected_catalogs[@]}"; do
                log "Running queries on ${catalog}.\"${scale}\"."
                run_queries_phase "$catalog" "$scale" "${selected_queries[@]}" # Pass queries as array elements
            done
        else
            log "No queries selected to run in this phase. Skipping Phase 2 (Query Execution on Direct Copies)."
        fi
        
        if $cross_copy_enabled; then
            do_cross_copy_phase "$scale" "${selected_catalogs[@]}" # Pass catalogs as array elements
        else
            log "Skipping Phase 3 (Cross-Catalog Data Copy) as cross-copy is not enabled."
        fi

        if $cross_copy_enabled && [[ ${#selected_catalogs[@]} -ge 2 ]] && [[ ${#selected_queries[@]} -gt 0 ]]; then
            log "\n--- Phase 4: Query Execution on Cross-Copied Data ---"
            # Iterate through all possible source -> target catalog pairs
             for target_cat in "${selected_catalogs[@]}"; do
                for source_cat in "${selected_catalogs[@]}"; do
                    if [[ "$source_cat" == "$target_cat" ]]; then
                        continue # Skip if source and target are the same
                    fi
                    local cross_copy_schema="${scale}_from_${source_cat}"
                    
                    # Verify cross-copied schema actually exists before trying to query it
                    local check_cross_schema=$(trino_query "SHOW SCHEMAS FROM ${target_cat} LIKE '${cross_copy_schema}'" "${target_cat}")
                    if [[ $? -ne 0 || -z "$check_cross_schema" ]]; then
                        debug "Skipping queries on ${target_cat}.\"${cross_copy_schema}\": Schema does not exist or is not accessible."
                        continue
                    fi

                    log "Running queries on cross-copied schema ${target_cat}.\"${cross_copy_schema}\" (originally from ${source_cat})."
                    run_queries_phase "$target_cat" "$cross_copy_schema" "${selected_queries[@]}" # Pass queries as array elements
                done
            done
        else
            log "Skipping Phase 4 (Query Execution on Cross-Copied Data)."
            if ! $cross_copy_enabled; then log "  Reason: Cross-copy not enabled."; fi
            if [[ ${#selected_catalogs[@]} -lt 2 ]]; then log "  Reason: Fewer than 2 catalogs for cross-copy."; fi
            if [[ ${#selected_queries[@]} -eq 0 ]]; then log "  Reason: No queries selected."; fi
        fi

    done # End of scale factor loop
    
    log "---------------------------------"
    log "=== TrinoBench v15.10 Benchmark Completed ===" # Updated version to 15.10
    log "Results saved to: $RESULTS_FILE"
    log "Log saved to: $LOG_FILE"
    
    local total_operations=0
    local failed_operations=0
    
    if [[ -f "$RESULTS_FILE" ]]; then
        # Subtract 1 for the header row
        total_operations=$(( $(wc -l < "$RESULTS_FILE" 2>/dev/null || echo 1) - 1 )) 
        if (( total_operations < 0 )); then total_operations=0; fi # Ensure it's not negative

        # Count lines that contain "failed" in the operation column (e.g., query_failed, copy_failed)
        failed_operations=$(grep -c "failed" "$RESULTS_FILE" 2>/dev/null || echo 0)
        
        log "--- Benchmark Statistics ---"
        if (( total_operations > 0 )); then
            local success_rate_calc=$(( (total_operations - failed_operations) * 1000 / total_operations )) # Multiply by 1000 for 1 decimal place precision
            local success_rate_int=$((success_rate_calc / 10))
            local success_rate_frac=$((success_rate_calc % 10))

            log "  Total operations recorded: $total_operations"
            log "  Operations failed: $failed_operations"
            log "  Overall success rate: ${success_rate_int}.${success_rate_frac}%"
        else
            log "  No successful benchmark operations were recorded."
        fi
    else
        log "Results file '$RESULTS_FILE' not found. No statistics to display."
    fi
    log "---------------------------------"
    
    exit 0
}

# Execute main function with all command-line arguments
main "$@"