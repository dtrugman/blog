FROM ruby:slim-bookworm

RUN apt update && \
    apt -y install build-essential && \
    gem install bundler jekyll && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

EXPOSE 4000

ENTRYPOINT /bin/bash
