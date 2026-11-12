# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TestSeamsTest do
  # Sanctum's test seams are read only by a build compiled with the test
  # permission (`:test_seams_permitted`): a release, compiled without it,
  # answers each seam's shipped default and never reads the key, whatever
  # its start-up configuration sets. Synchronous: a case sets the seams'
  # keys, which every reader in the VM sees.
  use ExUnit.Case, async: false

  # Each seam a release could be handed at start-up, beside the default a
  # build without the permission answers in its place.
  @seams [
    workos_api_url: "https://api.workos.com",
    oidc_reauth_client: Sanctum.Auth.OIDC.Oidcc,
    directory_client: [],
    scripted_oauth_provider: nil,
    caller_memo_ttl_ms: 2_000,
    namespace_cache_ttl_ms: 60_000
  ]

  setup do
    for {key, _default} <- @seams do
      Prima.Test.Env.put_app_env(:sanctum, key, {:set_at_start_up, key})
    end

    :ok
  end

  test "a build without the permission answers every seam's default and reads none of them" do
    for {key, default} <- @seams do
      read = fn -> flunk("#{key} was read by a build without the test permission") end
      assert Sanctum.seam(false, default, read) == default
    end
  end

  test "a build with the permission reads each seam's setting" do
    for {key, default} <- @seams do
      read = fn -> Application.get_env(:sanctum, key, default) end
      assert Sanctum.seam(true, default, read) == {:set_at_start_up, key}
    end
  end

  test "the permission is the test configurations' and no other's" do
    root = Path.expand("../../../..", __DIR__)

    setting =
      for path <-
            Path.wildcard(Path.join(root, "config/*.exs")) ++
              Path.wildcard(Path.join(root, "apps/*/config/*.exs")),
          File.read!(path) =~ ~r/^\s*config :sanctum,.*test_seams_permitted/m,
          do: Path.relative_to(path, root)

    # The standalone build holds no `config/test.exs`; the umbrella holds both.
    assert "apps/sanctum/config/config.exs" in setting
    assert setting -- ["apps/sanctum/config/config.exs", "config/test.exs"] == []

    # The standalone build's file sets it under test alone.
    [_shipped, under_test] =
      root
      |> Path.join("apps/sanctum/config/config.exs")
      |> File.read!()
      |> String.split("if config_env() == :test do", parts: 2)

    assert under_test =~ "test_seams_permitted: true"
  end
end
