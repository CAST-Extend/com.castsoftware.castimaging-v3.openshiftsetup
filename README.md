# Documentation
This repository contains the helm chart to deploy CAST Imaging on an OpenShift cluster.
General concepts about CAST Imaging install can be found here: https://doc.castsoftware.com/imaging/install/global/kubernetes/

## Helm Chart Release Notes

### 3.6.8 (vs 3.6.7)

#### New Features
- **Configurable network timeouts**: two new `values.yaml` settings control how long a request may take on the OpenShift Route before the router aborts it with a Gateway Timeout (504). They are applied through the `haproxy.router.openshift.io/timeout` annotation when `Routes.enable=true`:
  - `NetworkTimeoutSeconds: 300`: `castimaging-route` (main application, to `console-gateway-service`). Increase this if you see timeouts on long-running calls.
  - `ExtendProxy.timeoutSeconds: 3600`: `extendproxy-route` (bundle uploads can be large/slow, hence the much higher default).

  Previously no timeout annotation was set, so the OpenShift router default (30s) applied.
- **Persistent log volumes for console services**: logs of console-control-panel, console-gateway-service, console-authentication-service, console-service, console-sso-service and console-dashboards are now written to dedicated PersistentVolumeClaims (`pvc-controlpanel-logs`, `pvc-gatewayservice-logs`, `pvc-authenticationservice-logs`, `pvc-consoleservice-logs`, `pvc-ssoservice-logs`, `pvc-dashboards-logs`, created with `helm.sh/resource-policy: keep`), so they survive pod restarts. Their sizes are configurable via the new `size_controlpanel_logs`, `size_gatewayservice_logs`, `size_authenticationservice_logs`, `size_consoleservice_logs`, `size_ssoservice_logs` and `size_dashboards_logs` values (default `2Gi` each). Keycloak (sso-service) is configured to log both to the console and to a daily-rotated file (`sso.log`, max 10M per file).
  Volume write permissions rely on the `fsGroup` assigned by the OpenShift SCC (`restricted-v2`), so no fixed `fsGroup` is set in the chart.
