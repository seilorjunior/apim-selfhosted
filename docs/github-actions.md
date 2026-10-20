# Github Actions

[Project overview](../README.md). Run commands from the repository root.

## GitHub Actions

| Workflow | Trigger | Behavior |
|---|---|---|
| [CI](../.github/workflows/ci.yml) | Pull requests and pushes to `main` | Bicep builds and local regression tests |
| [Deployment](../.github/workflows/deploy.yml) | Manual dispatch | `validate`, `deploy`, or `rotate`; defaults to validation |
| Same deployment workflow | Opt-in schedule | Weekly token rotation; never provisions initial infrastructure |

CI validates PowerShell on Windows and native Bash on Ubuntu. The deployment
workflow uses Windows and PowerShell. No repository, Azure identity, or GitHub
environment is provisioned by these files.

1. Push the project to a GitHub repository.
2. Create GitHub environments `dev` and `prod`. Configure required reviewers and
   allowed deployment branches for prod before using it. YAML alone cannot enforce
   environment protection.
3. Configure an Entra application/service principal or user-assigned managed
   identity with GitHub OIDC federation and the
   [deployment permissions](deployment.md#1-check-prerequisites):
   - Issuer: `https://token.actions.githubusercontent.com`
   - Audience: `api://AzureADTokenExchange`
   - Subject: `repo:OWNER/REPO:environment:dev` or `repo:OWNER/REPO:environment:prod`
4. Set the following **GitHub environment variables**, not client secrets:

   | Variable | Required value |
   |---|---|
   | `AZURE_CLIENT_ID` | Federated identity client ID |
   | `AZURE_TENANT_ID` | Tenant ID |
   | `AZURE_SUBSCRIPTION_ID` | Target subscription ID |
   | `AZURE_RESOURCE_GROUP` | Precreated target resource group |
   | `AZURE_LOCATION` | Optional; defaults to `eastus2` |
   | `APIM_PUBLISHER_EMAIL` | Required when creating APIM |
   | `EXISTING_APIM_NAME` | Optional existing APIM service |
   | `APIM_RESOURCE_GROUP` | Optional existing APIM resource group |

5. Dispatch `validate`, review what-if, then dispatch `deploy`. Local checks and
   live verification must pass for a successful deployment job.
   Enable the manual `load_test` input to run the capped candidate load gate.
   Load reports are uploaded as workflow artifacts, including failed gate results.
   Scheduled token rotation does not enable load testing.

To enable weekly rotation, set repository variable `ENABLE_SCHEDULED_ROTATION`
to `true` and `SCHEDULED_ROTATION_ENVIRONMENT` to `dev` or `prod` (default: `dev`).
The schedule runs **Mondays at 06:00 UTC**, from the default branch, for one
environment. Protected environments still require approval before the token expires.
Use separate workflows/schedules if both environments need automatic rotation.

Actions serializes deployments per environment. Do not deploy locally at the same
time as a workflow targeting that environment. Generated token files are not
published as workflow artifacts.

## Protected pull-request workflow

The repository's `main` branch requires:

- A pull request, including for administrators.
- Successful `validate` (Windows) and `validate-bash` (Ubuntu) checks from GitHub Actions.
- A branch up to date with `main`.
- Resolved review conversations.
- No force pushes or deletion.
- Zero required approvals, so a solo maintainer can merge after checks pass.

These are GitHub repository settings, not protections enforced by YAML in forks.
Configure them separately when copying the project. Keep required check names
aligned with the job identifiers in [ci.yml](../.github/workflows/ci.yml).

```bash
git switch -c feat/my-change
# Make and locally validate the change.
git add PATHS-TO-CHANGED-FILES
git commit -m "feat: describe the change"
git push -u origin feat/my-change
gh pr create --base main --head feat/my-change --fill
gh pr checks --watch
```

Use the GitHub PR page to review and merge after the checks pass. Publishing a PR
does not deploy Azure resources. The live integration workflow is manual-only and
is not a required PR check.

## Disposable integration workflow

[integration.yml](../.github/workflows/integration.yml) creates a new isolated
environment, exercises real API requests, token rotation, and traffic rollback,
then attempts ownership-checked cleanup.

It uses a separate `integration` GitHub environment and requires the exact
confirmation `CREATE DISPOSABLE RESOURCES`. It has no schedule or PR trigger.
See [setup, costs, scenarios, and recovery](integration-testing.md) before dispatch.
The workflow and its OIDC identity do not provision themselves.
