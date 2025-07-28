# TrinoBench v15.10 - Advanced Trino Performance Benchmarking Tool

GitHub release (https://github.com/YuriyGavrilov/TrinoBench/releases/tag/RC1)

## Overview

TrinoBench is a robust and flexible Bash script designed to automate performance testing for Trino (formerly PrestoSQL) clusters, focusing on Iceberg table optimization with various compression codecs and file formats. It facilitates end-to-end benchmarking, from data ingestion (copying TPC-DS datasets) to complex query execution, and provides detailed performance metrics.

This script, `trincheck_v15.10.sh`, is **Release Candidate 1**. It incorporates significant enhancements over previous iterations, including improved Trino CLI handling, robust error management, and precise metadata extraction for Iceberg tables.

https://github.com/user-attachments/assets/8e567ce4-1f0a-44b6-82f9-784e7963d78d

## Features

- **Automated Data Copying:** Seamlessly copy TPC-DS datasets from a source catalog (e.g., `tpcds`) to various target Iceberg catalogs with different compression codecs and file formats.
- **Cross-Catalog Benchmarking:** Supports copying data between different Iceberg catalogs to evaluate performance implications of inter-catalog data movement.
- **Query Execution:** Runs a customizable set of TPC-DS queries against the generated datasets to measure query performance.
- **Detailed Logging & Results:** Outputs comprehensive benchmark results to a CSV file, including execution times, row counts, and Iceberg specific metadata (records, file sizes, data files). All operations are also thoroughly logged.
- **Iceberg Metadata Extraction:** Accurately extracts `total-records`, `total-files-size`, and `total-data-files` from Iceberg snapshot summaries.
- **Robustness:** Includes retry mechanisms for transient Trino query failures and improved error handling for a more stable benchmarking experience.
- **Configurable:** Command-line arguments allow for flexible selection of scale factors, target catalogs, and specific queries to run.

## How it Works

The `trincheck_v15.10.sh` script orchestrates a series of operations to benchmark your Trino cluster:

1.  **Environment Check:** Verifies Trino server connectivity and `trino-cli` availability.
2.  **Catalog & Schema Preparation:** Dynamically creates target Iceberg schemas in specified catalogs, mapping them to S3 locations for data storage.
3.  **Data Copying (Phase 1):** Copies tables from the `tpcds` source catalog (e.g., `tpcds.sf1`) to target Iceberg catalogs (e.g., `i_bench_gzip.sf1`). This process uses `CREATE TABLE ... AS SELECT` (CTAS) statements.
    

4.  **Query Execution (Phase 2):** Runs predefined TPC-DS `.sql` queries against the directly copied Iceberg tables.
5.  **Cross-Catalog Data Copying (Phase 3 - Optional):** If enabled, copies data between the *different* target Iceberg catalogs (e.g., from `i_bench_gzip.sf1` to `i_bench_lz4.sf1_from_i_bench_gzip`). This helps evaluate cross-format/cross-compression performance.
    

6.  **Query Execution on Cross-Copied Data (Phase 4 - Optional):** Runs the same TPC-DS queries against the cross-copied datasets.

All operations, their durations, and relevant metadata are recorded in `benchmark_results.csv`.

## Prerequisites

Before running the script, ensure you have:

1.  **Trino Cluster:** A running Trino cluster (coordinator and at least one worker).
    *   **Configuration for Testing:** My tests were conducted on a setup with:
        *   **Machine:** MacBook Pro 2.9 GHz 6-core Intel Core i9, 32 GB 2400 MHz DDR4.
        *   **Trino:** Single coordinator, single worker running in Podman (24GB RAM allocated to Podman).
        *   **Catalog Backend:** JDBC database (PostgreSQL in my case) for Iceberg catalog metadata.
        *   **Object Storage:** Storj.io S3-compatible cloud storage.
        *   **Catalog Configurations:** See `docs/catalog_configs/` for examples of the `.properties` files used for the Iceberg catalogs. These point to a JDBC meta-store and Storj.io S3.
2.  **`trino-cli`:** The Trino command-line interface installed and accessible in your system's PATH.
    *   **Crucial:** Ensure `JAVA_HOME` environment variable is correctly set and pointing to a JDK installation compatible with `trino-cli`. The script will attempt to detect it on macOS, but manual setting might be necessary.
3.  **`curl`:** For HTTP endpoint checks (usually pre-installed).
4.  **TPC-DS Data:** A `tpcds` catalog configured in your Trino setup with TPC-DS data loaded (e.g., `sf1`, `sf10`, `sf100` schemas). This script uses `tpcds` as the source for copying.
5.  **Queries Directory:** A `queries/` directory containing your TPC-DS `.sql` query files (e.g., `q01.sql`, `q02.sql`).
6.  **Executable Permissions:** Make the script executable:
    ```bash
    chmod +x trincheck_v15.10.sh
    ```

## Usage

```bash
./trincheck_v15.10.sh [options (e.g. --help)]

TrinoBench v15.10 - Enhanced Trino Performance Testing Tool

Usage: ./trincheck_v15.10.sh [options]

Options:
  -s, --scale       Scale factors (comma separated, e.g., sf1,sf10)
  -q, --queries     Query range (e.g., 1-5,10,15-20), or 'all' for all queries
  -c, --catalogs    Catalog names (comma separated, e.g., i_bench_gzip,i_bench_zstd)
  -p, --pattern     Catalog pattern (regex) to filter available catalogs (default: 'i_bench_')
  -x, --cross       Enable cross-catalog data copying and associated queries
  -P, --password    Trino password (if required)
  -d, --debug       Enable debug logging (very verbose)
  -h, --help        Show this help message and exit

Examples:
  ./trincheck_v15.10.sh -s sf1,sf10 -q 1-5,10
  ./trincheck_v15.10.sh -c i_bench_gzip,i_bench_zstd -x
  ./trincheck_v15.10.sh --scale sf100 --queries all --cross
  ./trincheck_v15.10.sh --debug # Test Trino connection and exit
```
## My example

```bash
./trincheck_v15.10.sh -s sf1 -q 1-99 -c i_bench_gzip,i_bench_lz4,i_bench_none,i_bench_snappy,i_bench_zstd -p i_bench_ -x
```

## My resaults

<img width="414" height="402" alt="Table" src="https://github.com/user-attachments/assets/6c7697e4-d14f-408b-ab1b-3818fe1bf301" />

## Resaults generated by Skywork.ai
https://github.com/YuriyGavrilov/TrinoBench/blob/main/results/Analysis_of_Compression_Algorithm_Performance_Tests_in_Trino.pdf