- **MCP Server 3.1 (`imaging-mcp-server` 3.1.0-beta6), now enabled by default (`McpServer.enable: true`)**: the `mcp-server` pod now runs the MCP Aggregator Gateway with the Structural, Semantic search and Text2Cypher MCP servers behind it (see https://doc.castsoftware.com/imaging/mcp-server/imaging/3.1/docker/). Requires CAST Imaging ≥ 3.6.8.
  - The `mcp-server` Service now exposes the gateway port **8285** (previously 8282). The gateway registers in the Control Panel under the same `MCPSERVER` name, so clients keep using `<FrontEndHost>/mcp`. The three MCP servers listen on the pod loopback only (8282 / 8287 / 8289).
  - The `mcpserverappconfig` ConfigMap (`app.config`) is replaced by the `mcpserver-registry` ConfigMap holding the gateway routing registry (`mcp_servers.json`, mounted at `/opt/cast/mcp-suite/config/`). External MCP servers can be added to it.
  - All other settings are environment variables, set in the `MCPSERVER` section of `values.yaml` with the same names as the docker `.env` file: `STRUCTURAL_MCP_ENABLED`, `SEMANTIC_MCP_ENABLED`, `TEXT_TO_CYPHER_MCP_ENABLED`, `*_TOOL_SURFACE_PROFILE`, `IMAGING_CODE`, `LOG_LEVEL` (`INFO` or `DEBUG` only, replaces `DEBUG_MODE`), telemetry settings... `IMAGING_BASE_URL` (Text2Cypher deep links) defaults to `<FrontEndHost>[<appcontext>]/imaging`.
  - Neo4j is now used (Semantic search and Text2Cypher): the pod connects to `bolt://viewer-neo4j:7687` with the `neo4j-password` Secret key, and an init container waits for console-control-panel and viewer-neo4j.
  - Logs are now written to `/opt/cast/mcp-suite/logs` (same `pvc-mcpserver-logs` volume, one sub-folder per process). A new `pvc-mcpserver-data` volume (`size_mcpserver_data`, default `1Gi`, `helm.sh/resource-policy: keep`) holds the Text2Cypher SQLite stores (`/opt/cast/mcp-suite/data`).
  - The pod runs with the UID/fsGroup assigned by the OpenShift SCC (`restricted-v2`, no fixed user in the chart): `emptyDir` volumes are mounted on `/tmp` and `/var/run` (supervisord) and `HOME` is set to `/tmp`. Default `McpServerResources` increased to requests 0.5 CPU / 1G, limits 2 CPU / 4G (4 processes in one pod).

#### Security
- **`guest` database user removed**: the embedded Postgres init script no longer creates the `guest` user, and the `guest-db-password` key has been removed from the `imaging-pwd-sec` Secret (`GuestDbPassword` value no longer used). Console services now connect explicitly with the `operator` user (`DB_USER` / `DB_USERNAME`, `DB_DATABASE=postgres`); console-authentication-service additionally receives `DB_ENCRYPTED_PASSWORD` from the `operator-db-password-crypted2` Secret key.
  ⚠️ **Migration note**: `GuestDbPassword` can be removed from your custom `values.yaml`, and the `guest-db-password` key is no longer required in an `existingSecret`. On existing deployments, the `guest` user already present in Postgres is not dropped by the upgrade (it can be removed manually with `DROP USER guest;` if not used elsewhere).

#### Configuration Changes
- **Deployment strategy set to `Recreate`** on console-authentication-service, console-service, console-control-panel, console-gateway-service, console-sso-service, mcp-server, viewer-aimanager, viewer-api, viewer-etl and viewer-server (previously the default `RollingUpdate`).
- Image updates: `imaging-mcp-server` 3.1.0-beta6, and all CAST Imaging application images 3.6.8.

### 3.6.7 (vs 3.6.6)

#### New Features
- **Proxy exclusions auto-update job**: a new `proxy-exclusions-update-script` ConfigMap and a suspended `proxy-exclusions-cronjob` CronJob are shipped with the chart. It can be triggered manually (`oc create job proxy-exclusions-cronjob-<id> --from=cronjob/proxy-exclusions-cronjob -n <namespace>`) to refresh `control_panel.settings.non_proxy_hosts` from the subnets of currently registered services, when `proxy_settings_mode` is `MANUAL_PROXY`.
- New `AIMANAGER.SUMMARY_LOG_LEVEL: info` default environment variable.

#### Security
- **`UseCustomTrustStore` removed**: self-signed or otherwise unverifiable certificate on an internal service is no longer a blocking issue. The `UseCustomTrustStore` option and the `auth.caCertificate` value have been removed from `values.yaml`, along with the `authcacrt` ConfigMap and the associated init container/volume mounts in `console-authentication-service`.
  ⚠️ **Migration note**: if your existing `values.yaml` sets `UseCustomTrustStore` / `auth.caCertificate`, you can remove them: they are no longer used by the chart.

#### Fixes
- **`license-extend-update-script.sql` fixed**: `extend_url` is now only auto-populated when currently empty, so a manually-configured Extend URL is no longer overwritten on every `helm upgrade`. Updating `extend_apikey` no longer depends on `ExtendProxy.enable`.

### 3.6.6 (vs 3.6.5)

#### New Features
- **Health probes** added on viewer-api, viewer-etl, viewer-server and viewer-aimanager (startup/liveness/readiness) for better detection of pods stuck at startup.
- **Generic per-service environment variable injection**: new sections in `values.yaml` (`NEO4J`, `ETL`, `SERVER`, `API`, `AIMANAGER`, `MCPSERVER`, `CONTROLPANEL`, `ANALYSISNODE`, `AUTHENTICATIONSERVICE`, `CONSOLESERVICE`, `DASHBOARDS`, `GATEWAYSERVICE`, `SSOSERVICE`, `EXTENDPROXY`) allowing custom environment variables to be added to each container without touching the templates.

#### Security
- The operator's encrypted password (`DB_ENCRYPTED_PASSWORD`) is no longer injected in plain text into the console-control-panel deployment: it is now stored in the Kubernetes Secret and referenced via `secretKeyRef`.
- ⚠️ **Migration note**: if you use an external `existingSecret`, it must now also contain the `operator-db-password-crypted2` key (base64-encoded value of the `CRYPTED2:...` string), in addition to the previously required keys.

#### Configuration Changes
- Neo4j memory parameters (`NEO4J_server_memory_heap_initial__size`, `NEO4J_server_memory_heap_max__size`, `NEO4J_dbms_memory_transaction_total_max`) have moved from the root of `values.yaml` into the `NEO4J:` section — update your custom values files accordingly.
- `IMAGING_DOMAIN_SYNCHRO_ENABLED` removed as a dedicated variable; it is now set via the `CONTROLPANEL:` env section instead (default unchanged).
- ⚠️ **Audit-trail volume no longer used**: the dedicated `pvc-controlpanel-audit-trails` PersistentVolumeClaim is no longer created or mounted by console-control-panel. Audit trail data is now stored in the existing shared volume (mounted at `/opt/cast/shared`) instead of its own volume (audit-trail full path remains unchanged: /opt/cast/shared/common-data/audit-trail).
  For customers upgrading from a previous version: the old PVC is **not deleted** by the upgrade (it was created with `helm.sh/resource-policy: keep`) — it simply becomes unmounted/orphaned, and its data (including the `audit-trail` folder) remains intact on the underlying disk. If you want to recover the audit trail history it contained, mount it temporarily with a pod and copy the data out, e.g.:
  ```yaml
  apiVersion: v1
  kind: Pod
  metadata:
    name: audit-trail-recovery
    namespace: <namespace>
  spec:
    restartPolicy: Never
    containers:
      - name: init-util
        image: castimaging/init-util:1.2.11
        command: ["sleep", "3600"]
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
        volumeMounts:
          - name: audit-trails
            mountPath: /opt/cast/shared/common-data
    volumes:
      - name: audit-trails
        persistentVolumeClaim:
          claimName: pvc-controlpanel-audit-trails
  ```
  ```
  oc apply -f audit-trail-recovery.yaml -n <namespace>
  oc cp <namespace>/audit-trail-recovery:/opt/cast/shared/common-data/audit-trail ./audit-trail-backup
  oc delete pod audit-trail-recovery -n <namespace>
  ```

#### Fixes
- Fixed NodePort/LoadBalancer activation conditions on the gateway service and extendproxy.

#### Known Issues
- Only applies to Kubernetes deployments: the application export/import feature is not yet functional in this version (it will fail). It will be fully functional in the next release.

