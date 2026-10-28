# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Builds.StagedBuildTest do
  @moduledoc """
  A staged build (`Compendium.Builds.build_staged/3`): sources held in
  memory are sent to the builds service as they are, and the verified
  files are answered without anything stored, no build row written and
  nothing registered. A server with no builds service refuses it
  `unavailable` before any request; a lockfile-less package manifest is
  refused before any request; a refused, failed or timed-out build is
  answered as `compile` answers it; a caller killed while the builder
  works takes the request with it. The builds service is
  `Cyfr.Test.ScriptedBuilder`.
  """
  # The builds service is application configuration and the scripted
  # builder one named process.
  use ExUnit.Case, async: false

  alias Arca.Schemas.{BuildRecord, StorageCommit}
  alias Compendium.Builds
  alias Cyfr.Test.ScriptedBuilder

  @sources %{
    "package.json" => ~s({"name":"staged"}),
    "package-lock.json" => ~s({"name":"staged","lockfileVersion":3}),
    "index.html" =>
      ~s(<html><body><script type="module" src="/src/main.tsx"></script></body></html>),
    "src/main.tsx" => "document.body.textContent = \"staged\";\n"
  }

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    dir = Path.join(System.tmp_dir!(), "staged_build_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, dir)

    on_exit(fn ->
      if prev, do: Application.put_env(:arca, :base_path, prev)
      File.rm_rf!(dir)
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()
    ScriptedBuilder.start!()

    ctx = Sanctum.TestContext.local()
    :ok = Arca.ensure_roots(Sanctum.Context.actor(ctx))
    {:ok, ctx: ctx}
  end

  defp built(outputs),
    do: %{language: :javascript, target_type: :tincture, outputs: outputs, diagnostics: []}

  # What the athanor's store holds: each committed unit is one commit row,
  # and each build one build row.
  defp stored(ctx) do
    import Ecto.Query, only: [from: 2]

    {Arca.Repo.aggregate(
       from(c in StorageCommit, where: c.athanor_id == ^ctx.athanor_id),
       :count
     ), Arca.Repo.aggregate(BuildRecord, :count)}
  end

  test "sends the sources as they are and answers the verified files, storing nothing", %{
    ctx: ctx
  } do
    outputs = %{"index.html" => "<html>built</html>", "assets/index-a1.js" => "console.log(1)"}

    ScriptedBuilder.script([
      {:stream, [{:progress, :compiling, "Building the page"}, {:result, built(outputs)}]}
    ])

    test = self()
    before = stored(ctx)

    assert {:ok, %{files: ^outputs, digest: digest, size: size}} =
             Builds.build_staged(ctx, @sources,
               reference: "tincture:local.staged",
               on_progress: &send(test, {:progress, &1})
             )

    assert {digest, size} == Prima.Digest.file_set(outputs)
    assert_received {:progress, %{phase: :compiling, message: "Building the page"}}

    assert [request] = ScriptedBuilder.requests()
    assert request.sources == @sources
    assert {request.language, request.target_type} == {:javascript, :tincture}
    assert request.athanor_id == ctx.athanor_id

    # Nothing of it is stored: no unit committed, no build row.
    assert stored(ctx) == before
    assert {_commits, 0} = before
  end

  test "a server with no builds service refuses it unavailable before any request", %{ctx: ctx} do
    ScriptedBuilder.configure!(nil, nil)

    assert {:error, %Prima.Refusal{class: :unavailable, message: message} = refusal} =
             Builds.build_staged(ctx, @sources)

    assert message ==
             "builds are disabled on this server: no builds service is configured " <>
               "(CYFR_LOCUS_BUILDS_URL and CYFR_LOCUS_BUILDS_KEY)"

    assert Prima.Refusal.classify(refusal) == refusal
    assert ScriptedBuilder.requests() == []
  end

  test "a package manifest without its lockfile is refused before any request", %{ctx: ctx} do
    assert {:error, sentence} =
             Builds.build_staged(ctx, Map.delete(@sources, "package-lock.json"))

    assert sentence =~ "package-lock.json"
    assert ScriptedBuilder.requests() == []
  end

  @tag :capture_log
  test "a refused, failed or timed-out build is answered as compile answers it, storing nothing",
       %{ctx: ctx} do
    log = ["src/main.tsx(1,1): error TS2304: Cannot find name 'x'."]
    before = stored(ctx)

    ScriptedBuilder.script([
      {:refuse, {:failed, {:status, 2}}, log},
      {:refuse, {:timeout, 270_000}, log},
      {:refuse, {:capacity, 2}}
    ])

    assert {:error, "Compilation failed (exit 2): " <> _} = Builds.build_staged(ctx, @sources)

    assert {:error, {:timeout, "Compilation timed out after 270000 ms"}} =
             Builds.build_staged(ctx, @sources)

    assert {:error, "Build capacity is full (2 concurrent) — retry shortly"} =
             Builds.build_staged(ctx, @sources)

    # Past its own deadline the request is ended here.
    ScriptedBuilder.script([{:stream, [{:hold, self()}]}])

    assert {:error, {:timeout, "The build passed its deadline and was ended; nothing was saved"}} =
             Builds.build_staged(ctx, @sources, budget_ms: 300)

    assert_received {:scripted_builder, :holding, _handler}
    assert_receive {:scripted_builder, :disconnected}, 15_000
    assert stored(ctx) == before
  end

  test "a caller killed while the builder works takes the request with it", %{ctx: ctx} do
    test = self()
    ScriptedBuilder.script([{:stream, [{:hold, test}]}])
    before = stored(ctx)

    caller = spawn(fn -> Builds.build_staged(ctx, @sources) end)
    ref = Process.monitor(caller)
    assert_receive {:scripted_builder, :holding, _handler}, 15_000

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}, 5_000
    assert_receive {:scripted_builder, :disconnected}, 15_000
    assert stored(ctx) == before
  end
end
