# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.MCPCutoverTest do
  # The CLI/MCP ingress cutover is data-driven: a profile roots the
  # execution under its consent, no profile runs the legacy path
  # explicitly, and selection never guesses.
  use ExUnit.Case, async: false

  alias Sanctum.Consent.Source
  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../support/test_wasm/math.wasm")
  @telemetry_event [:opus, :runtime, :authority_entered]
  @node "reagent:local.cutover-math"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    start_supervised!(Source.Memory)

    test_path = Path.join(System.tmp_dir!(), "mcp_cutover_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    ctx = %Context{
      user_id: "cutover_user_#{:rand.uniform(100_000)}",
      org_id: "local",
      project_id: "default",
      scope: :project,
      permissions: MapSet.new([:execute]),
      authenticated: true,
      request_id: "req_cutover"
    }

    admin_ctx = Sanctum.TestContext.local()

    {:ok, component} =
      Compendium.Registry.publish_bytes(admin_ctx, File.read!(@math_wasm_path), %{
        name: "cutover-math",
        version: "0.1.0",
        type: "reagent",
        description: "Cutover test component"
      })

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: ctx, component: component}
  end

  defp attach_witness do
    handler_id = "cutover-witness-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @telemetry_event,
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:authority_entered, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp limits_map do
    %{
      "timeout" => "1m",
      "max_memory_bytes" => 67_108_864,
      "max_request_size" => 1_048_576,
      "max_response_size" => 5_242_880,
      "rate_limit" => %{"requests" => 100, "window" => "1m"},
      "max_concurrent_tasks" => 5,
      "batch_timeout" => "1m"
    }
  end

  defp seed_profile(ctx, component, overrides \\ []) do
    profile_id = Keyword.get(overrides, :id, "prof-cutover")
    label = Keyword.get(overrides, :label, "default")

    blob =
      Jason.encode!(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          @node => %{"limits" => limits_map(), "edges" => %{"@ingress" => %{}}}
        }
      })

    :ok =
      Source.Memory.put_profile(ctx, %{
        id: profile_id,
        kind: :owner,
        source_ref: @node,
        label: label,
        status: :active
      })

    :ok =
      Source.Memory.put_head_consent(ctx, profile_id, %{
        id: "consent-#{profile_id}",
        revision: 1,
        scope: :versionless,
        pinned_version: "",
        invoke_mode: :open_inert,
        shape_digest: "sha256:shape-cutover",
        commit_digest: "sha256:commit-cutover",
        resolved_policy: blob,
        activation: %{@node => Keyword.get(overrides, :digest, component.release_digest)},
        vault_refs: []
      })
  end

  defp run(ctx, args) do
    Opus.MCP.handle(
      "execution",
      ctx,
      Map.merge(%{"action" => "run", "reference" => "#{@node}:0.1.0", "input" => %{}}, args)
    )
  end

  test "no profile runs the legacy path", %{ctx: ctx} do
    attach_witness()
    assert {:error, message} = run(ctx, %{})
    # math.wasm fails at component compile on the legacy path too.
    assert message =~ "Component compilation failed"
    refute_receive {:authority_entered, _}, 200
  end

  test "a profile roots the execution under its consent", %{ctx: ctx, component: component} do
    attach_witness()
    seed_profile(ctx, component)

    assert {:error, message} = run(ctx, %{})
    assert message =~ "Component compilation failed"

    assert_receive {:authority_entered, metadata}, 30_000
    assert metadata.authority.profile_id == "prof-cutover"
    assert metadata.plane == :guest
  end

  test "an explicit selector that matches nothing surfaces, never falls back", %{
    ctx: ctx,
    component: component
  } do
    attach_witness()
    seed_profile(ctx, component)

    assert {:error, message} = run(ctx, %{"profile" => "nope"})
    assert message =~ "profile_not_found: nope"
    refute_receive {:authority_entered, _}, 200
  end

  test "two active owner profiles are ambiguous, never guessed", %{
    ctx: ctx,
    component: component
  } do
    seed_profile(ctx, component)
    seed_profile(ctx, component, id: "prof-cutover-2", label: "work")

    assert {:error, message} = run(ctx, %{})
    assert message =~ "profile_ambiguous"
    assert message =~ "prof-cutover"

    attach_witness()
    assert {:error, _} = run(ctx, %{"profile" => "work"})
    assert_receive {:authority_entered, metadata}, 30_000
    assert metadata.authority.profile_id == "prof-cutover-2"
  end

  test "consent drift surfaces the consent_required payload", %{ctx: ctx, component: component} do
    seed_profile(ctx, component, digest: "sha256:stale-grant")

    assert {:error, message} = run(ctx, %{})
    assert message =~ "consent_required: "
    assert %{"profile_id" => "prof-cutover", "current_revision" => 1} = decode_payload(message)
  end

  test "run_stream roots under the profile too", %{ctx: ctx, component: component} do
    attach_witness()
    seed_profile(ctx, component)

    assert {:ok, %{execution_id: _, stream_url: _}} =
             Opus.MCP.handle("execution", ctx, %{
               "action" => "run_stream",
               "reference" => "#{@node}:0.1.0",
               "input" => %{}
             })

    assert_receive {:authority_entered, metadata}, 30_000
    assert metadata.authority.profile_id == "prof-cutover"
  end

  defp decode_payload(message) do
    [_tag, json] = String.split(message, ": ", parts: 2)
    Jason.decode!(json)
  end
end
