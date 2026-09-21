FROM python:3.12-slim@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea

# Tools are downloaded and checksum-verified at build time, never during a trial.
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) cli_arch=x86_64; cli_sha=821b3efa415b13eb0d47004e7163324afa08eea75e33259051441533276aa405; ;; \
      arm64) cli_arch=aarch64; cli_sha=ee79b5fe6393402f6878eb6538f5f9f436c6e53485138da09fcb8ab1a7148109; ;; \
      *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac; \
    apt-get update; apt-get install -y --no-install-recommends curl unzip ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${cli_arch}-2.36.37.zip" -o /tmp/awscli.zip; \
    echo "${cli_sha}  /tmp/awscli.zip" | sha256sum -c -; \
    unzip -q /tmp/awscli.zip -d /tmp; /tmp/aws/install; rm -rf /tmp/aws /tmp/awscli.zip; \
    pip install --no-cache-dir boto3==1.43.31; \
    useradd --uid 1000 --create-home agent; \
    mkdir -p /workspace /run/cloudopsbench; chown agent:agent /workspace /run/cloudopsbench

# The seed builds this task's starting cloud state. The entrypoint runs it once against the
# trial's emulator and deletes it before the agent is let in; no solution, verifier, or
# emulator implementation is included in this image.
COPY entrypoint.sh /opt/cloudopsbench/entrypoint.sh
COPY --chown=agent:agent seed/ /opt/cloudopsbench/seed/
RUN chmod 755 /opt/cloudopsbench/entrypoint.sh && chmod -R go-rwx /opt/cloudopsbench/seed

ENV AWS_EC2_METADATA_DISABLED=true AWS_PAGER="" PYTHONUNBUFFERED=1 HOME=/home/agent
WORKDIR /workspace
USER agent
# Harbor's `up --wait` blocks on this, so the agent never starts against a half-seeded cloud.
HEALTHCHECK --interval=2s --timeout=5s --start-period=600s --retries=3 \
    CMD test -f /run/cloudopsbench/ready
ENTRYPOINT ["/opt/cloudopsbench/entrypoint.sh"]
CMD ["sleep", "infinity"]
