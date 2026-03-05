# RW-DDT Eureka! Container

This repository provides a containerized **JupyterLab** environment for analyzing JWST data with the **[Eureka!](https://github.com/kevin218/Eureka)** pipeline.

- Works on shared institutional compute and personal/community machines.
- You provide local paths at runtime using the configuration script.
- Generates a `runs/**/docker-compose.yml` file that contains local absolute paths and **must not be committed**.

> **Migration note (breaking change):** If you previously ran `docker compose up` from inside an analyst directory, re-run `./configure_docker_compose.sh` from the repository root. The workflow generates a per-run directory under `runs/` and you manage the container via `./rwddt-run up/logs/exec/down`.

---

## Overview

The container provides:

- A fully configured JupyterLab environment with Eureka! preinstalled.
- Stable in-container paths under `/home/rwddt/*` (see “Notes (inside the container)”).
- Support for both **split-layout** CRDS (common on institutional systems) and **single-layout** CRDS caches (common for community use).
- Automatic seeding of example notebooks if none exist.
- A generated Jupyter access URL (with token) printed at startup.

---

## Prerequisites

- Docker Engine installed and running.
- Docker Compose v2 available via `docker compose` (Compose plugin).
- Permission to run Docker (either in the `docker` group or via `sudo`).

---

## Files you need

You will need several files from this repo, so you are best-off running everything from a local checkout of this repository.

### Option A: Clone with git (recommended)

```bash
git clone https://github.com/taylorbell57/RWDDT_Eureka.git
cd RWDDT_Eureka
```

### Option B: Download a ZIP

Use the GitHub **Code → Download ZIP** button, unzip it, and `cd` into the extracted folder.

---

## Configure a run (from repository root)

### Structured mode (recommended; single visit)

```bash
./configure_docker_compose.sh <rootdir> <planet> <visit_num> <analyst> [<crds_dir>] [split|single]
```

**Visit argument rule (important):**

- `<visit_num>` should be an **integer**, e.g. `12`.
- For backward compatibility, `visit12` and `visit012` are accepted, but are normalized to the directory name `visit12` (no zero padding).

**Example (community single-layout CRDS):**

```bash
./configure_docker_compose.sh $HOME/data TOI-1234b 1 Analyst_A $HOME/crds_cache single
```

This creates:

```text
runs/<planet>_<visit>/
├── docker-compose.yml
├── .rwddt_state
└── rwddt-run
```

> Note: `<visit>` will be the normalized visit directory name, e.g. `visit1`, `visit12`.

---

### Checkpoint mode (joint fit across multiple visits)

Checkpoint mode is intended for combining outputs from multiple prior visits (mounted **read-only**) and writing new joint-fit outputs into a checkpoint workspace (mounted **read-write**).

```bash
./configure_docker_compose.sh --checkpoint <rootdir> <planet> <checkpoint> <analyst> <max_visit_num> \
    [<crds_dir>] [split|single]
```

**Semantics:**

- Visit roots `visit1 ... visit<max_visit_num>` are mounted **read-only** (missing visits are skipped with a warning).
- The checkpoint analyst folder is created/mounted **read-write** at:
  - Host: `<rootdir>/JWST/<planet>/<checkpoint>/<analyst>/`
  - Container: `/mnt/rwddt/JWST/<planet>/<checkpoint>/<analyst>/`

**Example:**

```bash
./configure_docker_compose.sh --checkpoint $HOME/data TOI-1234b checkpoint1 Analyst_A 12 $HOME/crds_cache single
```

This creates:

```text
runs/<planet>_<checkpoint>_maxvisit<max_visit_num>/
├── docker-compose.yml
├── .rwddt_state
└── rwddt-run
```

---

### Simple mode (quick tests)

Simple mode is for quick tests when you **don’t** want to create a host directory tree. By default, work lives inside the container and is **not persisted** if the container is removed.

```bash
./configure_docker_compose.sh --simple [<crds_dir>] [split|single]
```

Examples:

```bash
# Community single-layout CRDS
./configure_docker_compose.sh --simple $HOME/crds_cache single

# Institutional split-layout CRDS
./configure_docker_compose.sh --simple /path/to/crds split
```

This creates:

```text
runs/simple_YYYYmmdd_HHMMSS/
├── docker-compose.yml
├── .rwddt_state
└── rwddt-run
```

---

## Folder structure on host

### Structured Mode (single visit)

Structured mode expects your host filesystem to look like:

```text
<rootdir>/JWST/<planet>/visit<visit_num>/
├── <analyst>/
│   └── notebooks/
├── MAST_Stage1/        (optional)
└── Uncalibrated/       (optional)
```

Notes:

- The script will create `<rootdir>/JWST/<planet>/visit<visit_num>/<analyst>/notebooks/` if needed.
- `MAST_Stage1` and `Uncalibrated` are optional.
- They are mounted automatically **only if those directories exist** on the host at configure time.

---

### Checkpoint Mode

Checkpoint mode assumes you already have visits laid out as:

```text
<rootdir>/JWST/<planet>/
├── visit1/
├── visit2/
├── ...
└── visitN/
```

and creates a new checkpoint workspace:

```text
<rootdir>/JWST/<planet>/<checkpoint>/
└── <analyst>/
    └── notebooks/
```

Notes:

- Visit roots are mounted **read-only**.
- The checkpoint analyst folder is mounted **read-write**.

---

## Mount & isolation model

### Structured Mode

To keep notebooks simple **and** prevent analysts from seeing each other’s work:

- The container bind-mounts **only what is needed**:
  - the analyst folder (read/write)
  - `MAST_Stage1` (read-only, only if it exists on the host)
  - `Uncalibrated` (read-only, only if it exists on the host)
- Inside the container, stable paths are provided via symlinks:
  - `/home/rwddt/analysis` → your analyst folder
  - `/home/rwddt/notebooks` → your notebooks
  - `/home/rwddt/MAST_Stage1` and `/home/rwddt/Uncalibrated` → input folders (or empty dirs if not present)

### Checkpoint Mode

- The container bind-mounts:
  - the checkpoint analyst folder (read/write)
  - visit roots `visit1..visitN` (read-only)
- Inside the container:
  - `/home/rwddt/analysis` → checkpoint analyst folder (RW)
  - `/home/rwddt/notebooks` → checkpoint notebooks (RW)
  - `/home/rwddt/visits` → `/mnt/rwddt/JWST/<planet>` (RO visit roots + checkpoint folder)
- **In checkpoint mode, `/home/rwddt/MAST_Stage1` and `/home/rwddt/Uncalibrated` are not created.**

---

## Start the container

Change into the run directory and start:

```bash
cd runs/<run_name>
./rwddt-run up
```

Examples:

```bash
# structured
cd runs/<planet>_visit12
./rwddt-run up

# checkpoint
cd runs/<planet>_checkpoint1_maxvisit12
./rwddt-run up
```

---

## Access JupyterLab

### View the access URL

```bash
./rwddt-run logs
```

If the URL/token doesn’t appear immediately, wait ~5–15 seconds and run `./rwddt-run logs` again.

### Remote host port-forwarding

If Docker is running on a remote host, you’ll need SSH port forwarding:

```bash
ssh -L <hostport>:localhost:<hostport> <user>@<remote-host>
```

Keep that terminal open while you use JupyterLab; type `exit` to close the tunnel when finished.

You can also print a helper snippet with:

```bash
./rwddt-run url
```

---

## Useful wrapper commands

```bash
./rwddt-run info     # show what this run directory is configured for
./rwddt-run exec bash
./rwddt-run ps
./rwddt-run down
./rwddt-run update   # pull newest image + recreate
```

---

## Persisting work in Simple Mode (recommended add-on)

By default, Simple Mode does **not** mount a host workspace. To persist your notebooks and analysis:

1) Create a host workspace directory (example):

