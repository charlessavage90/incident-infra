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
# Nothing is installed here. The VPC has no internet route, so a RUN that
# reached for a package would fail at build time in CodeBuild's network and at
# runtime in ours -- and the whole point of deriving from the Timesketch image
# is that plaso and boto3 are already in it.
ARG TIMESKETCH_BASE
FROM ${TIMESKETCH_BASE}

COPY worker.py /usr/local/bin/worker.py
COPY timesketch_client.py /usr/local/bin/timesketch_client.py

ENV PYTHONPATH=/usr/local/bin
ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python3", "/usr/local/bin/worker.py"]
