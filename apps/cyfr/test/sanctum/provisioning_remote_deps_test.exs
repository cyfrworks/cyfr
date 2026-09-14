# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ProvisioningRemoteDepsTest do
  @moduledoc """
  A bundle whose required closure reaches a registry. Required dependency
  work is bounded per attempt: a registry that accepts a connection and
  never answers cannot hold an estate's fill open — the attempt stops
  within its budget, the claim and the lock are released after it has
  stopped, the timeout is recorded on the row, and the next attempt
  resumes from what landed, a dependency below a partially installed
  remote component included. The seed sync heals a dependency an earlier
  attempt lost. An explicit retry that meets an attempt in progress is
  told so, typed, without waiting.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Provisioning
  alias Sanctum.Tenancy.Athanors

  # A registry of two fixture catalysts: `someone/catalysts/elsewhere`,
  # which the bundle requires, and `someone/catalysts/below`, which
  # `elsewhere` requires. While the stall agent names a repository, that
  # repository's manifest request is accepted and never answered.
  defmodule OCIRegistry do
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Plug.Conn{request_path: path} = conn, %{fixtures: fixtures, stall: stall}) do
      case Regex.run(~r{^/v2/(.+)/(tags/list|manifests/[^/]+|blobs/[^/]+)$}, path) do
        [_, repo, "tags/list"] when is_map_key(fixtures, repo) ->
          json(conn, 200, %{"name" => repo, "tags" => ["1.0.0"]})

        [_, repo, "manifests/" <> _tag] when is_map_key(fixtures, repo) ->
          if Agent.get(stall, & &1) == repo, do: Process.sleep(:timer.minutes(2))

          %{manifest: manifest, manifest_digest: digest} = fixtures[repo]

          conn
          |> Plug.Conn.put_resp_content_type(Compendium.OCI.Manifest.manifest_media_type())
          |> Plug.Conn.put_resp_header("docker-content-digest", digest)
          |> Plug.Conn.send_resp(200, manifest)

        [_, repo, "blobs/" <> digest] when is_map_key(fixtures, repo) ->
          case fixtures[repo].blobs[digest] do
            nil -> json(conn, 404, %{"errors" => [%{"code" => "BLOB_UNKNOWN"}]})
            bytes -> Plug.Conn.send_resp(conn, 200, bytes)
          end

        _ ->
          json(conn, 404, %{"errors" => [%{"code" => "NAME_UNKNOWN", "message" => path}]})
      end
    end

    defp json(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end

  @repo_root Path.expand("../../../..", __DIR__)
  @wasm File.read!(Path.join(@repo_root, "apps/cyfr/test/support/test_wasm/math.wasm"))
  @budget_ms 500

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "cyfr_deadline_#{System.unique_integer([:positive])}")
    seed_dir = Path.join(test_dir, "seed")
    write_bundle!(Path.join(seed_dir, "components"))
    File.cp_r!(Path.join(@repo_root, "seed/aqua"), Path.join(seed_dir, "aqua"))

    stall = start_supervised!({Agent, fn -> nil end})

    {:ok, server} =
      Bandit.start_link(
        plug: {OCIRegistry, %{fixtures: fixtures(), stall: stall}},
        ip: {127, 0, 0, 1},
        port: 0
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    keys = [
      :base_path,
      :seed_path,
      :oci_registry_url,
      :registry_url,
      :sigstore,
      :provisioning_required_pull_budget_ms
    ]

    prev = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})

    Application.put_env(:cyfr, :base_path, test_dir)
    Application.put_env(:cyfr, :seed_path, seed_dir)
    # `localhost:` is the one host the OCI reference layer maps to http.
    Application.put_env(:cyfr, :oci_registry_url, "localhost:#{port}")
    Application.put_env(:cyfr, :registry_url, "127.0.0.1:19")
    # A cosign on PATH would try to verify; point it at nothing so it fails fast.
    Application.put_env(:cyfr, :sigstore, verification: :keyed, key_path: "/nonexistent")
    Application.put_env(:cyfr, :provisioning_required_pull_budget_ms, @budget_ms)

    on_exit(fn ->
      for {key, value} <- prev do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end

      File.rm_rf!(test_dir)
      Process.exit(server, :normal)
    end)

    n = System.unique_integer([:positive])

    ctx =
      Sanctum.Context.build(
        user_id: "github|https://github.com|deadline-#{n}",
        athanor_id: Sanctum.TestContext.athanor_id(),
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, group} = Athanors.create_group(ctx.user_id, "Deadline #{n}")
    {:ok, ctx: %{ctx | athanor_id: group.id}, group: group, stall: stall}
  end

  test "a stalled required pull ends within its budget, releases coordination, and the next attempt completes the closure",
       %{ctx: ctx, group: group, stall: stall} do
    Agent.update(stall, fn _ -> "someone/catalysts/below" end)

    started = System.monotonic_time(:millisecond)
    :ok = Provisioning.start_provisioning(ctx)
    elapsed = System.monotonic_time(:millisecond) - started

    # The suite fills inline, so the attempt ran here: bounded by the
    # budget plus the seed scan and one answered pull, never by the
    # transport's own minutes-long patience.
    assert elapsed < 10 * @budget_ms

    {:ok, group} = Athanors.get(group.id)
    refute group.provisioned_at

    assert %{step: "closure", detail: detail} = Athanors.provisioning_failure(group)

    assert detail =~ "timeout"

    # What landed before the cut stays; what was cut is not there.
    assert {:ok, _} = Compendium.Registry.get_latest(ctx, "elsewhere", "someone", "catalyst")

    assert {:error, :not_found} =
             Compendium.Registry.get_latest(ctx, "below", "someone", "catalyst")

    # The attempt has stopped and let go of both the claim and the lock.
    assert Registry.lookup(Sanctum.ProvisioningRegistry, group.id) == []
    assert :ok = Arca.Overlay.UnitLock.with_lock({group.id, :provisioning}, fn -> :ok end, 1_000)

    # The registry answers again: the explicit retry reads the installed
    # remote component's manifest, finds the dependency below it, and
    # finishes the closure.
    Agent.update(stall, fn _ -> nil end)
    assert {:ok, %{provisioned_at: %DateTime{}}} = Provisioning.provision(group, ctx)
    assert {:ok, _} = Compendium.Registry.get_latest(ctx, "below", "someone", "catalyst")
  end

  test "the seed sync heals a dependency an earlier attempt lost", %{ctx: ctx, group: group} do
    :ok = Provisioning.start_provisioning(ctx)
    {:ok, group} = Athanors.get(group.id)
    assert %DateTime{} = group.provisioned_at, inspect(Athanors.settings(group))

    # A transient outage at an earlier sync leaves one dependency of the
    # closure unpulled; dropping its row is exactly that state. The next
    # boot registers no new bundle versions, and the closure still heals.
    {:ok, below} = Compendium.Registry.get_latest(ctx, "below", "someone", "catalyst")
    :ok = Arca.ComponentStorage.delete_component(ctx, "below", below.version, "someone", nil)

    assert {:error, :not_found} =
             Compendium.Registry.get_latest(ctx, "below", "someone", "catalyst")

    assert :ok = Provisioning.sync_seeds()
    assert {:ok, _} = Compendium.Registry.get_latest(ctx, "below", "someone", "catalyst")
  end

  test "an explicit retry that meets a running attempt is told it is in progress, at once",
       %{ctx: ctx, group: group} do
    # Another caller's attempt holds the claim — a background fill in
    # flight. The explicit verb does not queue behind it.
    parent = self()

    holder =
      spawn_link(fn ->
        {:ok, _} = Registry.register(Sanctum.ProvisioningRegistry, group.id, :filling)
        send(parent, :held)
        receive do: (:release -> :ok)
      end)

    assert_receive :held

    started = System.monotonic_time(:millisecond)
    assert {:error, :provisioning_busy} = Provisioning.provision(group, ctx)
    assert System.monotonic_time(:millisecond) - started < 1_000

    # The verb renders it as the same typed answer a turn gives while the
    # estate is being prepared — in progress, not a failure.
    assert {:error, :not_provisioned} =
             Sanctum.MCP.AthanorTool.handle(ctx, %{"action" => "provision"})

    send(holder, :release)
  end

  # ---- fixtures ---------------------------------------------------------------

  # The bundle: one local catalyst that requires `catalyst:someone.elsewhere`.
  defp write_bundle!(bundle_dir) do
    src = Path.join([bundle_dir, "catalysts", "local", "foo", "1.0.0"])
    File.mkdir_p!(src)
    File.write!(Path.join(src, "catalyst.wasm"), @wasm)

    manifest = %{
      "name" => "foo",
      "version" => "1.0.0",
      "type" => "catalyst",
      "caps" => %{"egress" => %{"domains" => []}},
      "dependencies" => %{
        "static" => [%{"ref" => "catalyst:someone.elsewhere", "optional" => false}]
      }
    }

    File.write!(Path.join(src, "cyfr-manifest.json"), Jason.encode!(manifest))
  end

  # `elsewhere` requires `below`; `below` requires nothing.
  defp fixtures do
    Map.new(["elsewhere", "below"], fn name ->
      static =
        if name == "elsewhere",
          do: [%{"ref" => "catalyst:someone.below", "optional" => false}],
          else: []

      config =
        Jason.encode!(%{
          "name" => name,
          "version" => "1.0.0",
          "type" => "catalyst",
          "publisher" => "someone",
          "description" => "#{name} (fixture)",
          "dependencies" => %{"static" => static},
          "caps" => %{"egress" => %{"domains" => []}}
        })

      {:ok, manifest_json, config_digest, wasm_digest} =
        Compendium.OCI.Manifest.build(config, @wasm, "catalyst")

      {"someone/catalysts/#{name}",
       %{
         manifest: manifest_json,
         manifest_digest: Compendium.OCI.Blob.compute_digest(manifest_json),
         blobs: %{config_digest => config, wasm_digest => @wasm}
       }}
    end)
  end
end
