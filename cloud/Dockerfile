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

# Node LTS: Ubuntu's own (18) is too old for current packages.
FROM node:24-bookworm-slim AS node

FROM ubuntu:24.04
# What agents and moved projects expect to find; anything else is installed by the user.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash ca-certificates openssl curl git rsync openssh-client build-essential python3 python3-venv \
        less vim-tiny locales tzdata \
    # The 1Password CLI, from 1Password's apt repository.
    && curl -fsSL https://downloads.1password.com/linux/keys/1password.asc -o /usr/share/keyrings/1password.asc \
    && echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/1password.asc] https://downloads.1password.com/linux/debian/amd64 stable main' \
        > /etc/apt/sources.list.d/1password.list \
    && apt-get update && apt-get install -y --no-install-recommends 1password-cli \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen \
    # The image's own user would take uid 1000 from the machine's user.
    && (userdel -r ubuntu 2>/dev/null || true) \
    # As on a Mac, /tmp is a link to /private/tmp: agents key conversations by the real path of
    # their folder, and moved tabs keep their paths.
    && mkdir -p /private && mv /tmp /private/tmp && ln -s private/tmp /tmp && chmod 1777 /private/tmp
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
# The agents a moved tab resumes. They update with the image (agterm-profile.sh turns off their
# own updaters, which can't write here).
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && npm install -g @anthropic-ai/claude-code @openai/codex \
    && npm cache clean --force
COPY --from=build /agterm-sessions /usr/local/bin/agterm-sessions
COPY cloud/entrypoint.sh /usr/local/bin/agterm-cloud
COPY cloud/agterm-profile.sh /etc/profile.d/agterm.sh
ENV LANG=en_US.UTF-8
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/agterm-cloud"]
