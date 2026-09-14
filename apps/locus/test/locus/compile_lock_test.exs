# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.CompileLockTest do
  @moduledoc """
  A Rust component's `Cargo.lock` across its builds: the first build
  resolves one and keeps it in the unit; later builds are locked to it, so
  a dependency added without re-resolving fails with cargo's own message;
  `resolve` re-resolves and keeps the new lock.
  """
  use ExUnit.Case, async: false

  alias Compendium.ComponentPath
  alias Locus.MCP

  @moduletag :requires_cargo_component
  @moduletag timeout: 900_000

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

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    dir = Path.join(System.tmp_dir!(), "compile_lock_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, dir)

    on_exit(fn ->
      if prev, do: Application.put_env(:cyfr, :base_path, prev)
      File.rm_rf!(dir)
    end)

    ctx = Sanctum.TestContext.local()
    :ok = Arca.ensure_roots(ctx)
    :ok = Arca.put(ctx, @src ++ ["src", "lib.rs"], @lib_rs)
    :ok = Arca.put(ctx, @src ++ ["Cargo.toml"], Locus.Builder.cargo_toml_for(:reagent))

    {:ok, ctx: ctx}
  end

  test "create, build, add a dependency, re-resolve, rebuild", %{ctx: ctx} do
    assert {:ok, %{status: "compiled"}} = compile(ctx)
    assert {:ok, first_lock} = Arca.get(ctx, @src ++ ["Cargo.lock"])
    assert first_lock =~ ~s(name = "wit-bindgen-rt")
    refute first_lock =~ ~s(name = "smallvec")

    {:ok, cargo_toml} = Arca.get(ctx, @src ++ ["Cargo.toml"])

    :ok =
      Arca.put(
        ctx,
        @src ++ ["Cargo.toml"],
        String.replace(cargo_toml, "[dependencies]\n", "[dependencies]\nsmallvec = \"1\"\n")
      )

    assert {:error, message} = compile(ctx)
    assert message =~ "--locked"
    assert {:ok, ^first_lock} = Arca.get(ctx, @src ++ ["Cargo.lock"])

    assert {:ok, %{status: "compiled"}} = compile(ctx, %{"resolve" => true})
    assert {:ok, resolved_lock} = Arca.get(ctx, @src ++ ["Cargo.lock"])
    assert resolved_lock =~ ~s(name = "smallvec")

    assert {:ok, %{status: "compiled"}} = compile(ctx)
    assert {:ok, ^resolved_lock} = Arca.get(ctx, @src ++ ["Cargo.lock"])
  end

  defp compile(ctx, extra \\ %{}) do
    MCP.handle(
      "build",
      ctx,
      Map.merge(%{"action" => "compile", "reference" => "reagent:local.locker:0.1.0"}, extra)
    )
  end
end
