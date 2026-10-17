# HostOps startup callback

`scripts/Start-HostOpsService.ps1` is this service's owner callback. HostOps
invokes it using `-HostOpsRoot`, `-ConfigPath`, `-ReleaseGitSha` and optional
`-RecoveryBarrierId`. No new scheduler, process manager or service is installed.

`-InspectOnly` checks existing health without starting tasks, services or
containers, performing recovery, or modifying the lifecycle context.
The service contract is in `config/startup-contract.json`; it contains no secrets.

Implementation is a mechanical extraction of the established Runtime behavior.
Shared storage/recovery context remains supplied by the existing harness.

Normal startup observes existing restart-always recovery. Same-session recovery
uses the existing exact recorded-workload restore owner before health acceptance.
