<!-- markdownlint-disable-file MD041 -->
## Phase and summary

<!-- Which phase (or fix) is this, and what does it change? -->

## Changed files

## Validation

<!-- Static checks run (tests/Invoke-StaticValidation.ps1) and live checks, with statuses:
Pass, Fail, Warning, Manual action required, Not supported, Not selected. Mark live checks
"pending go-ahead" when they haven't run. -->

## Risks

## Checklist

- [ ] No secrets, tokens, real subscription IDs, or tenant IDs in code, docs, logs, or notebook outputs
- [ ] Every Azure CLI call goes through the subscription guard (`Invoke-DemoAz`) and passes `--subscription`
- [ ] No calls to private Database Hub routes; only documented interfaces
- [ ] ADRs, docs, and `docs/implementation-report.md` updated where the decision or behavior changed
- [ ] `config/versions.json` updated for any new pinned version or action SHA
