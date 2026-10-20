# Testing

[Project overview](../README.md). Run commands from the repository root.

For the opt-in disposable Azure rehearsal, see
[live integration testing](integration-testing.md). Ordinary local checks test
the runner with mocked process and HTTP boundaries; they never provision resources.

## Testing and verified results

### Choose a test scope

The examples in this section use PowerShell 7.2+ from the repository root. For
Linux/macOS equivalents, see [native Bash commands](deployment.md#powershell-and-native-bash-commands). Use the
[prerequisites](deployment.md#1-check-prerequisites) for Python, Pester, and Bicep.

| Scope | Requirements | Effect |
|---|---|---|
| Local regression suite | Local tools; no Azure sign-in | Builds templates and runs mocked deployment and runtime tests |
| Live readiness and smoke checks | An existing gateway; network access to its HTTPS origin | Sends a few requests; no deployment or restart |
| Bounded load test | Permission to test the target environment | Sends up to 600 requests; can generate Azure usage/logging charges |
| Candidate load gate | Azure deployment permissions and settings | Deploys a candidate and conditionally promotes it; see [safe rollout](operations.md#safe-rollout-and-rollback) |

Run local tests first, then live functional checks, then the load test. Restart
and outage rehearsals are separate operations and are not part of this sequence.

### Local regression tests

```powershell
.\scripts\psw\Test-Local.ps1
```

Builds both templates, parses PowerShell scripts, and runs the
[Pester deployment suite](../tests/psw/Project.Tests.ps1),
[rollout/rollback suite](../tests/psw/Rollout.Tests.ps1), and
[Python runtime tests](../tests/shared/test_runtime.py). They cover configuration guards, internal
ingress, probes/scaling, secure token parameters, raw/prefixed token handling,
fresh revisions, cleanup of temporary files, smoke retries, and mocked deployment
and restart flows, false-positive readiness, load thresholds/pacing/concurrency,
promotion ordering, traffic restoration, and rollback safeguards.
Azure dependencies are mocked; no Azure sign-in or resource
changes are needed, although the CLI tools must be installed.

Success prints Python `OK` and a Pester summary with zero failures. The current
suite contains 35 shared Python tests and 52 Pester tests, plus 24 native Bash
behavior tests on POSIX hosts. Any build, parse, or test
failure stops the script with an error.

#### Run a specific suite

Use the full local runner for Bicep compilation, script parsing and Pester tests:

```powershell
.\scripts\psw\Test-Local.ps1
```

The Pester infrastructure tests require the compiled-template directory supplied
by that runner. Do not invoke them directly without that setup.

For a faster check of shared Python behavior only:

```powershell
python -B -m unittest discover -s .\tests\shared -p 'test_*.py' -v
```

On Linux/macOS, run shared behavior or the isolated Bash harness separately:

```bash
python3 -B -m unittest discover -s tests/shared -p 'test_*.py' -v
python3 -B -m unittest discover -s tests/bash -p 'test_*.py' -v

# Includes real Bicep builds, Bash syntax checks and both Python suites.
bash scripts/bash/test-local.sh
```

The Bash harness uses Python's standard library to execute native Bash commands
against temporary Azure CLI, Bicep and HTTP doubles. It requires a POSIX host,
Bash and jq, and skips explicitly on Windows. It tests deployment validation,
token handling, promotion order, failed-candidate restoration, rollback,
confirmation prompts and load caps without calling Azure.

#### Validation after folder reorganization

| Validation | Result |
|---|---|
| Windows PowerShell runner | 52 Pester and 15 shared Python tests passed; 24 POSIX Bash tests skipped as expected |
| Linux Bash runner in WSL | 24 Bash behavior and 15 shared Python tests passed |
| Templates and script checks | Both Bicep templates built; PowerShell parsing and Bash syntax checks passed |
| Azure changes | None; folder reorganization did not deploy, restart or move traffic |

That folder-reorganization snapshot had **91 distinct regression tests** across
all suites. The integration-runner and documentation additions bring the current
suite to **111 distinct regression tests**: 52 Pester, 35 shared Python, and
24 native Bash tests. The shared suite runs on both operating systems and is
counted once.
Shared Python tests run on both platforms; do not count those twice.
Linux validation covers the Bash orchestration with mocks, not a live Azure
deployment using Bash.

### Live smoke and negative-route checks

Set the origin for your deployment. Do not include `/sample/` in `$gatewayUrl`.
If the quick-start variables are already set, retrieve the address with:

```powershell
$appName = 'ca-apim-gateway'
$expectedGatewayId = 'aca-gateway'
$fqdn = az containerapp show --name $appName `
    --resource-group $resourceGroup --subscription $subscriptionId `
    --query properties.configuration.ingress.fqdn --output tsv
if ($LASTEXITCODE -ne 0 -or !$fqdn) { throw 'Cannot resolve the gateway origin.' }
$gatewayUrl = "https://$fqdn"
```

Alternatively, set `$gatewayUrl` directly to your deployed HTTPS origin. Azure
CLI sign-in is needed for address discovery, not for public HTTP checks. For prod,
set `$appName = 'ca-apim-gateway-prod'` and
`$expectedGatewayId = 'aca-gateway-prod'`.

Verify loaded configuration and backend routing:

```powershell
. .\scripts\psw\Common.ps1
Wait-GatewayConfiguration -GatewayUrl $gatewayUrl `
    -ExpectedGatewayId $expectedGatewayId -TimeoutSeconds 60

.\scripts\psw\Test-Gateway.ps1 -GatewayUrl $gatewayUrl `
    -ExpectedGatewayId $expectedGatewayId -TimeoutSeconds 60

$sample = Invoke-WebRequest -Uri "$gatewayUrl/sample/" -TimeoutSec 15
if ($sample.StatusCode -ne 200 -or
    [string]$sample.Headers['X-Served-By'] -cne $expectedGatewayId -or
    $sample.RawContentLength -le 0) {
    throw 'Sample response status, gateway identity, or body is invalid.'
}
```

Inspect negative routes:

```powershell
curl.exe -i "$gatewayUrl/not-found"
curl.exe -i -X POST "$gatewayUrl/sample/"
```

Both responses must be HTTP 404. `curl.exe` displays those responses but does
not fail automatically for HTTP error status codes. To assert them in a script:

```powershell
foreach ($test in @(
    @{ Path = '/not-found'; Method = 'GET' },
    @{ Path = '/sample/'; Method = 'POST' }
)) {
    $response = Invoke-WebRequest -Uri "$gatewayUrl$($test.Path)" `
        -Method $test.Method -TimeoutSec 15 -SkipHttpErrorCheck
    if ($response.StatusCode -ne 404) {
        throw "Expected HTTP 404 for $($test.Method) $($test.Path); got $($response.StatusCode)."
    }
}
```

| Check | Expected response |
|---|---|
| `GET /gateway-health/ready` | HTTP 200, `X-Gateway-Ready: configured`, expected `X-Served-By`, exact body `ready` |
| `GET /sample/` | HTTP 200, expected `X-Served-By`, nonempty backend body |
| `GET /not-found` | HTTP 404 |
| `POST /sample/` | HTTP 404 because the operation is not configured |

Readiness and smoke helpers retry for up to the supplied timeout and throw if
their checks never pass. An empty HTTP 200 is not proof of a configured gateway.
HTTP requests to public ingress redirect to HTTPS.

### Bounded load test

Run against an environment you own and have permission to test:

```powershell
# Short preliminary run: at most 100 scheduled requests.
.\scripts\psw\Test-Load.ps1 -GatewayUrl $gatewayUrl `
    -ExpectedGatewayId $expectedGatewayId `
    -RequestsPerSecond 10 -DurationSeconds 10 -MaxConcurrency 10

# Full bounded run: at most 600 scheduled requests.
.\scripts\psw\Test-Load.ps1 -GatewayUrl $gatewayUrl `
    -ExpectedGatewayId $expectedGatewayId `
    -RequestsPerSecond 10 -DurationSeconds 60 -MaxConcurrency 10
```

The script caps requests at **10 RPS, 60 seconds, and 10 in flight**: at most
600 scheduled requests. Each request must return HTTP 200, the expected gateway
header, and a nonempty body. Redirects fail. Requests time out after five seconds.
It uses fixed monotonic-clock slots rather than accumulating sleep overhead.
There is at most one submission per scheduled slot; expired slots are dropped
rather than replayed in catch-up bursts. Saturated or missed slots are reported
as dropped requests. Individual send times remain subject to client scheduling
jitter.

Default gates are **p95 <= 2,000 ms**, **error rate <= 1%**, and **zero dropped
requests**. Errors include failed requests and dropped slots. The script exits
nonzero when a gate fails. Optional `-MaxP95Milliseconds`, `-MaxErrorRate`, and
`-OutputPath` customize gates/report location, not the hard load caps.

JSON reports default to ignored `TestResults/load-<timestamp>-<id>.json` and
include request counts, drops by reason, p95/p99/max latency, error rate, observed concurrency,
throughput, thresholds, and pass/fail. Latency includes client/network overhead;
this small test is **not a production capacity or autoscaling certification**.

### Read a load report and investigate failures

The command prints the report path, including when a threshold fails. Read that
specific report; do not substitute an older successful run. To inspect the latest
local report:

```powershell
$latestReport = Get-ChildItem -LiteralPath .\TestResults -Filter 'load-*.json' |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
if (!$latestReport) { throw 'No load report found.' }
$report = Get-Content -LiteralPath $latestReport.FullName -Raw | ConvertFrom-Json
$report | Select-Object passed, plannedRequests, startedRequests, `
    successfulRequests, failedRequests, droppedRequests, errorRate, `
    p95Ms, p99Ms, maxLatencyMs, maxObservedConcurrency
$report.droppedByReason
$report.failureExamples
```

| Report field or failure | Meaning and next check |
|---|---|
| `failedRequests` | Requests started but failed validation or transport; inspect `failureExamples`, readiness, and gateway/backend logs |
| `droppedByReason.concurrencyLimit` | A scheduled slot found all allowed requests in flight; inspect latency, client networking, and gateway/backend metrics |
| `droppedByReason.scheduleLate` | The client missed a scheduling slot; inspect client CPU load, scheduling delays, and competing tests |
| `droppedByReason.durationElapsed` | The client reached the end of the request-launch window before submitting a slot |
| `errorRate` | `(failedRequests + droppedRequests) / plannedRequests`; `0.01` means 1% |
| High `p95Ms` | Investigate client/network overhead and gateway/backend response latency |
| `passed: false` with zero failed requests | Drops or latency can still fail the overall gate; successful HTTP responses alone do not establish a pass |

The maximum duration bounds request scheduling; outstanding requests can finish
after that window. `maxObservedConcurrency` includes pending submitted work.
One run cannot establish whether saturation originates in the client, network,
gateway, or backend. Keep failed reports, investigate the cause, and record any
rerun separately. Do not silently relax thresholds or raise the hard load caps
to turn a failed run into a pass.

On GitHub, the [CI workflow](../.github/workflows/ci.yml) runs the local suite only.
The [deployment workflow](../.github/workflows/deploy.yml) can run the candidate load
gate with its manual `load_test` input and uploads generated reports. It requires
the Azure/OIDC configuration described in [GitHub Actions](github-actions.md#github-actions).

### Latest test snapshot: October 20, 2026

| Check | Observed result |
|---|---|
| Local suite | 52 Pester and 13 Python tests passed; Bicep builds and PowerShell parsing passed |
| Live functional checks | Configuration readiness and sample API passed; unknown route and unsupported POST returned 404 |
| Full bounded load | 600 scheduled; 598 started and succeeded; zero failed requests |
| Dropped slots | 2, both due to the concurrency limit |
| Latency | p95 445.85 ms; p99 900.57 ms; maximum 1,107.65 ms |
| Error rate including drops | 0.333%, within the 1% gate |
| Overall load verdict | Failed because the zero-dropped-request gate was not met |

This run did not restart, redeploy, or change traffic. It does not replace the
earlier successful candidate load result below; each result describes its own run.

### Observed results: October 19, 2026

The deployed dev environment was verified with the following results. These are
a **dated snapshot**, not a guarantee of future availability or performance.

| Check | Observed result |
|---|---|
| Bicep builds and local regressions | 33 tests passed; zero failures |
| `GET /sample/` | HTTP 200, nonempty backend HTML, `X-Served-By: aca-gateway` |
| Unknown route / unsupported POST | HTTP 404 / HTTP 404 |
| Gateway status endpoint | HTTP 200 |
| HTTP-to-HTTPS redirect | HTTP 301 |
| 20 sequential API requests | 20 passed; zero status/header/body failures |
| Request latency | Median 380.4 ms; p95 405.3 ms; max 422.5 ms |

The live negative checks and latency sample were run separately from the local
Pester suite. Latency includes client/network overhead. Twenty sequential requests
are **not a load test**, an autoscaling test, or evidence of production capacity.

### Readiness and controlled-rollout verification: October 19, 2026

The updated dev deployment was verified separately:

| Check | Observed result |
|---|---|
| Local regression suite | 52 Pester + 13 Python tests passed |
| Configuration-aware readiness | Healthy candidate; public `/gateway-health/ready` returns the exact markers and `ready` body |
| Candidate load | 600 scheduled/started; 599 successful, 1 request error (`URLError`), zero dropped |
| Load error rate | 0.167%, within the configured 1% maximum |
| Load latency | p95 585.34 ms; p99 797.40 ms; maximum 5,048.44 ms |
| Load concurrency | Maximum observed 9; configured cap 10 |
| Promotion | Verified candidate receives 100% of traffic; previous healthy release remains active at 0% |
| Failure handling | Earlier rejected candidates left previous traffic restored and the public API verified; failed candidates deactivated |
| Manual rollback | Live `-WhatIf` resolved the retained prior release without moving traffic |
| Public routes after promotion | Sample 200 with gateway header and 8,893-byte body; unknown route 404 |

The accepted load run retained the default gates; its single request error was
not hidden or treated as a success. Reports are local generated files, not
committed test fixtures. Manual rollback was previewed, not executed as a
traffic-switch rehearsal.
