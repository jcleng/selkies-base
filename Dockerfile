# syntax=docker/dockerfile:1
#
# Minimal Selkies environment running xeyes.
# Patterned after https://github.com/linuxserver/docker-chrome/blob/master/Dockerfile
# x86_64 only by design (no aarch64).

FROM ghcr.io/linuxserver/baseimage-selkies:debiantrixie

# set version label
ARG BUILD_DATE
ARG VERSION
LABEL build_version="version:- ${VERSION} Build-date:- ${BUILD_DATE}"
LABEL maintainer="jcleng"

# title + default application started by the session
# APP: command (with arguments) launched in the desktop session, override at runtime.
ENV TITLE=xeyes \
    PIXELFLUX_WAYLAND=true \
    APP=xeyes

RUN \
  echo "**** add icon ****" && \
  { curl -fsSL -o /usr/share/selkies/www/icon.png \
      https://raw.githubusercontent.com/linuxserver/docker-templates/master/linuxserver.io/img/selkies-logo.png || \
    :; } && \
  echo "**** install packages ****" && \
  apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    x11-apps \
    xterm && \
  echo "**** cleanup ****" && \
  apt-get autoclean && \
  rm -rf \
    /config/.cache \
    /var/lib/apt/lists/* \
    /var/tmp/* \
    /tmp/*

# add local files
COPY /root /

# ports and volumes
EXPOSE 3001

VOLUME /config
