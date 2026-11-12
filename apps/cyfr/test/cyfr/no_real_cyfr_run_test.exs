# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.NoRealCyfrRunTest do
  @moduledoc """
  No person is ever made at the real cyfr.run from a test: the test node's
  registry is the discard address `config/test.exs` names and it pins no
  directory. A development build and a release share one default, cyfr.run
  for the registry and the account service, so a CYFR takes one path
  whatever it was built as.
  """

  # The runtime configuration is read under a changed process environment.
  use ExUnit.Case, async: false

  alias Prima.Test.Env

  @root Path.expand("../../../..", __DIR__)
  @discard "127.0.0.1:19"

  test "the test node's registry is config/test.exs's discard address, and it pins no directory" do
    assert File.read!(Path.join(@root, "config/test.exs")) =~
             ~s(config :sanctum, :registry_url, "#{@discard}")

    assert Application.get_env(:sanctum, :registry_url) == @discard
    assert Application.get_env(:cyfr, :registry_url) == @discard
    assert Application.get_env(:cyfr, :oci_registry_url) == @discard
    assert Sanctum.registry_base_url(@discard) == "http://#{@discard}"
    assert Sanctum.directory_url() == nil
  end

  for env <- [:dev, :prod] do
    test "a #{env} configuration with neither URL set names cyfr.run" do
      config = runtime(unquote(env))
      assert get_in(config, [:sanctum, :registry_url]) == "cyfr.run"
      assert get_in(config, [:cyfr, :registry_url]) == "cyfr.run"
      assert get_in(config, [:cyfr, :oci_registry_url]) == "registry.cyfr.run"
      assert get_in(config, [:sanctum, :directory_url]) == "https://cyfr.run"
    end
  end

  test "a directory over http is accepted on this machine's loopback alone" do
    config = runtime(:dev, %{"CYFR_DIRECTORY_URL" => "http://127.79.0.1:4702"})
    assert get_in(config, [:sanctum, :directory_url]) == "http://127.79.0.1:4702"

    for refused <- ["http://10.0.0.5", "http://dir.example", "http://127.0.0.1.example"] do
      assert_raise RuntimeError, ~r/CYFR_DIRECTORY_URL must be a directory URL/, fn ->
        runtime(:dev, %{"CYFR_DIRECTORY_URL" => refused})
      end
    end
  end

  # Each form a registry setting may be written in, what the boot does
  # with it, and, for a value that boots, the scheme its requests use:
  # {form, value, registry, OCI registry}, each `{:boots, scheme}`,
  # `:default` or `:refused`. A form boots exactly when it reached a
  # registry for that setting's purpose before `none` was removed, with two
  # narrowings of forms that half-worked. An IPv6 address reached the
  # registry's search and metadata and refused everything its accounts
  # sign, which names the registry by a host name's grammar. A path's empty
  # segment or trailing `/` put `//` in every request, which a CYFR's router
  # forgives and cyfr.run redirects, and no registry request follows a
  # redirect.
  @forms [
    {"a host name", "registry.example", {:boots, "https"}, {:boots, "https"}},
    {"a host name and port", "registry.example:8443", {:boots, "https"}, {:boots, "https"}},
    {"an empty port, the scheme's own", "registry.example:", {:boots, "https"},
     {:boots, "https"}},
    {"an IPv4 address and port", "203.0.113.7:9", {:boots, "https"}, {:boots, "https"}},
    {"a bracketed IPv6 address and port", "[2001:db8::1]:5000", :refused, {:boots, "https"}},
    {"a bracketed IPv6 address", "[2001:db8::1]", :refused, {:boots, "https"}},
    {"an IPv6 address without brackets", "2001:db8::1", :refused, :refused},
    {"a path a proxy serves the registry under", "registry.example:8443/registry",
     {:boots, "https"}, :refused},
    {"a path of segments", "registry.example/a/b", {:boots, "https"}, :refused},
    {"a trailing slash", "registry.example/", :refused, :refused},
    {"a path's trailing slash", "registry.example:8443/registry/", :refused, :refused},
    {"an empty segment inside a path", "registry.example/a//b", :refused, :refused},
    {"a path with a query", "registry.example/a?b", :refused, :refused},
    {"a path's empty segment", "registry.example//registry", :refused, :refused},
    {"a path with a fragment", "registry.example/a#b", :refused, :refused},
    {"an https scheme", "https://registry.example", :refused, :refused},
    {"an http scheme", "http://127.0.0.1:9", :refused, :refused},
    {"userinfo", "user@registry.example", :refused, :refused},
    {"upper case", "REGISTRY.EXAMPLE", {:boots, "https"}, {:boots, "https"}},
    {"a trailing dot", "registry.example.", :refused, :refused},
    {"localhost and port", "localhost:4000", {:boots, "http"}, {:boots, "http"}},
    {"a loopback IPv4 address", "127.0.0.2:9", {:boots, "http"}, {:boots, "http"}},
    {"a loopback IPv6 address", "[::1]:9", :refused, {:boots, "http"}},
    {"an empty value", "", :default, :default},
    {"none", "none", :refused, :refused},
    {"NONE", "NONE", :refused, :refused},
    {"None", "None", :refused, :refused},
    {"port 0", "registry.example:0", :refused, :refused},
    {"port 65536", "registry.example:65536", :refused, :refused},
    {"a space", "registry example", :refused, :refused}
  ]

  for {form, value, registry, oci} <- @forms do
    test "#{form} (#{inspect(value)}): the registry #{inspect(registry)}, the OCI registry #{inspect(oci)}" do
      assert_setting("CYFR_REGISTRY_URL", unquote(value), unquote(Macro.escape(registry)))
      assert_setting("CYFR_OCI_REGISTRY_URL", unquote(value), unquote(Macro.escape(oci)))
    end
  end

  defp assert_setting(variable, value, expected) do
    key =
      if variable == "CYFR_REGISTRY_URL",
        do: [:sanctum, :registry_url],
        else: [:cyfr, :oci_registry_url]

    read = fn -> runtime(:prod, %{variable => value}) end

    case expected do
      {:boots, scheme} ->
        assert get_in(read.(), key) == value
        assert Sanctum.registry_base_url(value) == scheme <> "://" <> value

      :default ->
        assert get_in(read.(), key) in ["cyfr.run", "registry.cyfr.run"]

      :refused ->
        assert_raise RuntimeError, ~r/#{variable} must name/, read
    end
  end

  test "the registry's refusal says why it takes no IPv6 address" do
    assert_raise RuntimeError,
                 ~r/The requests its accounts sign name the registry, and they cannot name an IPv6 address/,
                 fn -> runtime(:prod, %{"CYFR_REGISTRY_URL" => "[::1]:9"}) end
  end

  test "the OCI registry derives from the registry's host and port, without its path" do
    assert get_in(
             runtime(:prod, %{"CYFR_REGISTRY_URL" => "registry.example:8443/registry"}),
             [:cyfr, :oci_registry_url]
           ) == "registry.registry.example:8443"
  end

  defmodule IPv6Registry do
    @moduledoc false
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "local-registry")
  end

  test "an OCI registry on an IPv6 address the transport reaches is one the boot takes" do
    {:ok, server} =
      start_supervised(
        {Bandit,
         plug: IPv6Registry,
         scheme: :http,
         ip: {0, 0, 0, 0, 0, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    registry = "[::1]:#{port}"
    Env.put_app_env(:sanctum, :private_egress_targets, ["::1"])
    Env.put_app_env(:cyfr, :oci_registry_url, registry)
    ref = %Compendium.OCI.Reference{registry: registry, repository: "demo/catalysts/example"}

    assert {:ok, 200, _headers, "local-registry"} =
             Compendium.OCI.Transport.request(nil, :get, "/v2/", ref)

    assert get_in(runtime(:prod, %{"CYFR_OCI_REGISTRY_URL" => registry}), [
             :cyfr,
             :oci_registry_url
           ]) ==
             registry
  end

  # `config/runtime.exs` read for `env` with neither URL set but those in
  # `vars`, and the variables a production boot cannot do without.
  defp runtime(env, vars \\ %{}) do
    base = %{
      "CYFR_REGISTRY_URL" => nil,
      "CYFR_DIRECTORY_URL" => nil,
      "CYFR_OCI_REGISTRY_URL" => nil,
      "CYFR_DATABASE" => nil,
      "RELEASE_ROOT" => nil,
      "CYFR_SECRET_KEY_BASE" => Base.encode64(:crypto.strong_rand_bytes(48)),
      "RELEASE_NAME" => "cyfr"
    }

    base
    |> Map.merge(vars)
    |> Enum.reduce(
      fn ->
        Config.Reader.read!(Path.join(@root, "config/runtime.exs"), env: env, imports: :disabled)
      end,
      fn
        {key, nil}, read -> fn -> Env.without_system_env(key, read) end
        {key, value}, read -> fn -> Env.with_system_env(key, value, read) end
      end
    )
    |> then(& &1.())
  end
end
