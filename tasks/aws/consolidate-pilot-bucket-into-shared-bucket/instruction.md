The vera2 pilot's bucket is being retired, but its dataset belongs in the team's shared bucket first. Both are
in us-east-1: the source is the vera2- bucket ending in -pilot and the destination ends in -shared.

Consolidate the pilot dataset into the shared bucket under the same object keys, then leave the source empty.
Keep both buckets, preserve anything already in the shared bucket, and do not modify any other resources.