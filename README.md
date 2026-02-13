# RW-DDT Eureka! Container

This repository provides a containerized **JupyterLab** environment for analyzing JWST data with the **[Eureka!](https://github.com/kevin218/Eureka)** pipeline.

- Works on shared institutional compute and personal/community machines.
- You provide local paths at runtime using the configuration script.
- Generates a `runs/**/docker-compose.yml` file that contains local absolute paths and **must not be committed**.

---

## Overview

The container provides:

- A fully configured JupyterLab environment with Eureka! preinstalled.
- Automatic linking of analysis, notebooks, and (optional) input data directories into a stable in-container layout under `/home/rwddt/*`.
- Support for both **split-layout** CRDS (common on institutional systems) and **single-layout** CRDS caches (common for community use).
- Automatic seeding of example notebooks if none exist.
- A generated Jupyter access URL (with token) printed at startup.

---

## Files you need

From this repository:

- `configure_docker_compose.sh` — generates a per-dataset run directory under `./runs/`.
- `docker-compose.template.yml` — the template used by the script.

**Do not copy these files into your data directories.** Run the script from the repository checkout.

---

## Folder structure (Structured Mode)

Structured mode expects your host filesystem to look like:

```text
<rootdir>/JWST/<planet>/<visit>/
├── <analyst>/
│   └── notebooks/
├── MAST_Stage1/        (optional)
└── Uncalibrated/       (optional)
```

Notes:

- The script will create `<rootdir>/JWST/<planet>/<visit>/<analyst>/notebooks/` if needed.
- `MAST_Stage1` and `Uncalibrated` are **optional** for community users.

---

## Mount & isolation model (Structured Mode)

To keep notebooks simple **and** prevent analysts from seeing each other’s work:

- The container bind-mounts **only what is needed**:
  - the analyst folder (read/write)
  - `MAST_Stage1` (read-only, **only if it exists on the host**)
  - `Uncalibrated` (read-only, **only if it exists on the host**)
- Inside the container, stable paths are provided via symlinks:
  - `/home/rwddt/analysis`  → your analyst folder
  - `/home/rwddt/notebooks` → your notebooks
  - `/home/rwddt/MAST_Stage1` and `/home/rwddt/Uncalibrated` → input folders (or empty dirs if not present)

---

## 1) Configure the container

### Structured mode (recommended)

From the repository root:

```bash
./configure_docker_compose.sh <rootdir> <planet> <visit> <analyst> [<crds_dir>] [split|single]
```

Example (community single-layout CRDS):

```bash
./configure_docker_compose.sh $HOME/data TOI-1234b visit1 Analyst_A $HOME/crds_cache single
```

This creates:

```text
runs/<planet>_<visit>/
├── docker-compose.yml
├── .rwddt_state
└── rwddt-run
```

### Simple mode (quick tests)

Simple mode is for quick tests when you **don’t** want to create a host directory tree.
By default, work lives inside the container and is **not persisted** if the container is removed.

From the repository root:

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

## 2) Start the container

Change into the run directory and start:

```bash
cd runs/<planet>_<visit>
./rwddt-run up
```

For simple mode:

```bash
cd runs/simple_YYYYmmdd_HHMMSS
./rwddt-run up
```

---

## 3) Access JupyterLab

### View the access URL

```bash
./rwddt-run logs
```

If the URL/token doesn’t appear immediately, wait ~5–15 seconds and run `./rwddt-run logs` again.

### Remote host port-forwarding

If Docker is running on a remote host, you'll need to setup ssh-based port forwarding using the
command provided in the Docker logs that will look something like:

```bash
ssh -L <hostport>:localhost:<hostport> <user>@<remote-host>
```

Keep that terminal open while you use JupyterLab; type `exit` to close the tunnel when finished.

---

## Updating to the newest DockerHub image version

```bash
./rwddt-run update
```

---

## Stopping the container

```bash
./rwddt-run down
```

---

## Troubleshooting

- **No URL printed yet:** wait a few seconds and re-run `./rwddt-run logs`.
- **Permission denied writing files:** ensure your `<analyst>` directory is writable by your user (and group, if applicable).
- **Two datasets at once:** each dataset gets its own run directory under `runs/`; start each from its own run directory.

---

## Notes (inside the container)

| Container Path             | Purpose                                           |
|----------------------------|---------------------------------------------------|
| `/home/rwddt/notebooks/`   | Editable notebooks                                |
| `/home/rwddt/analysis/`    | Analyst writable area                             |
| `/home/rwddt/MAST_Stage1/` | Shared Stage 1 inputs (RO if present; else empty) |
| `/home/rwddt/Uncalibrated/`| Shared Stage 0 inputs (RO if present; else empty) |

---

## Support

If you encounter issues, please contact the RW-DDT JWST Data Analysis team lead (Taylor Bell; @taylorbell57).
