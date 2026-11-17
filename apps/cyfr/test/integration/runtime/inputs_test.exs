# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.InputsTest do
  @moduledoc """
  A running invocation's further inputs, end to end: the hostile
  `inputs_probe` (`test_wasm/hostile/` of the runtime's suite) run by the
  runtime in a runner of its own, over the suite's wire
  (`Cyfr.Test.TwoServices`), through CYFR's host (`Opus.Host.Inputs`) to
  the supplier its run was started with (`:inputs`, `Opus.Inputs`), here a
  supplier of the test's own (`Cyfr.Test.InputSupplier`).

  The probe asks for one input and reports it sent: the supplier hears the
  run's own identity, the probe gets the input's id and content, and the
  report is recorded while the run holds its attempt. A run started with
  no supplier reads none.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Test.{InputSupplier, TwoServices}
  alias Sanctum.Consent.{Commit, Plan}

  @moduletag timeout: 300_000

  @probe Path.expand(
           "../../../../locus/test/support/runtime/test_wasm/hostile/inputs_probe.wasm",
           __DIR__
         )

  @input %{
    "id" => "evt_input.e2e",
    "content" => [%{"type" => "text", "text" => "Still waiting on the run?"}]
  }

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
    TwoServices.watch!()

    {ctx, _user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)
    Cyfr.Test.Sandbox.stop_work_on_exit()
    Sanctum.TestContext.ready!(ctx.athanor_id)
    {:ok, ctx: ctx, ref: publish_probe!(ctx)}
  end

  # The probe, published as a component of the person's own, consented.
  defp publish_probe!(ctx) do
    name = "inputs-probe-#{System.unique_integer([:positive])}"
    manifest = %{"name" => name, "version" => "1.0.0", "type" => "catalyst", "needs" => %{}}

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@probe), %{
        name: name,
        version: "1.0.0",
        type: "catalyst",
        manifest: Jason.encode!(manifest)
      })

    ref = "catalyst:local." <> name
    {:ok, plan} = Plan.plan(ctx, %{ref: ref})
    decisions = %{ref: ref, bindings: []}
    {:ok, preview} = Commit.preview(ctx, decisions)

    {:ok, _committed} =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    ref
  end

  # A root of the probe, run by the runtime with `opts`: its id and what
  # the guest answered as its runner closed the attempt.
  defp run!(ctx, ref, opts) do
    id = Prima.UUID7.execution_id()
    {:ok, _} = Opus.run_root(ctx, :default, ref <> ":1.0.0", %{}, [execution_id: id] ++ opts)
    TwoServices.settled!()

    assert [%{args: %{"outcome" => %{"output" => %{"status" => 200, "data" => data}}}}] =
             TwoServices.calls(:complete, id)

    {id, data}
  end

  test "the run's own supplier hands its input to the guest, and hears its report", %{
    ctx: ctx,
    ref: ref
  } do
    supplier = InputSupplier.start!([@input])
    {id, data} = run!(ctx, ref, inputs: supplier)
    content_bytes = byte_size(Jason.encode!(@input["content"]))

    assert data == %{
             "next" => "ok",
             "id" => @input["id"],
             "content_bytes" => content_bytes,
             "sent" => "ok"
           }

    assert InputSupplier.marked(supplier) == [@input["id"]]

    assert [
             {:next, %{execution_id: ^id, athanor_id: athanor} = invocation},
             {:sent, invocation, "evt_input.e2e"}
           ] = InputSupplier.asks(supplier)

    assert athanor == ctx.athanor_id
    assert is_binary(invocation.attempt) and is_integer(invocation.fence)
  end

  test "a run started with no supplier reads none", %{ctx: ctx, ref: ref} do
    assert {_id, %{"next" => "none"}} = run!(ctx, ref, [])
  end
end
