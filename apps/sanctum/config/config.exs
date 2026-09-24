# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

# Sanctum's own configuration, read by a build that holds the contracts,
# Arca and Sanctum alone. An umbrella build reads the root application's
# instead, which declares the same keys. Arca's are imported rather than
# restated: Sanctum starts it, and a second spelling of the repository's
# settings would drift.
import Config

import_config "../../arca/config/config.exs"

# Consent proofs are durable: the plan → preview → commit walk spans human
# minutes and must survive a restart.
config :sanctum, :consent_proof_store, Sanctum.Consent.Proof.DB

# Where this deployment is reachable when the operator declared nothing.
# `CYFR_PUBLIC_URL` overrides it (`:sanctum, :public_url`); an OAuth
# `redirect_uri` needs an absolute origin either way.
config :sanctum, :fallback_origin, "http://localhost:4000"

# The two ports this domain declares — consent's view of the operation
# table (`:grimoire`) and the component facts a consent rests on
# (`:consent_components`) — are deliberately unset here. Nothing above
# this application exists to implement them, and an unset port refuses
# every call through it, distinguishably from an absent component; the
# umbrella's configuration names the implementations.

# The rows are Arca's; the mix tasks are told where to find them.
config :sanctum, ecto_repos: [Arca.Repo]

if config_env() == :test do
  # Unit tests run on the ETS store; `proof_db_test.exs` exercises the
  # durable adapter directly.
  config :sanctum, :consent_proof_store, Sanctum.Consent.Proof.Memory

  config :sanctum, :fallback_origin, "http://localhost:4002"

  # At-rest encryption needs a keyring before any row is sealed. A build
  # with no host resolves none, so the suite carries one of its own.
  config :sanctum, :crypto_keyring, %{
    primary: "default",
    keys: %{"default" => :crypto.hash(:sha256, "sanctum-suite-keyring")}
  }

  config :sanctum,
    secret_key_base: "test_dev_key_base_min_64_chars_for_aes256_key_derivation_padding!",
    default_test_namespace: "testns"

  # Allow tests to inject a membership-resolution override
  # (`Sanctum.Tenancy`). Compile-time gate: production releases compile
  # this to false and never honor the override.
  config :sanctum, allow_tenancy_resolver_override: true

  # Let fixtures that build an issuing context by hand pass the generations
  # its rows stand at (`generation_snapshot:`). Compile-time gate, like the
  # override above: a release compiles it out and refuses the option.
  config :sanctum, issuance_snapshot_permitted: true

  # No host runs here to claim a control-plane slot, as none claims one in
  # the umbrella's suite (`config/test.exs`): the member counts as holding
  # the plane unless a case records otherwise, so a tincture token can be
  # minted (`Sanctum.TinctureAuth`).
  config :arca, control_plane_claim_enabled: false

  # The caller bound is off: the establish memo keeps nothing, so tests
  # assert on the uncached pipeline, and a retained context is revalidated
  # before each use. A sandbox rollback is a write no invalidation ever
  # sees, so the namespace read is uncached too.
  config :sanctum, :caller_memo_ttl_ms, 0
  config :sanctum, :namespace_cache_ttl_ms, 0

  # Same for the provisioning retries a sign-in kicks off.
  config :sanctum, provisioning_inline: true

  config :logger, level: :warning
end
