# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.MCPCutoverTest do
  # The CLI/MCP ingress is data-driven: a profile roots the execution
  # under its consent, no profile refuses with consent guidance (nothing
  # runs), and selection never guesses. A rooted run runs on the Opus
  # service, and the authority it roots under is the one its runner's
  # attach was handed, read on the suite's wire.
  use ExUnit.Case, async: false

  import Cyfr.Test.Wait

  alias Cyfr.Test.TwoServices
  alias Sanctum.Consent.Source
  alias Sanctum.Context

  @math_wasm_path Path.join(__DIR__, "../../support/test_wasm/math.wasm")
  @node "reagent:local.cutover-math"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()
    start_supervised!(Source.Memory)

    test_path = Path.join(System.tmp_dir!(), "mcp_cutover_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    ctx = %Context{
      user_id: "cutover_user_#{:rand.uniform(100_000)}",
      athanor_id: Sanctum.TestContext.athanor_id(),
      scope: :athanor,
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

    Cyfr.Test.Sandbox.stop_work_on_exit()

    {:ok, ctx: ctx, component: component}
  end

  # The authorities the runs attached since the test began watching the
  # suite's wire entered with, oldest first.
  defp entered do
    for %{callback: :attach, fields: %{execution_id: id}} <- TwoServices.calls(),
        do: TwoServices.entered(id)
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
    Cyfr.Execution.MCP.handle(
      "execution",
      ctx,
      Map.merge(%{"action" => "run", "reference" => "#{@node}:0.1.0", "input" => %{}}, args)
    )
  end

  test "no profile refuses with consent guidance — nothing runs", %{ctx: ctx} do
    TwoServices.watch!()
    assert {:error, {:consent_required, payload}} = run(ctx, %{})
    assert %{"detail" => detail} = payload
    assert detail =~ "profile.plan"
    assert entered() == []
  end

  test "a profile roots the execution under its consent", %{ctx: ctx, component: component} do
    TwoServices.watch!()
    seed_profile(ctx, component)

    assert {:error, message} = run(ctx, %{})
    assert message =~ "Component compilation failed"

    assert [%{profile_id: "prof-cutover"}] = entered()
  end

  test "an explicit selector that matches nothing surfaces, never falls back", %{
    ctx: ctx,
    component: component
  } do
    TwoServices.watch!()
    seed_profile(ctx, component)

    assert {:error, message} = run(ctx, %{"profile" => "nope"})
    assert message =~ "profile_not_found: nope"
    assert entered() == []
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

    TwoServices.watch!()
    assert {:error, _} = run(ctx, %{"profile" => "work"})
    assert [%{profile_id: "prof-cutover-2"}] = entered()
  end

  test "consent drift surfaces the consent_required payload", %{ctx: ctx, component: component} do
    seed_profile(ctx, component, digest: "sha256:stale-grant")

    assert {:error, {:consent_required, payload}} = run(ctx, %{})
    assert %{profile_id: "prof-cutover", current_revision: 1} = payload
  end

  test "run_stream roots under the profile too", %{ctx: ctx, component: component} do
    TwoServices.watch!()
    seed_profile(ctx, component)

    assert {:ok, %{execution_id: id, stream_url: _}} =
             Cyfr.Execution.MCP.handle("execution", ctx, %{
               "action" => "run_stream",
               "reference" => "#{@node}:0.1.0",
               "input" => %{}
             })

    wait_until(fn -> TwoServices.entered(id) != nil end, 30_000, "the run's attach")
    assert %{profile_id: "prof-cutover"} = TwoServices.entered(id)
  end
end
