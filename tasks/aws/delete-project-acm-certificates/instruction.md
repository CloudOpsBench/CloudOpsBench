We are decommissioning the "vera2" project and need to clean up its TLS certificates.
Please delete all of our vera2 ACM certificates in us-east-1 — their domain names all
start with "vera2-". None of them are attached to a load balancer, API Gateway, or
CloudFront distribution, so they can be deleted safely. Remove every vera2 certificate.