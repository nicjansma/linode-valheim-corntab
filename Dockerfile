# Start from php-fpm
FROM ubuntu:latest

#
# Arguments (build)
#

# linux packages to install
ARG RUNTIME_PACKAGE_DEPS="curl python3 python3-pip pipx jq"

#
# Build repo
#

# install dependencies and cleanup in one step
RUN apt-get update -y \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        $RUNTIME_PACKAGE_DEPS \
    && apt-get clean \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/share/doc/* /var/log/dpkg.log

#
# linode-cli
#

RUN pipx install linode-cli

ENV PATH=$PATH:/root/.local/bin

RUN mkdir -p /root/.config/

#
# AWS CLI
#
RUN pipx install awscli

#
# Cron via supercronic
#

# Latest releases available at https://github.com/aptible/supercronic/releases
ENV SUPERCRONIC_URL=https://github.com/aptible/supercronic/releases/download/v0.2.33/supercronic-linux-amd64 \
    SUPERCRONIC_SHA1SUM=71b0d58cc53f6bd72cf2f293e09e294b79c666d8 \
    SUPERCRONIC=supercronic-linux-amd64

RUN curl -fsSLO "$SUPERCRONIC_URL" \
 && echo "${SUPERCRONIC_SHA1SUM}  ${SUPERCRONIC}" | sha1sum -c - \
 && chmod +x "$SUPERCRONIC" \
 && mv "$SUPERCRONIC" "/usr/local/bin/${SUPERCRONIC}" \
 && ln -s "/usr/local/bin/${SUPERCRONIC}" /usr/local/bin/supercronic

RUN mkdir -p /etc/cron.minutely
RUN mkdir -p /etc/cron.5minutes
RUN mkdir -p /etc/cron.10minutes
RUN mkdir -p /etc/cron.15minutes
RUN mkdir -p /etc/cron.hourly
RUN mkdir -p /etc/cron.daily
RUN mkdir -p /etc/cron.weekly
RUN mkdir -p /etc/cron.monthly

COPY crontab /etc/crontab

#
# Scripts
#
COPY --chmod=755 ./launch-valheim-server.sh /root/
COPY --chmod=755 ./stop-valheim-server.sh /root/
COPY --chmod=755 ./discord-notify.sh /root/

COPY --chmod=755 ./docker-entrypoint.sh /root/docker-entrypoint.sh

#
# Entrypoint
#
CMD ["/root/docker-entrypoint.sh"]
