# syntax=docker/dockerfile:1
#
# Minimal Selkies environment running xeyes, with real systemd as PID 1.
# s6-overlay is kept in the image only as a library (its helpers/scripts are
# reused by systemd units); it is no longer the init process.
# x86_64 only by design (no aarch64).

FROM ghcr.io/linuxserver/baseimage-selkies:debiantrixie

# set version label
ARG BUILD_DATE
ARG VERSION
LABEL build_version="version:- ${VERSION} Build-date:- ${BUILD_DATE}"
LABEL maintainer="jcleng"

# title + default application started by the session
# APP: command (with arguments) launched in the desktop session, override at runtime.
# container=docker: standard hint for systemd inside a container.
ENV TITLE=xeyes \
    PIXELFLUX_WAYLAND=true \
    APP=xeyes \
    container=docker

RUN \
  echo "**** add icon ****" && \
  { curl -fsSL -o /usr/share/selkies/www/icon.png \
      https://raw.githubusercontent.com/linuxserver/docker-templates/master/linuxserver.io/img/selkies-logo.png || \
    :; } && \
  echo "**** install packages ****" && \
  apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    x11-apps \
    xterm \
    systemd \
    systemd-sysv \
    openssh-server \
    docker-compose-plugin \
    ca-certificates \
    curl \
    wget \
    unzip \
    zstd \
    tar && \
  echo "**** avoid socket-vs-service conflicts ****" && \
  rm -f /etc/systemd/system/sockets.target.wants/ssh.socket \
        /etc/systemd/system/sockets.target.wants/docker.socket && \
  echo "**** allow services to run under systemd (drop the docker guards) ****" && \
  dpkg-divert --local --rename --remove /sbin/initctl || true && \
  rm -f /usr/sbin/policy-rc.d /sbin/initctl && \
  echo "**** cleanup ****" && \
  apt-get autoclean && \
  rm -rf \
    /config/.cache \
    /var/lib/apt/lists/* \
    /var/tmp/* \
    /tmp/*

# add local files (systemd units, helper scripts, sshd/docker config)
COPY /root /

# make helper scripts executable regardless of checkout file modes
RUN chmod +x /usr/local/bin/selkies-container-env /usr/local/bin/selkies-root-password

# ports and volumes
EXPOSE 3001

VOLUME /config

# stop systemd gracefully on `docker stop`
STOPSIGNAL SIGRTMIN+3

# systemd as PID 1
ENTRYPOINT ["/sbin/init"]
CMD ["--system", "--unit=multi-user.target"]
