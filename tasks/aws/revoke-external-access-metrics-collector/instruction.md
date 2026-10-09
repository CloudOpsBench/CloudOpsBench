We are retiring the vera2 metrics collector in us-east-1 and returning this account to the pool. Part of
shutting it down cleanly is confirming that none of the vera2 pieces can still be touched by anyone outside
this account. During its life a handful of the things vera2 created may have been opened up for parties beyond
our own account, and those grants need to be pulled back. Go through the vera2 footprint, find whatever an
outsider is presently able to get at, and narrow each one so only this account retains access. Once you
have finished, there should be nothing left under vera2 that is reachable from beyond the account boundary.