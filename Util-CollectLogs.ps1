param (
    [string]$NAMESPACE = "castimaging-v3"
)

# Pre-check: cluster reachable and namespace exists
Write-Host "Context: $(kubectl config current-context)"
kubectl get namespace $NAMESPACE -o name 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Host "Namespace '$NAMESPACE' not found or cluster unreachable (check 'oc login' / kubectl context). Aborting."
  exit 1
}
$ALLPODS = @((kubectl get pods -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}') -split '\s+' | Where-Object { $_ })
if ($ALLPODS.Count -eq 0) {
  Write-Host "No pods found in namespace '$NAMESPACE'. Aborting."
  exit 1
}

$DEST = "./Logs/$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Force -Path $DEST | Out-Null

# neo4j
Write-Host "=== Pod: viewer-neo4j-core-0 ==="
$CmdString = "kubectl exec viewer-neo4j-core-0 -n $NAMESPACE -- sh -c `"tar cf - /var/lib/neo4j/logs 2>/dev/null`" > `"$DEST\viewer-neo4j-logs.tar`""
# Execute it via cmd.exe to preserve the binary stream
cmd.exe /c $CmdString

# Analysis nodes
$pods = kubectl get pods -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}' | 
    ForEach-Object { $_ -split ' ' } | 
    Where-Object { $_ -match '^console-analysis-node' }

foreach ($pod in $pods) {
    Write-Host "=== Pod: $pod ==="
    $CmdString = "kubectl exec $pod -n $NAMESPACE -- sh -c `"tar cf - /usr/share/CAST/CAST/Logs 2>/dev/null`" > `"$DEST\$pod-Logs.tar`""
    cmd.exe /c $CmdString
}

# Other pods
$SERVICES = @{
  "viewer-server"    = "/opt/imaging/imaging-service/logs"
  "viewer-etl"       = "/opt/imaging/imaging-etl/logs"
  "console-postgres" = "/var/lib/pgsql/data/userdata/log"

}
foreach ($SVC in $SERVICES.Keys) {
  $POD = kubectl get pod -n $NAMESPACE -l "imaging.service=$SVC" -o jsonpath='{.items[0].metadata.name}' 2>$null
  if (-not $POD) {
    Write-Host "No pod found for $SVC, skipping."
    continue
  }
  $LOGPATH = $SERVICES[$SVC]
  if ($SVC -eq "console-postgres") {
    # Read the actual PGDATA from the container (RHEL postgresql image: /var/lib/pgsql/data/userdata)
    $PGDATA = kubectl exec $POD -n $NAMESPACE -c console-postgres -- printenv PGDATA 2>$null
    if ($PGDATA) { $LOGPATH = "$($PGDATA.Trim())/log" }
  }
  Write-Host "=== Copying logs from $POD ($SVC) ==="
  kubectl cp -n $NAMESPACE "${POD}:$LOGPATH" "$DEST/$SVC"
}

# Retrieving standard output log from all pods
# Single pipeline into Out-File keeps the file open once (Add-Content per line causes file-lock errors)
Write-Host  "=== Retrieving std-out logs from all pods ==="
& {
  foreach ($pod in $(kubectl get pods -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}').Split(' ')) {
    "=== Pod: $pod ==="
    kubectl logs $pod -n $NAMESPACE --all-containers=true --prefix=true --tail=-1
  }
} | Out-File -FilePath "$DEST/all-pods-stdout.log" -Encoding utf8

Write-Host "All logs collected in $DEST"
