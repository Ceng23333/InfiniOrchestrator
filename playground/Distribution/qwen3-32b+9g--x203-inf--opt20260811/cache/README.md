# Case host caches

Large host-side seeds and AOT products live here (not packaged by default in `export-bundle.sh`).

| Subdir | In-container mount | Role |
|--------|--------------------|------|
| `piecewise_inductor/` | `/workspace/piecewise_inductor_cache` | Qwen piecewise inductor AOT (compose rw) |

Blobs are gitignored; only `README.md` / `.gitignore` are tracked.
