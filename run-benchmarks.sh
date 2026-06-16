#!/bin/bash

# Optimized Benchmark Script - Build once per app, run multiple memory configs
set -euo pipefail

# Configuration
IMAGE_NAME="web-tooling-benchmark"
RESULTS_DIR="./version_1.4_results"
FAIL_LOG="$RESULTS_DIR/failures.log"

# Memory configuration ranges (in MiB)
# Lower values added to induce more GC pressure for tuning analysis
OLD_SPACE_VALUES=(32 48 64 96 128 192 256 384 512 640 768 896 1024 1280 1536 1792 2048)
SEMI_SPACE_VALUES=(2 4 6 8 12 16 24 32 48 64 80 96 128 160 192)

# Application list
APP_VALUES=("acorn" "babel" "babel-minify" "babylon" "buble" "chai" "coffeescript" "espree" "esprima" "jshint" "lebab" "postcss" "prepack" "prettier" "source-map" "terser" "typescript" "uglify-js")

# Build Docker image
echo "Building Docker image '$IMAGE_NAME'..."
if docker build -t "$IMAGE_NAME" .; then
    echo "Docker image built successfully"
else
    echo "Failed to build Docker image"
    exit 1
fi

# Setup results directory
mkdir -p "$RESULTS_DIR"
> "$FAIL_LOG"

