# RW-DDT Eureka! Container

This repository provides a containerized JupyterLab environment for analyzing JWST data with the [Eureka!](https://github.com/kevin218/Eureka) pipeline. The setup is designed for both STScI staff and the wider research community, with flexibility for local and remote deployments.

---

## Overview

The container provides:

* A fully-configured JupyterLab environment with Eureka! preinstalled.
* Automatic linking of analysis, notebooks, and input data directories.
* Support for both split-layout CRDS (used at STScI) and single-layout CRDS caches (typical for community use).
* Automatic seeding of example notebooks if none exist.
* A generated Jupyter access URL (with token) printed at startup.

---

## Required Files

Before running the container, you need two configuration files from this repository:

* `configure_docker_compose.sh` – Generates a personalized `docker-compose.yml` for your analysis session.
* `docker-compose.template.yml` – A template used by the script.

### Placement

Store both files inside your `<analyst>` folder. All commands should be run from within this folder. For example:

```
<rootdir>/JWST/<planet>/<visit>/<analyst>/
├── configure_docker_compose.sh
└── docker-compose.template.yml
```

---

## Folder Structure

The container supports different layouts depending on whether you are at STScI or working externally.

### STScI Staff

STScI staff should use the established shared root directory for RW-DDT work. The structure is:

```
<rootdir>/JWST/<planet>/<visit>/
├── <analyst>/
│   ├── notebooks/           # Analyst's personal notebooks
│   └── outputs/             # Other products and analysis files
├── Uncalibrated/            # Shared Stage 0 data (read-only)
└── MAST_Stage1/             # Shared Stage 1 data (read-only)
```

CRDS is accessed in split-layout mode.

### Community Members

Community members have two options:

1. **Structured layout (recommended for collaboration):**

   ```
   <rootdir>/JWST/<planet>/<visit>/
   ├── <analyst>/
   │   ├── notebooks/           # Analyst's personal notebooks
   │   └── outputs/             # Other products and analysis files
   ├── Uncalibrated/            # Shared Stage 0 data (optional)
   └── MAST_Stage1/             # Shared Stage 1 data (optional)
   ```

   By default, CRDS is expected at `$HOME/crds_cache` in single-layout mode.

2. **Simplified mode:** If you prefer not to set up the above directory structure, set `SIMPLE_MODE=1` when starting the container. In this case, the container creates a generic workspace under `/home/rwddt/work` with subdirectories for notebooks, analysis, and inputs. This is convenient for quick tests or local exploration.

   ```bash
   SIMPLE_MODE=1 docker compose up -d
   ```

   You must still run this command from the directory containing your `docker-compose.yml` (normally your `<analyst>` folder).

   **Warning:** In simplified mode, the workspace lives only inside the container. Data is not written to your host filesystem and will be lost if the container is removed. Use this mode only for temporary or test runs unless you manually configure additional host volume mounts.

---

## 1. Configure the Container

From your `<analyst>` folder, run:

```bash
./configure_docker_compose.sh <rootdir> <planet> <visit> <analyst> [<crds_dir>] [split|single]
```

Examples:

* STScI staff:

  ```bash
  ./configure_docker_compose.sh <rootdir> TOI-1234b visit1 Analyst_A /grp/crds split
  ```

* Community researcher:

  ```bash
  ./configure_docker_compose.sh $HOME/data TOI-1234b visit1 Analyst_A $HOME/crds_cache single
  ```

This generates a `docker-compose.yml` customized for your environment. Do **not** commit this file; it contains local absolute paths.

---

## 2. Start the Container

Once you have generated your `docker-compose.yml`, start JupyterLab **from within your `<analyst>` folder**:

```bash
docker compose up -d
```

The container will:

* Run in the background and persist after disconnect.
* Find a free port automatically.
* Print the access URL with token.

To enable simplified mode, prefix the command with `SIMPLE_MODE=1`:

```bash
SIMPLE_MODE=1 docker compose up -d
```

---

## 3. Access JupyterLab

To view the access URL:

```bash
docker logs rwddt_<planet>_<visit>_<analyst>
```

Open the URL in your browser. If running on a remote server, forward the port first, for example:

```bash
ssh -L <hostport>:localhost:<hostport> user@remote.server
```

---

## Troubleshooting

* If no URL is printed, wait a few seconds and re-check with `docker logs`.
* If your notebooks directory is empty on first run, default example notebooks are copied in automatically.
* To stop your container:

  ```bash
  docker compose down
  ```

---

## Notes

* Inside the container:

| Container Path              | Purpose                           |
| --------------------------- | --------------------------------- |
| `/home/rwddt/notebooks/`    | Editable notebooks                |
| `/home/rwddt/analysis/`     | Analyst writable area             |
| `/home/rwddt/MAST_Stage1/`  | Shared Stage 1 inputs (read-only) |
| `/home/rwddt/Uncalibrated/` | Shared Stage 0 inputs (read-only) |

* The container always runs as an unprivileged `rwddt` user.
* CRDS configuration depends on your layout choice (split vs. single).

---

## Support

If you encounter issues, please contact the RW-DDT team lead (Taylor Bell; @taylorbell57).

