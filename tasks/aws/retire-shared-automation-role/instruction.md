Region: us-east-1. Everything relevant to this task lives in this region.

Our platform team is retiring its shared automation role, fleet-maintenance-*.
The replacement role, ops-runner-*, has already been provisioned.

Complete the retirement:

1. Move everything onto the replacement role: every job, workflow, and
   access path that operates through the legacy role today must operate
   through the replacement role instead, and anything that would break or
   silently stop working once the legacy role no longer exists must keep
   working via the replacement.

2. After your change, no policy or configuration in this account may still
   reference the legacy role, not even as an unresolvable leftover.

3. Everything else must keep working exactly as it does today. Do not
   delete, disable, or reconfigure anything beyond what the migration
   requires, and do not remove or weaken anyone else's access.

4. Once nothing references it anymore, delete the legacy role.