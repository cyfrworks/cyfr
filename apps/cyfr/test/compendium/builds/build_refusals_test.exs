# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Builds.BuildRefusalsTest do
  @moduledoc """
  What the build tool answers when a build does not happen. This server
  holds no build slots: the builds service caps its builds, on the whole
  and per athanor, and its `capacity` refusal is the one retryable
  message. Every other way the service refuses, or fails to answer, has a
  sentence of its own; and a build id nobody recorded is not found.
  """
  # The builds service is application configuration and the scripted
  # builder one named process.
  use ExUnit.Case, async: false

  alias Compendium.Builds.Provider
  alias Cyfr.Test.ScriptedBuilder

  @wasm File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))
  @reference "reagent:local.refused:0.1.0"

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    dir = Path.join(System.tmp_dir!(), "build_refusals_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, dir)

    on_exit(fn ->
      if prev, do: Application.put_env(:cyfr, :base_path, prev)
      File.rm_rf!(dir)
    end)

    # Registered after the restore, so it runs before it: a build's tasks
    # stop while the tree they write is still theirs.
    Cyfr.Test.Sandbox.stop_work_on_exit()
    ScriptedBuilder.start!()
    :ok
  end

  defp compile(ctx),
    do: Provider.handle("build", ctx, %{"action" => "compile", "reference" => @reference})

  defp local_ctx, do: Sanctum.TestContext.local()

  defp ctx_in(athanor_id), do: %{local_ctx() | athanor_id: athanor_id}

  # The reference's unit, scaffolded in `ctx`'s athanor, so a build of it
  # is one the builder is asked for.
  defp scaffolded(ctx) do
    :ok = Arca.ensure_roots(Sanctum.Context.actor(ctx))
    {:ok, _} = Compendium.Scaffold.create(ctx, "refused", "reagent", "0.1.0")
    ctx
  end

  defp result do
    {:result,
     %{
       language: :rust,
       target_type: :reagent,
       outputs: %{"component.wasm" => @wasm},
       diagnostics: []
     }}
  end

  defp err_msg(reason) do
    Cyfr.Ops.Error.render(reason) || flunk("unrenderable refusal: #{inspect(reason)}")
  end

  describe "build.compile at the builder's capacity" do
    test "refuses with a retryable message naming the builder's cap, and builds once a slot is back" do
      ctx = scaffolded(local_ctx())
      ScriptedBuilder.script([{:refuse, {:capacity, 2}}, {:stream, [result()]}])

      assert {:error, message} = compile(ctx)
      assert message == "Build capacity is full (2 concurrent) — retry shortly"

      # Never queued: the refused build made one request and is over. The
      # next is admitted by the builder and built.
      assert length(ScriptedBuilder.requests()) == 1
      assert {:ok, %{status: "compiled"}} = compile(ctx)
      ScriptedBuilder.await_builds()
    end

    test "names the athanor on every request, which is what the builder caps each athanor by" do
      ScriptedBuilder.script([{:refuse, {:capacity, 1}}, {:refuse, {:capacity, 1}}])

      # Each build is for the athanor of the context it was asked under.
      for ctx <- [scaffolded(ctx_in("ath_a")), scaffolded(ctx_in("ath_b"))] do
        assert {:error, "Build capacity is full (1 concurrent) — retry shortly"} = compile(ctx)
      end

      assert ["ath_a", "ath_b"] == Enum.map(ScriptedBuilder.requests(), & &1.athanor_id)
    end

    test "is refused before the builder is asked when the reference has no source" do
      # Not scaffolded: the refusal is this server's, and no slot was asked for.
      assert {:error, message} = compile(local_ctx())
      assert message =~ "Source not found"
      assert ScriptedBuilder.requests() == []
    end
  end

  describe "build.compile, every other way the builder refuses" do
    @tag :capture_log
    test "each has a sentence of its own" do
      ctx = scaffolded(local_ctx())
      log = ["output: error[E0425]: cannot find value `x`", "output: error: could not compile"]

      refusals = [
        {{:refuse, {:timeout, 270_000}, log},
         &assert({:timeout, "Compilation timed out after 270000 ms"} == &1)},
        {{:refuse, {:memory, 1_073_741_824}, log},
         &assert(err_msg(&1) =~ "reached its memory bound of 1073741824 bytes")},
        {{:refuse, {:unavailable, "the rust toolchain is not installed in this image"}},
         &assert(err_msg(&1) =~ "cannot build this: the rust toolchain is not installed")},
        {{:refuse, {:failed, {:status, 101}}, log},
         &assert(err_msg(&1) == "Compilation failed (exit 101): " <> Enum.join(log, "\n"))},
        {{:refuse, {:failed, {:signal, "KILL"}}, log},
         &assert(err_msg(&1) =~ "the build was killed (KILL)")},
        {{:refuse, {:unauthorized, :bad_mac}},
         fn reason ->
           assert err_msg(reason) =~ "refused this server's key (bad_mac)"
           assert err_msg(reason) =~ "CYFR_LOCUS_BUILDS_KEY"
           assert err_msg(reason) =~ "LOCUS_BUILDS_KEY on the builds service"
         end},
        {{:refuse, {:protocol_mismatch, 2, 1}},
         fn reason ->
           assert err_msg(reason) =~ "the builder speaks builder protocol 2"
           assert err_msg(reason) =~ "this server speaks builder protocol 1"
         end},
        {{:refuse, {:malformed, "deadline is not of the form this message takes"}},
         &assert(err_msg(&1) =~ "could not read the request: deadline is not of the form")},
        {{:stream, [{:progress, :compiling, "…"}]},
         &assert(err_msg(&1) =~ "answer ended before the build finished")},
        {{:stream, [{:line, "garbage"}, result()]},
         &assert(err_msg(&1) =~ "not the builder protocol's")},
        {{:respond, 502, "<html>Bad Gateway</html>"},
         &assert(err_msg(&1) =~ "not the builder protocol's")}
      ]

      for {answer, check} <- refusals do
        ScriptedBuilder.script([answer])
        assert {:error, reason} = compile(ctx)
        check.(reason)
      end

      assert length(ScriptedBuilder.requests()) == length(refusals)
    end

    @tag :capture_log
    test "a wrong key is the builder's unauthorized, and a builder that is not there is unavailable" do
      ctx = scaffolded(local_ctx())

      ScriptedBuilder.configure!(ScriptedBuilder.url(), :crypto.strong_rand_bytes(32))
      assert {:error, message} = compile(ctx)
      assert message =~ "refused this server's key (bad_mac)"

      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)
      ScriptedBuilder.configure!("http://127.0.0.1:#{port}", ScriptedBuilder.key())

      assert {:error, {:unavailable, "The builder service"}} = compile(ctx)
    end
  end

  describe "build.status" do
    test "of an unknown build errors" do
      assert {:error, {:not_found, "Build", "build_nope"}} =
               Provider.handle("build", local_ctx(), %{
                 "action" => "status",
                 "build_id" => "build_nope"
               })
    end

    test "of another athanor's build is not found" do
      ctx = scaffolded(local_ctx())
      ScriptedBuilder.script([{:refuse, {:capacity, 1}}])

      assert {:ok, %{build_id: build_id}} =
               Provider.handle("build", ctx, %{
                 "action" => "compile",
                 "reference" => @reference,
                 "async" => true
               })

      Cyfr.Test.Wait.wait_until(fn ->
        match?(
          {:ok, %{"status" => "failed"}},
          Provider.handle("build", ctx, %{"action" => "status", "build_id" => build_id})
        )
      end)

      assert {:error, {:not_found, "Build", ^build_id}} =
               Provider.handle("build", ctx_in("ath_b"), %{
                 "action" => "status",
                 "build_id" => build_id
               })

      ScriptedBuilder.await_builds()
    end
  end
end
