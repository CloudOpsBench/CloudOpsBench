FROM python:3.12-slim@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea

RUN pip install --no-cache-dir boto3==1.43.31 \
    && useradd --uid 1000 --create-home agent \
    && mkdir -p /workspace \
    && chown agent:agent /workspace
ENV AWS_EC2_METADATA_DISABLED=true PYTHONUNBUFFERED=1
WORKDIR /workspace
USER agent
# Harbor keeps this container alive. No verifier or reference solution is baked in.
