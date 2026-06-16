# README.md (GC testing version)

## Node.js Memory Benchmark Framework

This project provides an automated benchmarking framework for evaluating the impact of Node.js V8 memory configuration parameters on the execution of JavaScript tooling applications.

The framework systematically tests combinations of:

* `--max-old-space-size`
* `--max-semi-space-size`

across multiple benchmark applications while collecting detailed memory, process, and container-level metrics.

---

## Objectives

The script is designed to:

1. Build each benchmark application only once.
2. Reuse build artifacts across all memory configurations.
3. Execute thousands of benchmark runs automatically.
4. Collect detailed runtime memory statistics.
5. Detect unstable memory configurations.
6. Generate reproducible experimental results suitable for academic research.

---

## Tested Applications

The benchmark suite includes:

| Application  |
| ------------ |
| acorn        |
| babel        |
| babel-minify |
| babylon      |
| buble        |
| chai         |
| coffeescript |
| espree       |
| esprima      |
| jshint       |
| lebab        |
| postcss      |
| prepack      |
| prettier     |
| source-map   |
| terser       |
| typescript   |
| uglify-js    |

---

## Memory Configuration Space

### Old Space

Values tested:

```text
32, 48, 64, 96, 128, 192, 256, 384,
512, 640, 768, 896, 1024, 1280,
1536, 1792, 2048 MiB
```

### Semi Space

Values tested:

```text
2, 4, 6, 8, 12, 16, 24, 32,
48, 64, 80, 96, 128, 160, 192 MiB
```

---

## Total Experimental Space

```text
18 applications
× 17 old-space values
× 15 semi-space values
--------------------------------
4590 benchmark executions
```

---

## Execution Strategy

Instead of rebuilding each application for every memory configuration:

```text
Build application once
    ↓
Store artifacts
    ↓
Execute all memory combinations
    ↓
Move to next application
```

This reduces build overhead dramatically.

---

## Docker Requirements

The script requires:

* Docker
* Node.js benchmark image build context
* npm build scripts
* npm benchmark scripts

Expected commands:

```bash
npm run build -- --env.only <app>
npm run benchmark
```

---

## Output Structure

```text
version_1.4_results/
│
├── failures.log
│
├── acorn/
│   ├── old32_semi2.txt
│   ├── old32_semi4.txt
│   └── ...
│
├── babel/
│   └── ...
│
└── ...
```

Each result file contains:

* Benchmark output
* V8 GC logs
* Timing synchronization data
* Detailed memory monitoring data

---

## Failure Handling

Failed executions are recorded in:

```text
version_1.4_results/failures.log
```
