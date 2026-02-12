defmodule Opus.WasiCapabilitiesTest do
  @moduledoc """
  Tests for WASI capability enforcement per PRD §5.1.

  Verifies that component types receive the correct WASI capabilities:
  - Catalyst: Full WASI including HTTP
  - Reagent: WASI with logging, clocks, random; NO HTTP
  - Formula: Same as Reagent
  """
  use ExUnit.Case, async: true

  alias Opus.ComponentType
  alias Wasmex.Wasi.WasiP2Options

  describe "WASI capability mappings per PRD §5.1" do
    test "catalyst gets WASI with HTTP via host function (not native)" do
      opts = ComponentType.wasi_options(:catalyst)

      assert %WasiP2Options{} = opts
      # Catalysts use cyfr:http/fetch host function, not wasi:http/outgoing-handler
      assert opts.allow_http == false, "Catalyst uses cyfr:http/fetch, not native WASI HTTP"
      assert opts.inherit_stdout == true, "Catalyst must have stdout for logging"
      assert opts.inherit_stderr == true, "Catalyst must have stderr for logging"
    end

    test "reagent gets WASI but NO HTTP" do
      opts = ComponentType.wasi_options(:reagent)

      assert %WasiP2Options{} = opts, "Reagent must get WasiP2Options (not nil)"
      assert opts.allow_http == false, "Reagent must NOT have HTTP access"
      assert opts.inherit_stdout == true, "Reagent must have stdout for logging"
      assert opts.inherit_stderr == true, "Reagent must have stderr for logging"
    end

    test "formula gets WASI but NO HTTP (same as reagent)" do
      opts = ComponentType.wasi_options(:formula)

      assert %WasiP2Options{} = opts, "Formula must get WasiP2Options (not nil)"
      assert opts.allow_http == false, "Formula must NOT have HTTP access"
      assert opts.inherit_stdout == true, "Formula must have stdout for logging"
      assert opts.inherit_stderr == true, "Formula must have stderr for logging"
    end

    test "reagent and formula have identical WASI options" do
      reagent_opts = ComponentType.wasi_options(:reagent)
      formula_opts = ComponentType.wasi_options(:formula)

      assert reagent_opts.allow_http == formula_opts.allow_http
      assert reagent_opts.inherit_stdin == formula_opts.inherit_stdin
      assert reagent_opts.inherit_stdout == formula_opts.inherit_stdout
      assert reagent_opts.inherit_stderr == formula_opts.inherit_stderr
      assert reagent_opts.args == formula_opts.args
      assert reagent_opts.env == formula_opts.env
    end
  end

  describe "stdin isolation" do
    test "all component types have stdin disabled" do
      for type <- [:catalyst, :reagent, :formula] do
        opts = ComponentType.wasi_options(type)
        assert opts.inherit_stdin == false,
          "#{type} must have stdin disabled for security"
      end
    end
  end

  describe "logging capability" do
    test "all component types can log via stdout/stderr" do
      for type <- [:catalyst, :reagent, :formula] do
        opts = ComponentType.wasi_options(type)
        assert opts.inherit_stdout == true,
          "#{type} must have stdout enabled for logging"
        assert opts.inherit_stderr == true,
          "#{type} must have stderr enabled for logging"
      end
    end
  end

  describe "HTTP capability differentiation" do
    test "no component type has native WASI HTTP (catalysts use host function)" do
      catalyst_opts = ComponentType.wasi_options(:catalyst)
      reagent_opts = ComponentType.wasi_options(:reagent)
      formula_opts = ComponentType.wasi_options(:formula)

      # All types have allow_http: false; catalysts use cyfr:http/fetch host function instead
      assert catalyst_opts.allow_http == false
      assert reagent_opts.allow_http == false
      assert formula_opts.allow_http == false
    end
  end

  describe "unknown types are secure" do
    test "unknown type returns nil (no WASI at all)" do
      assert ComponentType.wasi_options(:unknown) == nil
      assert ComponentType.wasi_options(:invalid) == nil
      assert ComponentType.wasi_options(:malicious) == nil
    end
  end

  describe "WASI options structure" do
    test "all valid types return properly structured WasiP2Options" do
      for type <- [:catalyst, :reagent, :formula] do
        opts = ComponentType.wasi_options(type)

        assert %WasiP2Options{
          allow_http: _,
          inherit_stdin: _,
          inherit_stdout: _,
          inherit_stderr: _,
          args: args,
          env: env
        } = opts

        assert is_list(args), "#{type} args must be a list"
        assert is_map(env), "#{type} env must be a map"
      end
    end

    test "default args and env are empty" do
      for type <- [:catalyst, :reagent, :formula] do
        opts = ComponentType.wasi_options(type)
        assert opts.args == [], "#{type} should have empty default args"
        assert opts.env == %{}, "#{type} should have empty default env"
      end
    end
  end
end
