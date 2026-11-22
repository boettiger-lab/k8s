#!/usr/bin/env bash
# Create (or replace) view monitoring.jupyter_home_quota on the JuiceFS metadata DB
# and let `juicefs_exporter` read it. home-quota-exporter.yaml serves it to
# Prometheus as jupyter_home_* metrics.
#
# The view exposes ONLY the top-level home directories (jupyter-claim-*) and
# their quota counters. The exporter role gets SELECT on the view, not on
# jfs_edge, so it cannot list the files inside anyone's home. The view runs
# with its owner's (juicefs) rights.
#
# A home has a jfs_dir_quota row only once the CSI driver has mounted it at
# least once (the quota is set at mount, not at provisioning), so a migrated
# or new home appears here after its first server start.
#
# Idempotent. Run after mint-pg-exporter-role.sh (it creates the role).
# Usage: bash platform/juicefs/home-quota-view.sh
set -euo pipefail
kubectl -n juicefs exec -i deploy/juicefs-pg -- psql -q -U juicefs -d juicefs -v ON_ERROR_STOP=1 <<'SQL'
CREATE SCHEMA IF NOT EXISTS monitoring;
CREATE OR REPLACE VIEW monitoring.jupyter_home_quota AS
SELECT regexp_replace(convert_from(e.name, 'UTF8'), '^jupyter-', '') AS pvc,
       q.max_space   AS quota_bytes,
       q.used_space  AS used_bytes,
       q.used_inodes AS used_inodes
FROM public.jfs_dir_quota q
JOIN public.jfs_edge e ON e.inode = q.inode AND e.parent = 1
WHERE convert_from(e.name, 'UTF8') LIKE 'jupyter-claim-%';
GRANT USAGE ON SCHEMA monitoring TO juicefs_exporter;
GRANT SELECT ON monitoring.jupyter_home_quota TO juicefs_exporter;
SQL
echo "view monitoring.jupyter_home_quota ready (SELECT granted to juicefs_exporter)"
