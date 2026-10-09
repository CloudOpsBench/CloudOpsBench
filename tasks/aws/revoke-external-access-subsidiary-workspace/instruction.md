We are offboarding the vera3 subsidiary workspace in us-east-1. The account is going back to central IT, and
before that handover we have to be certain that nothing the vera3 team stood up can still be touched from
outside our AWS account. Over the life of that workspace a handful of the things they created may have been
opened up to parties beyond our own account. Go through every vera3 resource that an outside party could
currently reach and close it down so that only our own account retains access. By the time you finish, no vera3
resource should be reachable from anywhere outside the account.