```bash
mkdir -p $HOME/rwddt_simple_work/{notebooks,analysis}
```

2) Edit the generated `runs/simple_YYYYmmdd_HHMMSS/docker-compose.yml` **before** starting (or run `./rwddt-run down` first if already running), and add these mounts under `services -> rwddt_eureka -> volumes`:

```yaml
      - $HOME/rwddt_simple_work/notebooks:/home/rwddt/notebooks:rw
      - $HOME/rwddt_simple_work/analysis:/home/rwddt/analysis:rw
```

3) Start (or restart) the run:

```bash
cd runs/simple_YYYYmmdd_HHMMSS
./rwddt-run up
```

> Tip: Structured Mode is best for collaboration and consistent shared host layout; Simple Mode persistence is intended for quick, self-contained experiments.

---

## Optional environment overrides

Set these in your shell before running `./rwddt-run up`:

- `IMAGE` — override which container image to run (useful for local builds).
- `CRDS_MODE=remote` — run without requiring a local CRDS cache directory on the host (uses the CRDS server).

---

## Troubleshooting

- **No URL printed yet:** wait a few seconds and re-run `./rwddt-run logs`.
- **Permission denied writing files:** ensure your `<analyst>` directory is writable by your host user (and group, if applicable).
- **Two datasets at once:** each dataset gets its own run directory under `runs/`; start each from its own run directory.

---

## Notes (inside the container)

### Structured mode paths

- `/home/rwddt/notebooks/` — editable notebooks
- `/home/rwddt/analysis/` — analyst writable area
- `/home/rwddt/MAST_Stage1/` — shared Stage 1 inputs (RO if present; else empty)
- `/home/rwddt/Uncalibrated/` — shared Stage 0 inputs (RO if present; else empty)

### Checkpoint mode paths

- `/home/rwddt/notebooks/` — checkpoint notebooks (RW)
- `/home/rwddt/analysis/` — checkpoint workspace (RW)
- `/home/rwddt/visits/` — browse visit roots under this planet (primarily RO)

---

## Support

If you encounter issues, please contact the RW-DDT JWST Data Analysis team lead (Taylor Bell; @taylorbell57).

