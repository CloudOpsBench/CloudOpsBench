We are retiring the vera2 metrics collector in us-east-1 and returning this account to the pool. Part of
shutting it down cleanly is confirming that none of the vera2 pieces can still be touched by anyone outside
this account. Some of what vera2 created may have been opened to parties outside our account, and those grants
need to be pulled back. Go through the vera2 footprint, find whatever an outsider can currently reach, and
narrow each one so only this account retains access. When you are done, nothing under vera2 should be
reachable from outside the account.
