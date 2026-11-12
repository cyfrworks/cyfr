# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Sanctum's test seams in the shipped release, evaluated inside it by
# `bin/cyfr eval` (tests/release-boot/boot.sh): a release is compiled
# without the test permission (`:sanctum, :test_seams_permitted`), so no
# setting it is given at start-up reaches a seam. Every seam's key, and
# the permission itself, is set here at runtime, as `sys.config` or
# `ERL_AFLAGS` could set them, and the release must answer as it ships:
#
#   - `Sanctum.seam/2` answers the shipped default and never runs the
#     seam's read;
#   - the WorkOS sign-in keeps https://api.workos.com, the directory client
#     takes no suite options, the OAuth presets take no scripted provider
#     and the caller memo keeps its 2 s bound, whatever their keys say;
#   - an issuance refuses a fixture's generation snapshot;
#   - `Sanctum.Tenancy`'s compiled code names no resolver override.
#
# Each check raises naming what it found; a release that passes them all
# prints the one line `CYFR_TEST_SEAMS=ok`.

reads = :counters.new(1, [])

check = fn
  true, _what -> :ok
  false, what -> raise "a release built without the test permission #{what}"
end

for module <- [Sanctum, Sanctum.Tenancy, Sanctum.Issuance, Sanctum.Auth.WorkOS],
    do: Code.ensure_loaded!(module)

# A seam's value names this probe, so a read of it is seen where it lands.
defmodule CyfrReleaseProof.Seam do
  def counter, do: :persistent_term.get({__MODULE__, :reads})
  def preset(_hint), do: hit(nil)
  def hit(answer), do: tap(answer, fn _ -> :counters.add(counter(), 1, 1) end)
end

:persistent_term.put({CyfrReleaseProof.Seam, :reads}, reads)

Application.put_env(:sanctum, :test_seams_permitted, true)
Application.put_env(:sanctum, :workos_api_url, "https://seam.invalid")
Application.put_env(:sanctum, :workos, %{client_id: "client", organization: "org"})
Application.put_env(:sanctum, :oidc_reauth_client, CyfrReleaseProof.Seam)
Application.put_env(:sanctum, :directory_client, not_an_option: true)
Application.put_env(:sanctum, :scripted_oauth_provider, CyfrReleaseProof.Seam)
Application.put_env(:sanctum, :caller_memo_ttl_ms, 3_600_000)
Application.put_env(:sanctum, :namespace_cache_ttl_ms, 3_600_000)

check.(
  Sanctum.seam(:shipped, fn -> CyfrReleaseProof.Seam.hit(:read) end) == :shipped,
  "ran a seam's read"
)

{:ok, url} =
  Sanctum.Auth.WorkOS.authorize_url(%{redirect_uri: "https://example.com/callback"}, "state")

check.(URI.parse(url).host == "api.workos.com", "sent the WorkOS sign-in to #{url}")

check.(
  Sanctum.Directory.Client.log("not-an-identifier", "https://directory.invalid") ==
    {:error, :invalid_locator},
  "took the suite's directory options"
)

check.(Sanctum.Vault.OAuth.preset("cyfr-release-proof") == nil, "read a scripted OAuth preset")

validated = DateTime.add(DateTime.utc_now(), -10, :second)

check.(
  not Sanctum.Caller.fresh?(%Sanctum.Context{validated_at: validated}),
  "kept a context fresh past the shipped 2 s memo"
)

check.(
  Sanctum.Issuance.expectation(%Sanctum.Context{user_id: "usr_release_proof"},
    generation_snapshot: %{
      user_id: "usr_release_proof",
      user_generation: 1,
      athanor_id: nil,
      athanor_generation: nil
    }
  ) == {:error, :missing_generation},
  "issued under a fixture's generation snapshot"
)

{:ok, {Sanctum.Tenancy, [atoms: atoms]}} =
  :beam_lib.chunks(:code.which(Sanctum.Tenancy), [:atoms])

check.(
  not Enum.any?(atoms, fn {_number, atom} -> atom == :tenancy_resolver_override end),
  "compiled the tenancy resolver override in"
)

check.(:counters.get(reads, 1) == 0, "read a seam the probe set")

IO.puts("CYFR_TEST_SEAMS=ok")
