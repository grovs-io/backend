# Self-hosted image: one image for every role; docker-compose.yml picks the command.
#   Community Edition:  docker build -t grovs-backend .
#   Enterprise Edition: docker build --build-arg GROVS_EE=true -t grovs-backend-ee .
ARG RUBY_VERSION=3.4.10
ARG GROVS_EE=false

FROM ruby:${RUBY_VERSION}-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && apt-get install --no-install-recommends -y \
      build-essential \
      libpq-dev \
      libyaml-dev \
      pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV BUNDLE_WITHOUT=development:test \
    BUNDLE_FROZEN=true

COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4 --retry 3 \
    && rm -rf /usr/local/bundle/cache \
    && find /usr/local/bundle -name "*.c" -delete \
    && find /usr/local/bundle -name "*.o" -delete

COPY . .

# CE deletes ee/ so the runtime flag has nothing to load; the licence boundary is the image, not env.
ARG GROVS_EE
RUN if [ "$GROVS_EE" != "true" ]; then rm -rf ee; fi

# SECRET_KEY_BASE_DUMMY lets assets:precompile run without a real secret at build time.
ENV RAILS_ENV=production \
    SECRET_KEY_BASE_DUMMY=1
RUN bundle exec rails assets:precompile \
    && rm -rf tmp/cache log/* tmp/local_secret.txt

FROM ruby:${RUBY_VERSION}-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && apt-get upgrade -y -qq && apt-get install --no-install-recommends -y \
      curl \
      libpq5 \
      postgresql-client \
      tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 1000 grovs \
    && useradd --system --uid 1000 --gid grovs --create-home grovs

WORKDIR /app

ARG GROVS_EE
ENV BUNDLE_WITHOUT=development:test \
    RAILS_ENV=production \
    RAILS_SERVE_STATIC_FILES=true \
    RAILS_LOG_TO_STDOUT=true \
    PORT=3000 \
    GROVS_EE=${GROVS_EE}
LABEL org.opencontainers.image.source="https://github.com/grovs-io/backend" \
      io.grovs.edition="${GROVS_EE}"

COPY --from=builder --chown=grovs:grovs /usr/local/bundle /usr/local/bundle
COPY --from=builder --chown=grovs:grovs /app /app
RUN mkdir -p storage tmp/pids tmp/cache log && chown -R grovs:grovs storage tmp log

USER grovs:grovs

EXPOSE 3000

CMD ["bundle", "exec", "puma", "-b", "tcp://0.0.0.0:3000"]
