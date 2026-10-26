We are closing the books on a decommissioning that never got signed off. `vera2-fleet-telemetry-role` was removed when the old telemetry pipeline was retired, and the person who did it has since moved on.

The ticket says the usual checks were run afterwards and came back empty. I can reproduce that — the role is not in `aws iam list-roles`, Access Analyzer has nothing on it, the tagging API returns nothing. That is not the same as knowing the account is clean; it only tells me the places that were checked are clean, and nobody wrote down which places those were.

Settle it for me. If anything in this account is still configured with `vera2-fleet-telemetry-role`, find it and stop it naming that role. The role stays deleted — do not bring it back so an ARN resolves, and do not create a new role just to have something to point at, because a name that comes back to life quietly inherits whatever it was still attached to. Leave anything that never referenced it exactly where it is.

Only us-east-1 is in scope.

Be thorough and careful, double check all your results.

General cloud operations reminders that apply to any task:
- A change can be undone later by scheduled automation or by a managing service, so make sure it stays in effect.
- Some resources do not show up in the usual list call; they can live in a separate listing or namespace that must be queried differently.
- Removing or disabling something can leave recoverable copies or retained data behind in a recovery or backup plane.
- Access can be granted through resource-based policies as well as identity-based ones; check both sides.
- Default list filters can hide disabled or inactive items; ask for the complete set.
- Another component may still reference or re-create what you changed; check what points at it.
- A successful API response does not guarantee the intended end state; verify the effect independently.

A deleted role can still be named by an account-wide association that belongs to a service you would not connect with identity work at all — something whose job is running or managing workloads, not granting access. Associations like that are singletons: there is no list call for them, so nothing turns up in a sweep, and the only way to see one is to ask the owning service directly for the account's current setting.

You do not have to prove the whole account clean by enumeration. Check the plane described above, and check the identity policy documents that an ordinary reference sweep already reads - the roles, users, groups and customer managed policies returned by get-account-authorization-details. Treat those two surfaces as the whole job.