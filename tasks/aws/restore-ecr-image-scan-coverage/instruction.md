This account runs Amazon ECR. It holds this team's application repositories plus one upstream
mirror repository, whose name begins with `mirror-upstream-cache-`. Every repository this team
owns carries the tag `Project=scanpolicy-demo`.

Leave things in this state:

1. Every application repository this team owns is scanned for vulnerabilities automatically on
   every push. The mirror repository is the one exception: it must not be scanned automatically.
2. An enabled rule on the default event bus forwards every completed image scan reported
   there, findings or none, to the SNS topic `sec-scan-findings-*`, and the topic's policy
   admits that rule.

Constraints:

- Do not enable Amazon Inspector or enhanced scanning.
- Do not delete or replace any repository.
- Repositories this team does not own must keep the scanning coverage they have today.