# Calculate statistics
TOTAL_RUNS=$((${#OLD_SPACE_VALUES[@]} * ${#SEMI_SPACE_VALUES[@]} * ${#APP_VALUES[@]}))
BUILDS_NEEDED=${#APP_VALUES[@]}

echo "=========================================="
echo "BENCHMARK EXECUTION PLAN"
echo "=========================================="
echo "Apps to test: ${#APP_VALUES[@]}"
echo "Old space configs: ${#OLD_SPACE_VALUES[@]} (${OLD_SPACE_VALUES[0]}MiB to ${OLD_SPACE_VALUES[-1]}MiB)"
echo "Semi space configs: ${#SEMI_SPACE_VALUES[@]} (${SEMI_SPACE_VALUES[0]}MiB to ${SEMI_SPACE_VALUES[-1]}MiB)"
echo "Total benchmark runs: $TOTAL_RUNS"
echo "Total builds needed: $BUILDS_NEEDED"
echo "Strategy: Build each app once, then run all memory configs"
echo "=========================================="

CURRENT_RUN=0
CURRENT_BUILD=0

# Main execution loop - iterate by app first to minimize builds
for APP in "${APP_VALUES[@]}"; do
    CURRENT_BUILD=$((CURRENT_BUILD + 1))
    echo ""
    echo "[$CURRENT_BUILD/$BUILDS_NEEDED] Processing app: $APP"
    echo "----------------------------------------"

    mkdir -p "$RESULTS_DIR/$APP"

    # Check if we need to build this app (skip if all configs already exist)
    NEEDS_BUILD=false
    for OLD in "${OLD_SPACE_VALUES[@]}"; do
        for SEMI in "${SEMI_SPACE_VALUES[@]}"; do
            FILE_NAME="$RESULTS_DIR/${APP}/old${OLD}_semi${SEMI}.txt"
            if [ ! -f "$FILE_NAME" ]; then
                NEEDS_BUILD=true
                break 2
            fi
        done
    done

    if [ "$NEEDS_BUILD" = false ]; then
        echo "All configurations for $APP already completed, skipping..."
        CURRENT_RUN=$((CURRENT_RUN + ${#OLD_SPACE_VALUES[@]} * ${#SEMI_SPACE_VALUES[@]}))
        continue
    fi

    # Build the app once
    echo "Building $APP benchmark..."
    BUILD_SUCCESS=false

    if docker run --rm \
        --memory=2g \
        -v "$(pwd)/temp_builds:/app/temp_builds" \
        "$IMAGE_NAME" \
        /bin/bash -c "
            echo 'Building $APP...'
            if npm run build -- --env.only '$APP'; then
                echo 'Build successful for $APP'
                # Copy built artifacts to shared volume
                mkdir -p /app/temp_builds
                cp -r dist /app/temp_builds/
                echo 'Build artifacts copied'
                exit 0
            else
                echo 'Build failed for $APP'
                exit 1
            fi
        "; then
        BUILD_SUCCESS=true
        echo "$APP build completed successfully"
    else
        echo "Failed to build $APP, skipping all configurations for this app"
        # Log all configurations as failed
        for OLD in "${OLD_SPACE_VALUES[@]}"; do
            for SEMI in "${SEMI_SPACE_VALUES[@]}"; do
                echo "$APP old=$OLD semi=$SEMI (build_failed)" >> "$FAIL_LOG"
                CURRENT_RUN=$((CURRENT_RUN + 1))
            done
        done
        continue
    fi

    # Run all memory configurations for this app
    for OLD in "${OLD_SPACE_VALUES[@]}"; do
        for SEMI in "${SEMI_SPACE_VALUES[@]}"; do
            CURRENT_RUN=$((CURRENT_RUN + 1))
            FILE_NAME="$RESULTS_DIR/${APP}/old${OLD}_semi${SEMI}.txt"

            if [ -f "$FILE_NAME" ]; then
                echo "[SKIP] ($CURRENT_RUN/$TOTAL_RUNS) $APP old=${OLD}MiB semi=${SEMI}MiB - already exists"
                continue
            fi

            echo "[RUN] ($CURRENT_RUN/$TOTAL_RUNS) $APP old=${OLD}MiB semi=${SEMI}MiB"

            # Run benchmark with the pre-built app
            if docker run --rm \
                --memory=2g \
                -v "$(pwd)/temp_builds:/app/temp_builds" \
                -e NODE_OPTIONS="--max-old-space-size=$OLD --max-semi-space-size=$SEMI" \
                "$IMAGE_NAME" \
                /bin/bash -c "
                    # Copy pre-built artifacts
                    if [ -d /app/temp_builds/dist ]; then
                        cp -r /app/temp_builds/dist /app/
                        echo 'Using pre-built $APP artifacts'
                    else
                        echo 'ERROR: No pre-built artifacts found for $APP'
                        exit 1
                    fi

                    # Record process start time for timestamp synchronization
                    PROCESS_START_TIME=\$(date '+%s.%3N')
                    echo \"PROCESS_START_TIME=\$PROCESS_START_TIME\" > /tmp/timing_sync.log

                    # Create detailed memory monitoring function
                    monitor_memory() {
                        while true; do
                            wall_time=\$(date '+%s.%3N')
                            # Calculate process time using awk
                            process_time_float=\$(awk \"BEGIN {print \$wall_time - \$PROCESS_START_TIME}\")
                            process_time_ms=\$(awk \"BEGIN {printf \\\"%d\\\", \$process_time_float * 1000}\")

                            # Memory info from /proc/meminfo (all values in KiB)
                            mem_total=\$(grep '^MemTotal:' /proc/meminfo 2>/dev/null | awk '{print \$2}' || echo 0)
                            mem_free=\$(grep '^MemFree:' /proc/meminfo 2>/dev/null | awk '{print \$2}' || echo 0)
                            mem_available=\$(grep '^MemAvailable:' /proc/meminfo 2>/dev/null | awk '{print \$2}' || echo 0)
                            buffers=\$(grep '^Buffers:' /proc/meminfo 2>/dev/null | awk '{print \$2}' || echo 0)
                            cached=\$(grep '^Cached:' /proc/meminfo 2>/dev/null | awk '{print \$2}' || echo 0)

                            # Container memory from cgroups (all values in bytes)
                            if [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
                                # cgroups v1 - all values in bytes
                                mem_limit=\$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo 0)
                                mem_usage=\$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo 0)
                                mem_cache=\$(grep '^cache ' /sys/fs/cgroup/memory/memory.stat 2>/dev/null | awk '{print \$2}' || echo 0)
                            elif [ -f /sys/fs/cgroup/memory.max ]; then
                                # cgroups v2 - all values in bytes
                                mem_limit=\$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo 0)
                                mem_usage=\$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo 0)
                                mem_cache=\$(grep '^file ' /sys/fs/cgroup/memory.stat 2>/dev/null | awk '{print \$2}' || echo 0)
                            else
                                mem_limit=0
                                mem_usage=0
                                mem_cache=0
                            fi

                            # Node.js process memory from /proc/PID/status (all values in KiB)
                            # Exclude shell wrapper 'sh -c node', get actual node binary
                            node_pid=\$(pgrep -f '^node.*--trace-gc-nvp.*dist/cli.js' 2>/dev/null | head -1 || echo 0)
                            if [ \"\$node_pid\" != \"0\" ] && [ -f \"/proc/\$node_pid/status\" ]; then
                                # Basic memory metrics from /proc/PID/status (all values in KiB)
                                node_rss=\$(grep '^VmRSS:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' || echo 0)
                                node_size=\$(grep '^VmSize:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' || echo 0)
                                node_peak=\$(grep '^VmPeak:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' || echo 0)
                                node_hwm=\$(grep '^VmHWM:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' || echo 0)
                                # Extended memory breakdown (KiB)
                                node_data=\$(grep '^VmData:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' || echo 0)
                                node_stk=\$(grep '^VmStk:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' || echo 0)
                                node_exe=\$(grep '^VmExe:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' || echo 0)
                                node_lib=\$(grep '^VmLib:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' || echo 0)
                                node_pte=\$(grep '^VmPTE:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' || echo 0)
                                node_swap=\$(grep '^VmSwap:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' || echo 0)
                                node_lck=\$(grep '^VmLck:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' || echo 0)
                                # RSS breakdown - very useful for heap vs non-heap analysis (KiB)
                                node_rss_anon=\$(grep '^RssAnon:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' || echo 0)
                                node_rss_file=\$(grep '^RssFile:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' || echo 0)
                                node_rss_shmem=\$(grep '^RssShmem:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' || echo 0)
                                # Process metrics
                                node_threads=\$(grep '^Threads:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' || echo 0)
                                node_fds=\$(ls /proc/\$node_pid/fd 2>/dev/null | wc -l || echo 0)
                                node_fdsize=\$(grep '^FDSize:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' || echo 0)
                                # Performance context switches
                                node_ctxt_vol=\$(grep '^voluntary_ctxt_switches:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' || echo 0)
                                node_ctxt_nonvol=\$(grep '^nonvoluntary_ctxt_switches:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' || echo 0)
                                # Process state and identifiers
                                node_state=\$(grep '^State:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' || echo unknown)
                                node_tgid=\$(grep '^Tgid:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' || echo 0)
                                # CPU and memory affinity (useful in containers)
                                node_cpus_allowed=\$(grep '^Cpus_allowed_list:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' | tr -d '\n' || echo unknown)
                                node_mems_allowed=\$(grep '^Mems_allowed_list:' /proc/\$node_pid/status 2>/dev/null | awk '{print \$2}' | tr -d '\n' || echo unknown)
                                # Debug: record which PID we're monitoring
                                monitored_pid=\$node_pid
                            else
                                # Zero out all node metrics if no valid PID found
                                node_rss=0
                                node_size=0
                                node_peak=0
                                node_hwm=0
                                node_data=0
                                node_stk=0
                                node_exe=0
                                node_lib=0
                                node_pte=0
                                node_swap=0
                                node_lck=0
                                node_rss_anon=0
                                node_rss_file=0
                                node_rss_shmem=0
                                node_threads=0
                                node_fds=0
                                node_fdsize=0
                                node_ctxt_vol=0
                                node_ctxt_nonvol=0
                                node_state=unknown
                                node_tgid=0
                                node_cpus_allowed=unknown
                                node_mems_allowed=unknown
                                monitored_pid=0
                            fi

                            # Additional system metrics
                            # Load average (1, 5, 15 minute averages) - use semicolons to avoid CSV conflicts
                            load_avg=\$(cat /proc/loadavg 2>/dev/null | awk '{print \$1,\$2,\$3}' | tr ' ' ';' || echo '0;0;0')

                            # CPU usage snapshot (user, nice, system, idle, iowait, irq, softirq, steal) - use semicolons
                            cpu_stats=\$(head -1 /proc/stat 2>/dev/null | awk '{print \$2,\$3,\$4,\$5,\$6,\$7,\$8,\$9}' | tr ' ' ';' || echo '0;0;0;0;0;0;0;0')

                            # Context switches and interrupts
                            ctxt_switches=\$(grep '^ctxt ' /proc/stat 2>/dev/null | awk '{print \$2}' || echo 0)
                            interrupts=\$(grep '^intr ' /proc/stat 2>/dev/null | awk '{print \$2}' || echo 0)

                            # Output comprehensive CSV data with enhanced process metrics
                            echo \"\$wall_time,\$process_time_ms,\$mem_total,\$mem_free,\$mem_available,\$buffers,\$cached,\$mem_limit,\$mem_usage,\$mem_cache,\$node_rss,\$node_size,\$node_peak,\$node_hwm,\$node_data,\$node_stk,\$node_exe,\$node_lib,\$node_pte,\$node_swap,\$node_lck,\$node_rss_anon,\$node_rss_file,\$node_rss_shmem,\$node_threads,\$node_fds,\$node_fdsize,\$node_ctxt_vol,\$node_ctxt_nonvol,\$node_state,\$node_tgid,\$node_cpus_allowed,\$node_mems_allowed,\$load_avg,\$cpu_stats,\$ctxt_switches,\$interrupts,\$monitored_pid\" >> /tmp/detailed_memory.log

                            sleep 1
                        done
                    }

                    # Start monitoring in background
                    monitor_memory &
                    MONITOR_PID=\$!

                    # Run the benchmark (only the pre-built app will execute)
                    npm run benchmark
                    BENCHMARK_EXIT=\$?

                    # Stop monitoring
                    kill \$MONITOR_PID 2>/dev/null || true
                    wait \$MONITOR_PID 2>/dev/null || true

                    # Output results
                    echo '=== TIMING SYNC ==='
                    if [ -f /tmp/timing_sync.log ]; then
                        cat /tmp/timing_sync.log
                    else
                        echo '# No timing sync data found'
                    fi

                    echo '=== DETAILED MEMORY DATA ==='
                    # CSV header with comprehensive metrics and correct unit documentation
                    # Note: load_avg and cpu_stats use semicolon separators to avoid CSV conflicts
                    # Memory metrics in KiB unless specified otherwise
                    echo 'wall_time,process_time_ms,mem_total_kib,mem_free_kib,mem_available_kib,buffers_kib,cached_kib,cgroup_limit_bytes,cgroup_usage_bytes,cgroup_cache_bytes,node_rss_kib,node_size_kib,node_peak_kib,node_hwm_kib,node_data_kib,node_stk_kib,node_exe_kib,node_lib_kib,node_pte_kib,node_swap_kib,node_lck_kib,node_rss_anon_kib,node_rss_file_kib,node_rss_shmem_kib,node_threads,node_fds,node_fdsize,node_ctxt_voluntary,node_ctxt_nonvoluntary,node_state,node_tgid,node_cpus_allowed,node_mems_allowed,load_avg_1_5_15_semicolon,cpu_user_nice_sys_idle_iowait_irq_softirq_steal_semicolon,ctxt_switches,interrupts,monitored_node_pid'
                    if [ -f /tmp/detailed_memory.log ]; then
                        cat /tmp/detailed_memory.log
                    else
                        echo '# No memory data collected'
                    fi

                    exit \$BENCHMARK_EXIT
                " > "$FILE_NAME" 2>&1; then
                echo "[OK] ($CURRENT_RUN/$TOTAL_RUNS) $APP old=${OLD}MiB semi=${SEMI}MiB"
            else
                echo "[FAIL] ($CURRENT_RUN/$TOTAL_RUNS) $APP old=${OLD}MiB semi=${SEMI}MiB"
                echo "$APP old=$OLD semi=$SEMI" >> "$FAIL_LOG"
            fi
        done
    done

    echo "$APP completed - all memory configurations tested"
done

# Cleanup temp builds
if [ -d "$(pwd)/temp_builds" ]; then
    rm -rf "$(pwd)/temp_builds"
    echo "Cleaned up temporary build artifacts"
fi

echo ""
echo "=========================================="
echo "BENCHMARK EXECUTION COMPLETE"
echo "=========================================="
echo "Results directory: $RESULTS_DIR"
echo "Total files created: $(find "$RESULTS_DIR" -name "*.txt" -type f | wc -l)"
echo "Failed runs: $([ -s "$FAIL_LOG" ] && wc -l < "$FAIL_LOG" || echo 0)"
echo "Total disk usage: $(du -sh "$RESULTS_DIR" | cut -f1)"

if [ -s "$FAIL_LOG" ]; then
    echo ""
    echo "Failed configurations:"
    head -10 "$FAIL_LOG"
    if [ $(wc -l < "$FAIL_LOG") -gt 10 ]; then
        echo "... and $(($(wc -l < "$FAIL_LOG") - 10)) more failures"
    fi
fi

echo "=========================================="
