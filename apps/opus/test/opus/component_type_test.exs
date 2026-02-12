defmodule Opus.ComponentTypeTest do
  use ExUnit.Case, async: true

  alias Opus.ComponentType

  describe "parse/1" do
    test "parses nil as reagent (default)" do
      assert {:ok, :reagent} = ComponentType.parse(nil)
    end

    test "parses string types" do
      assert {:ok, :catalyst} = ComponentType.parse("catalyst")
      assert {:ok, :reagent} = ComponentType.parse("reagent")
      assert {:ok, :formula} = ComponentType.parse("formula")
    end

    test "parses atom types" do
      assert {:ok, :catalyst} = ComponentType.parse(:catalyst)
      assert {:ok, :reagent} = ComponentType.parse(:reagent)
      assert {:ok, :formula} = ComponentType.parse(:formula)
    end

    test "returns error for invalid type" do
      assert {:error, msg} = ComponentType.parse("invalid")
      assert msg =~ "Invalid component type"
      assert msg =~ "catalyst, reagent, formula"
    end
  end

  describe "wasi_options/1" do
    test "reagent returns WasiP2Options with allow_http: false" do
      opts = ComponentType.wasi_options(:reagent)
      assert %Wasmex.Wasi.WasiP2Options{} = opts
      assert opts.allow_http == false
      assert opts.inherit_stdin == false
      assert opts.inherit_stdout == true
      assert opts.inherit_stderr == true
    end

    test "formula returns WasiP2Options with allow_http: false" do
      opts = ComponentType.wasi_options(:formula)
      assert %Wasmex.Wasi.WasiP2Options{} = opts
      assert opts.allow_http == false
      assert opts.inherit_stdin == false
      assert opts.inherit_stdout == true
      assert opts.inherit_stderr == true
    end

    test "catalyst returns WasiP2Options with allow_http: false (uses host function)" do
      opts = ComponentType.wasi_options(:catalyst)
      assert %Wasmex.Wasi.WasiP2Options{} = opts
      assert opts.allow_http == false
      assert opts.inherit_stdin == false
      assert opts.inherit_stdout == true
      assert opts.inherit_stderr == true
    end

    test "all types have empty args and env by default" do
      for type <- [:catalyst, :reagent, :formula] do
        opts = ComponentType.wasi_options(type)
        assert opts.args == []
        assert opts.env == %{}
      end
    end

    test "unknown type defaults to nil (secure)" do
      assert ComponentType.wasi_options(:unknown) == nil
    end
  end

  describe "valid?/1" do
    test "returns true for valid types" do
      assert ComponentType.valid?(:catalyst)
      assert ComponentType.valid?(:reagent)
      assert ComponentType.valid?(:formula)
    end

    test "returns false for invalid types" do
      refute ComponentType.valid?(:unknown)
      refute ComponentType.valid?(:invalid)
    end
  end

  describe "valid_types/0" do
    test "returns list of valid types" do
      assert ComponentType.valid_types() == [:catalyst, :reagent, :formula]
    end
  end
end
