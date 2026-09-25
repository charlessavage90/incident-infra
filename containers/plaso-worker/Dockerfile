# syntax=docker/dockerfile:1
#
# The base is supplied as a build argument by modules/images/buildspec.yml, and
# it is always a DIGEST resolved seconds earlier in the same build. That is what
# makes the spec 4.5 parity invariant structural rather than a matter of
# discipline: the log2timeline.py in this image is the one the appliance's
# Timesketch reads .plaso files back with.
#
# Never replace this with a tag. Timesketch installs plaso-tools unpinned from
# ppa:gift, so two builds of one release tag can carry different plaso versions,
# and Timesketch rejects a .plaso produced by a newer plaso than it runs.
#
# One package is installed, at BUILD time. The Timesketch image carries plaso and
# requests in /opt/venv but NOT boto3 -- an earlier draft of this file assumed it
# did, and every job died on `import boto3` (Phase 3 acceptance, defect 6).
# Build time is CodeBuild, which runs outside the VPC with an internet route, so
# this does not contradict the VPC having none. Pinned to the version the
# worker's test suite runs against; bump the two together.
ARG TIMESKETCH_BASE
FROM ${TIMESKETCH_BASE}

RUN /opt/venv/bin/python3 -m pip install --no-cache-dir boto3==1.43.94

COPY worker.py /usr/local/bin/worker.py
COPY timesketch_client.py /usr/local/bin/timesketch_client.py

ENV PYTHONPATH=/usr/local/bin
ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python3", "/usr/local/bin/worker.py"]
