# mcl-distributor
#
# Distributes a sealed pubsub group's rotating epoch keys to its admitted members over sealed calls
#
# NO DATA VOLUME AS GENERATED. The scaffold writes nothing, and a named volume
# for data that does not exist is a promise the image cannot keep. Add one
# together with the code that writes it, and declare it here and in the compose
# file at the same time.

# ⚠ THE TEAM IMAGE PAIR, PINNED BY DATED TAG AND DIGEST. macula-ci-otp is
# macula-io/macula-ci-images' build image: OTP 28.4.3 on Debian trixie with an
# OpenSSL carrying ML-DSA, rebar3 3.27.0 and Rust, all pinned. The release runs
# on macula-pq-runtime of the same date, the same Debian, so its ERTS and NIFs
# match the runtime's glibc. 20260923-1444 is the pair the rocksdb images are
# derived from, so every mcl service sits on one base. lint.yml pins the same
# build image, and the service tests guard all three pins.
FROM ghcr.io/macula-io/macula-ci-otp:20260923-1444@sha256:dd2ba6eb858a0eacedf0179300323fe5c6da46fb308d22da0ca8cfcd1f0718dc AS builder

# ⚠ THE OTP RELEASE, ASSERTED HERE because the image tag names a date, not a
# release. The same check as lint.yml's toolchain step; the service tests read
# this line and compare it with .tool-versions and lint's.
RUN erl -noshell -eval ' \
    Otp = string:trim(element(2, file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])))), \
    Mldsa = lists:member(mldsa87, crypto:supports(public_keys)), \
    io:format("OTP ~s, mldsa87 ~p~n", [Otp, Mldsa]), \
    case {Otp, Mldsa} of \
        {<<"28.4.3">>, true} -> halt(0); \
        _                    -> halt(1) \
    end.'

WORKDIR /build

# Dependencies resolve from rebar.config alone, so this layer survives every
# change to config/ and apps/.
COPY rebar.config ./
RUN rebar3 get-deps

COPY config ./config
COPY apps ./apps
RUN rebar3 as prod release

FROM ghcr.io/macula-io/macula-pq-runtime:20260923-1444@sha256:15a5501b7277804c5a62c93121d157773d1401d238a1bf630ef4b50fc2f1df09
# LINKS THE PACKAGE TO THE REPOSITORY. On registries that read it, ghcr among
# them, a package without this label is an orphan: it does not appear on the
# repository page and does not inherit its visibility. A service that shipped
# private by accident failed its first pull with a bare "unauthorized", which
# names nothing and sends you looking in the wrong place.
LABEL org.opencontainers.image.source="https://github.com/macula-services/mcl-distributor"
# THIS image's commit (build-push passes github.sha). Without it the image
# inherited its base image's label, which names macula-ci-images' commit.
ARG REVISION=unknown
LABEL org.opencontainers.image.revision="${REVISION}"
# The runtime image carries what the release loads: OpenSSL 3.5, libz,
# libzstd, libstdc++, libtinfo, and curl for the healthcheck below.
WORKDIR /app
COPY --from=builder /build/_build/prod/rel/mcl_distributor ./

ENV HOME=/app
ENV RELX_REPLACE_OS_VARS=true

ENV MCL_NODE_NAME=mcl_distributor
ENV MCL_NODE_HOST=127.0.0.1
ENV MCL_COOKIE=mcl_distributor

# Every ${VAR} in sys.config must resolve or the term is malformed, so the
# required ones (MCL_GROUP_ORG, MCL_GROUP_ORG_KEY_ID, MCL_GROUP_REALM_KEY_ID,
# MCL_REALM, MCL_REALM_KEY, MCL_REALM_NAME) are supplied by the fleet's
# compose env, never defaulted here: a half-configured distributor must not
# boot looking healthy. The two knobs with safe defaults:
ENV MCL_GROUP_POLICY=required
ENV MCL_GROUP_ROTATE_MS=900000

# The node identity key. Mount a NAMED volume here (the fleet's compose
# does): the key is the distributor's verified identity on the mesh.
VOLUME ["/etc/mcl/secrets"]

# /health is served on a Unix socket only (mcl_om health_socket); mcl_om
# creates the socket, mode 0600, in this directory.
RUN mkdir -p /run/mcl
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS --unix-socket /run/mcl/health.sock http://localhost/health || exit 1

CMD ["/app/bin/mcl_distributor", "foreground"]
