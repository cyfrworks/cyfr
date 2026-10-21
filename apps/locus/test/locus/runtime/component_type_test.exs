# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.ComponentTypeTest do
  use ExUnit.Case, async: true

  alias Locus.Runtime.ComponentType

  describe "parse/1" do
    test "a missing type is an error, not a reagent" do
      assert {:error, _} = ComponentType.parse(nil)
    end

    test "parses string types" do
      assert {:ok, :catalyst} = ComponentType.parse("catalyst")
      assert {:ok, :reagent} = ComponentType.parse("reagent")
      assert {:ok, :formula} = ComponentType.parse("formula")
    end

    test "a type is a string: an atom is refused" do
      for type <- [:catalyst, :reagent, :formula] do
        assert {:error, "Invalid component type: " <> _} = ComponentType.parse(type)
      end
    end

    test "returns error for invalid type" do
      assert {:error, msg} = ComponentType.parse("invalid")
      assert msg =~ "Invalid component type"
      assert msg =~ "catalyst, reagent, formula"
    end

    test "every canonical executable type parses, and the canonical list is the typespec's" do
      # The typespec is hand-written (`:catalyst | :reagent | :formula`)
      # beside a derived value list. A new executable type in
      # Prima.ComponentRef fails this literal until both the assertion and
      # the typespec are updated, so the spec cannot go silently stale.
      assert Prima.ComponentRef.executable_types() == ~w(catalyst reagent formula)

      for type <- Prima.ComponentRef.executable_types() do
        atom = String.to_existing_atom(type)
        assert {:ok, ^atom} = ComponentType.parse(type)
      end
    end
  end

  describe "wasi_options/1" do
    test "reagent returns WasiP2Options with allow_http: false" do
      opts = ComponentType.wasi_options(:reagent)
      assert %Wasmex.Wasi.WasiP2Options{} = opts
      assert opts.allow_http == false
      assert opts.inherit_stdin == false
      assert opts.inherit_stdout == false
      assert opts.inherit_stderr == false
    end

    test "formula returns WasiP2Options with allow_http: false" do
      opts = ComponentType.wasi_options(:formula)
      assert %Wasmex.Wasi.WasiP2Options{} = opts
      assert opts.allow_http == false
      assert opts.inherit_stdin == false
      assert opts.inherit_stdout == false
      assert opts.inherit_stderr == false
    end

    test "catalyst returns WasiP2Options with allow_http: false (uses host function)" do
      opts = ComponentType.wasi_options(:catalyst)
      assert %Wasmex.Wasi.WasiP2Options{} = opts
      assert opts.allow_http == false
      assert opts.inherit_stdin == false
      assert opts.inherit_stdout == false
      assert opts.inherit_stderr == false
    end

    test "all types have empty args and env by default" do
      for type <- [:catalyst, :reagent, :formula] do
        opts = ComponentType.wasi_options(type)
        assert opts.args == []
        assert opts.env == %{}
      end
    end
  end
end
