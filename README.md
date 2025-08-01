# RW-DDT Eureka! Container

This containerized environment provides a fully-configured JupyterLab server for analyzing JWST data using the [Eureka!](https://github.com/kevin218/Eureka) pipeline. It is customized for the RW-DDT team and is preloaded with reference notebooks, required dependencies, and CRDS integration.

---

## Quick Summary

* No Docker installation required — the container runs on the central compute server
* Each analyst has their own private working area
* Shared read-only inputs (e.g. MAST Stage 1 and Uncalibrated data)
* Automatically launches JupyterLab and shows the access URL (with token)

---

## Folder Structure (on the server)

Your data is expected to live under a shared root like:

```
/<rootdir>/JWST/<planet>/<visit>/
├── Analysis_A/
│   ├── notebooks/           # Your Jupyter notebooks go here
│   └── ...                  # Outputs and intermediate products
├── Analysis_B/
│   ├── notebooks/           # Your Jupyter notebooks go here
│   └── ...                  # Outputs and intermediate products
├── Uncalibrated/            # Shared input (read-only)
└── MAST_Stage1/             # Shared input (read-only)
```

> Analysts should only write inside their assigned `Analysis_<X>/` folder.

---

## 1. Configure the Container

To generate a personalized `docker-compose.yml` file, run:

```bash
./configure_docker_compose.sh <rootdir> <planet> <visit> <analyst>
```

replacing the `<variable>` fields with the appropriate details. This will create a `docker-compose.yml` file tailored for your analyst and visit.

---

## 2. Start the Container

Once the config is generated, launch your container using:

```bash
docker compose up -d
```

This will:

* Start the container in the background (this will persist even after you disconnect from the server)
* Automatically find an available port
* Print the Jupyter URL (including token) to access in your browser

---

## 3. Access JupyterLab

Once running, check the logs to get the Jupyter URL with the correct port and token. Wait a few seconds after starting the container, and then run:

```bash
docker logs rwddt_<planet>_<visit>_<analyst>
```

Open that URL in your browser (from a browser on your laptop connected via port forwarding, or through a web interface if available).

---

## Notes

* If your `notebooks/` folder is empty on first run, example notebooks will be copied in automatically.
* The CRDS cache is mounted read-only from `/grp/crds/cache`.
* The container runs as the unprivileged `rwddt` user inside.
* The server IP and external port are automatically detected and printed at launch.
* All paths inside the container follow this convention:

| Container Path              | Purpose                          |
| --------------------------- | -------------------------------- |
| `/home/rwddt/notebooks/`    | Your editable notebooks          |
| `/home/rwddt/analysis/`     | Your full writable analysis area |
| `/home/rwddt/MAST_Stage1/`  | Read-only shared MAST inputs     |
| `/home/rwddt/Uncalibrated/` | Read-only raw JWST uncalibrated  |
| `/home/rwddt/crds_cache/`   | Read-only CRDS reference cache   |

---

## Troubleshooting

* If the Jupyter URL isn't printed on startup, try:

  ```bash
  docker logs rwddt_<planet>_<visit>_<analyst>
  ```
* If port 8888 is unavailable, the container will pick another and print the correct access URL.
* You can stop the container anytime with:

  ```bash
  docker compose down
  ```

  Please be sure to stop the container once you are done using it.

---

## Need Help?

If you run into issues, please contact the RW-DDT JWST Data Analysis Team Lead (Taylor Bell; @taylorbell57).