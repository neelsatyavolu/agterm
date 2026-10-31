# agterm Cloud: one user's machine (docs/cloud-sessions-plan.md). Build from the repo root:
#   docker build -f cloud/Dockerfile .
FROM swift:6.4-noble AS build
WORKDIR /src
COPY Package.swift Package.resolved ./
COPY Sources Sources
COPY Vendor Vendor
COPY Tests Tests
RUN swift build -c release --product agterm-sessions --static-swift-stdlib \
    && cp "$(swift build -c release --show-bin-path)/agterm-sessions" /agterm-sessions

FROM ubuntu:24.04
# What agents and moved projects expect to find; anything else is installed by the user.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash ca-certificates openssl curl git rsync openssh-client build-essential python3 python3-venv \
        nodejs npm less vim-tiny locales tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen \
    # The image's own user would take uid 1000 from the machine's user.
    && (userdel -r ubuntu 2>/dev/null || true) \
    # As on a Mac, /tmp is a link to /private/tmp: agents key conversations by the real path of
    # their folder, and moved tabs keep their paths.
    && mkdir -p /private && mv /tmp /private/tmp && ln -s private/tmp /tmp && chmod 1777 /private/tmp
COPY --from=build /agterm-sessions /usr/local/bin/agterm-sessions
COPY cloud/entrypoint.sh /usr/local/bin/agterm-cloud
ENV LANG=en_US.UTF-8
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/agterm-cloud"]
