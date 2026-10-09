We are retiring the "vera2" trial integration in us-east-1 and returning the account to the platform group.
Part of closing this out is confirming that none of the pieces the trial spun up are still reachable by
anyone outside our own AWS account. Some of what vera2 created may, at one point, have been opened up for
sharing beyond the account boundary. Go through the resources belonging to vera2, find any that an outside
party can currently get to, and restrict each one so only our account retains access. By the time this is
finished, nothing carrying the vera2 label should be reachable from outside the account.