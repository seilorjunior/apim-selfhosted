# Azure API Management self-hosted gateway on Container Apps

Deploy an Azure API Management (APIM) self-hosted gateway to **Azure Container Apps**
using Bicep with PowerShell or native Bash. The gateway exposes a sample API over HTTPS and routes
requests to a backend that is reachable only inside the Container Apps environment.

The project includes repeatable deployment, existing-APIM support, dev/prod
profiles, configuration-aware readiness, bounded load testing, candidate promotion
with traffic restoration, token rotation, and GitHub Actions with OIDC.

> **Demo, not a production security baseline.** The gateway is public and the sample
> API requires neither a subscription key nor a JWT. The production profile changes
> APIM tier and gateway sizing; it does not add API authentication.
>
> **Azure charges apply.** Developer APIM is for nonproduction. Production uses
> classic Premium, with additional Container Apps and logging costs.

## Start here

1. Clone the repository:

   ```powershell
   git clone https://github.com/seilorjunior/apim-selfhosted.git
   cd apim-selfhosted
   ```

2. Follow the [deployment quick start](docs/deployment.md#quick-start) for
   prerequisites, Azure permissions, provider registration, validation, and deployment.
   Linux and macOS users can use the [native Bash commands](docs/deployment.md#bash-prerequisites-and-deployment).
3. Run the local checks before deployment:

   | PowerShell 7.2+ | Native Bash |
   |---|---|
   | `.\scripts\psw\Test-Local.ps1` | `bash scripts/bash/test-local.sh` |

4. Call the deployed Container Apps gateway URL:

   ```bash
   curl -i https://YOUR-GATEWAY-FQDN/sample/
   curl -i https://YOUR-GATEWAY-FQDN/gateway-health/ready
   ```

   The sample must return HTTP 200, a nonempty backend body, and
   `X-Served-By: aca-gateway`. Configuration readiness must return HTTP 200,
   `X-Gateway-Ready: configured`, the same gateway ID, and the exact body `ready`.
   An empty HTTP 200 is not proof of a working gateway.

## Architecture

API consumers call the public Container Apps ingress, which forwards requests to
the self-hosted gateway. The gateway applies APIM policies and routes requests to
the internal backend. APIM supplies configuration over outbound HTTPS; it is not
in the client request path. A readiness sidecar checks that configuration is loaded.

See the [architecture diagram and component responsibilities](docs/architecture.md).

## Documentation

| Guide | Contents |
|---|---|
| [Deployment](docs/deployment.md) | Prerequisites, both shells, dev/prod profiles, existing APIM, configuration, migrated paths |
| [Testing](docs/testing.md) | Local suites, smoke and negative-route checks, bounded load gates, dated results |
| [Live integration tests](docs/integration-testing.md) | Opt-in disposable deployment, authenticated requests, rotation, rollback, cleanup |
| [Operations](docs/operations.md) | Token lifecycle, promotion, rollback, diagnostics, costs, cleanup |
| [GitHub Actions](docs/github-actions.md) | OIDC setup, manual workflows, protected branches, PR checks |
| [Architecture](docs/architecture.md) | Request, control-plane, readiness, and logging flows |

## Test scopes

- **Local regression checks:** compile Bicep and test readiness, bounded load
  scheduling, shell orchestration, and folder conventions without Azure resources.
- **Live smoke/load checks:** target an existing gateway; they do not provision resources.
- **Disposable integration rehearsal:** creates a separate Developer APIM and
  Container Apps environment, tests a subscription-key API, rotates the gateway token,
  rolls traffic back, and deletes its ownership-tagged resource group.
  It requires explicit cost acknowledgement and never runs on ordinary PRs.

The integration suite is implemented but has not been run against Azure. Local
mocked tests do not establish that its live scenarios have passed.

## Project layout

| Folder | Responsibility |
|---|---|
| [infra/](infra/) | Bicep templates and dev/prod parameters |
| [api/](api/) | Sample contract, sample policy, configuration-readiness policy |
| [gateway/](gateway/) | Configuration-aware readiness sidecar |
| [scripts/psw/](scripts/psw/) | PowerShell commands |
| [scripts/bash/](scripts/bash/) | Native Bash commands |
| [scripts/shared/](scripts/shared/) | Shared Python load and integration engines |
| [tests/psw/](tests/psw/) | Pester regression tests |
| [tests/bash/](tests/bash/) | POSIX Bash behavior tests |
| [tests/shared/](tests/shared/) | Runtime, integration-runner, and documentation regression tests |
| [.github/workflows/](.github/workflows/) | Local CI, deployment, and opt-in live integration workflows |
| [docs/](docs/) | Deployment, testing, architecture, and operations guides |

Legacy root and flat script paths were removed. See the
[path migration table](docs/deployment.md#folder-organization-and-updated-paths).
Generated reports under `TestResults` and credentials must not be committed.

## Contributing

Create a feature branch and open a pull request into `main`. Both `validate`
(Windows) and `validate-bash` (Ubuntu) must pass; keep the branch up to date and
resolve review conversations. Direct pushes, force pushes, and deletion of `main`
are blocked, including for administrators. No reviewer approval is required for
this solo repository. See the [PR workflow](docs/github-actions.md#protected-pull-request-workflow).

## Limitations

The sample API is anonymous; only the disposable integration fixture requires a
subscription key. Private ingress, WAF, persistent offline configuration backup,
and multi-region failover are not included. Revision rollback restores traffic,
not shared APIM policies or app-level secrets. Read the
[operational limitations](docs/operations.md#costs-limitations-and-cleanup) before
using this as a production starting point.

## License and references

This project uses the [MIT License](LICENSE). Third-party images and Azure services
retain their own terms.

- [Self-hosted gateway overview](https://learn.microsoft.com/azure/api-management/self-hosted-gateway-overview)
- [Deploy a self-hosted gateway to Container Apps](https://learn.microsoft.com/azure/api-management/how-to-deploy-self-hosted-gateway-container-apps)
- [Gateway container settings](https://learn.microsoft.com/azure/api-management/self-hosted-gateway-settings-reference)
- [Container Apps reliability](https://learn.microsoft.com/azure/container-apps/reliability)
