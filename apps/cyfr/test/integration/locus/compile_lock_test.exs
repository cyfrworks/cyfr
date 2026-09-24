# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Integration.Locus.CompileLockTest do
  @moduledoc """
  A Rust component's `Cargo.lock` across its builds, built for real by the
  Locus builds service over the signed build wire
  (`Cyfr.Test.LocusService`): the first build resolves one and it is kept
  in the unit; later builds are locked to it, so a dependency added without
  re-resolving fails with cargo's own message and the kept lock stands;
  `resolve` re-resolves and keeps the new lock, which the next build is
  locked to.
  """
  use ExUnit.Case, async: false

  alias Compendium.Builds.Provider
  alias Compendium.ComponentPath
  alias Cyfr.Test.LocusService

  @moduletag :requires_cargo_component
  @moduletag timeout: 900_000

  @reference "reagent:local.locker:0.1.0"
  @src ComponentPath.version_dir("reagent", "local", "locker", "0.1.0") ++ ["src"]
  @lib_rs """
  #[allow(warnings)]
  mod bindings;

  use bindings::exports::cyfr::reagent::compute::Guest;

  struct Locker;
  bindings::export!(Locker with_types_in bindings);

  impl Guest for Locker {
      fn compute(input: String) -> String {
          input
      }
  }
  """

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    dir = Path.join(System.tmp_dir!(), "compile_lock_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, dir)

    on_exit(fn ->
      if prev, do: Application.put_env(:arca, :base_path, prev)
      File.rm_rf!(dir)
    end)

    # Registered after the restore, so it runs before it: the builds'
    # registrations stop while the tree they write is still theirs.
    Cyfr.Test.Sandbox.stop_work_on_exit()
    LocusService.configure!()

    ctx = Sanctum.TestContext.local()
    :ok = Arca.ensure_roots(Sanctum.Context.actor(ctx))
    :ok = Arca.put(Sanctum.Context.actor(ctx), @src ++ ["src", "lib.rs"], @lib_rs)

    :ok =
      Arca.put(
        Sanctum.Context.actor(ctx),
        @src ++ ["Cargo.toml"],
        Prima.CargoToml.template(:reagent)
      )

    {:ok, ctx: ctx}
  end

  test "create, build, add a dependency, re-resolve, rebuild", %{ctx: ctx} do
    assert Cyfr.RuntimeConfig.locus_builds_url() == LocusService.url()

    assert {:ok, %{status: "compiled"}} = compile(ctx)
    assert {:ok, first_lock} = Arca.get(Sanctum.Context.actor(ctx), @src ++ ["Cargo.lock"])
    assert first_lock =~ ~s(name = "wit-bindgen-rt")
    refute first_lock =~ ~s(name = "smallvec")

    {:ok, cargo_toml} = Arca.get(Sanctum.Context.actor(ctx), @src ++ ["Cargo.toml"])

    :ok =
      Arca.put(
        Sanctum.Context.actor(ctx),
        @src ++ ["Cargo.toml"],
        String.replace(cargo_toml, "[dependencies]\n", "[dependencies]\nsmallvec = \"1\"\n")
      )

    assert {:error, reason} = compile(ctx)
    assert Cyfr.Ops.Error.render(reason) =~ "--locked"
    assert {:ok, ^first_lock} = Arca.get(Sanctum.Context.actor(ctx), @src ++ ["Cargo.lock"])

    assert {:ok, %{status: "compiled"}} = compile(ctx, %{"resolve" => true})
    assert {:ok, resolved_lock} = Arca.get(Sanctum.Context.actor(ctx), @src ++ ["Cargo.lock"])
    assert resolved_lock =~ ~s(name = "smallvec")

    assert {:ok, %{status: "compiled"}} = compile(ctx)
    assert {:ok, ^resolved_lock} = Arca.get(Sanctum.Context.actor(ctx), @src ++ ["Cargo.lock"])

    # Each successful build started its registration; it ends while the
    # tree it writes is still this test's.
    Prima.Test.Wait.wait_until(
      fn -> Task.Supervisor.children(Compendium.Builds.TaskSupervisor) == [] end,
      60_000,
      "the builds' registrations to finish"
    )
  end

  defp compile(ctx, extra \\ %{}) do
    Provider.handle(
      "build",
      ctx,
      Map.merge(%{"action" => "compile", "reference" => @reference}, extra)
    )
  end
end
