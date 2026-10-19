The vera2 checkout service is moving to a new database. Point it at the new endpoint:

    aurora-pg.vera2.internal

The checkout service reads its database endpoint from AWS Systems Manager Parameter Store (the relevant
parameter lives under the /vera2/ path). Update the configuration so the checkout service uses the new
database.

When you are finished, the database endpoint the checkout service loads must be aurora-pg.vera2.internal.