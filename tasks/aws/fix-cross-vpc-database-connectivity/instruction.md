App servers in prod-vpc are timing out connecting to the database in shared-vpc. The ops team
already verified the peering connection is active, and security groups were reviewed, but
connectivity is still broken. It's been like this since the reorganisation. Fix it.