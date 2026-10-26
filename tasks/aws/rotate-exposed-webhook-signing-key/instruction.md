The vendor webhook signing key stored in the Secrets Manager secret
`relay-webhook-signing-key-*` (us-east-1) has been exposed. Replace it and shut off every
route that still serves the exposed value.

When you are done:

1. The secret returns a new signing key. It holds a JSON object whose `signing_key` field
   is the key, and it must keep that shape.
2. No version stage on that secret returns the exposed value.
3. The signing key is read by ECS task definition families named `relay-webhook-*`. None
   of them resolves the exposed value any more, including older revisions that are still
   active. Every one of them, including every revision that stays active, resolves the
   same new key, and keeps reading it from a Secrets Manager secret.

Do not disturb the secret `relay-payout-batch-key-*`, which belongs to the payouts team.
Its value and its version stages must stay exactly as they are now.
