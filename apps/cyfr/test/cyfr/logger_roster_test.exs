# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.LoggerRosterTest do
  @moduledoc """
  The metadata roster existed in three places: `config/config.exs`,
  `config/runtime.exs`'s JSON branch, and a hardcoded fallback inside
  `Prima.JsonFormatter` — which carried three keys the config never
  requested and therefore never emitted.

  Config files run before application code is loaded, so the roster cannot
  literally be one expression. It can be one *checked* expression: the keys
  `Prima.LoggerContext` sets must be the keys the formatter is configured to
  print, or the metadata is written and silently dropped.
  """

  use ExUnit.Case, async: true

  # The one module that formats an exception for every application
  # (`Prima.LogFilter`).
  @formatter Prima.LogFilter

  # Every `Exception` function that writes a frame's or a call's arguments
  # into text: a stacktrace, an exit naming its call, an MFA, or a
  # function-clause error blamed with its arguments.
  @formatters [
    :blame,
    :blame_mfa,
    :format,
    :format_banner,
    :format_exit,
    :format_stacktrace,
    :format_stacktrace_entry,
    :format_mfa,
    :format_fa
  ]

  defp root, do: Path.expand("../../../..", __DIR__)

  test "the configured roster carries every key LoggerContext sets" do
    configured = Application.get_env(:logger, :default_formatter, [])[:metadata]

    assert is_list(configured),
           "config/config.exs must set :logger, :default_formatter, metadata: [...]"

    missing = Prima.LoggerContext.keys() -- configured

    assert missing == [],
           """
           `Prima.LoggerContext` sets metadata the log roster does not print:

             #{inspect(missing)}

           Add them to `metadata:` in config/config.exs, or stop setting them.
           """
  end

  test "no application formats an exception but through Prima.LogFilter" do
    calls =
      for app <- applications(),
          {module, beam} <- lib_beams(app),
          module != @formatter,
          call <- exception_formatters(beam),
          do: {module, call}

    assert calls == [],
           """
           These write a frame's or a call's arguments into text:

             #{Enum.map_join(calls, "\n  ", &inspect/1)}

           Use Prima.LogFilter.format_exception/3 or format_stacktrace/1.
           """

    assert {Exception, :format, 3} in imports(beam!(@formatter))
  end

  test "a planted Exception.format is refused" do
    on_exit(fn ->
      :code.purge(Cyfr.LoggerRosterTest.Plant)
      :code.delete(Cyfr.LoggerRosterTest.Plant)
    end)

    [{_module, beam}] =
      Code.compile_string("""
      defmodule Cyfr.LoggerRosterTest.Plant do
        def text(error, stacktrace), do: Exception.format(:error, error, stacktrace)
      end
      """)

    assert exception_formatters(beam) == [{Exception, :format, 3}]
  end

  test "runtime.exs overrides only the format, never the roster" do
    runtime = File.read!(Path.join(root(), "config/runtime.exs"))

    lines = String.split(runtime, "\n")

    # The call and any continuation lines its keyword list spills onto.
    json_branch =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _i} ->
        String.contains?(line, "config :logger, :default_formatter")
      end)
      |> Enum.flat_map(fn {_line, i} -> Enum.slice(lines, i, 4) end)

    assert json_branch != [], "the JSON log format branch went missing"

    refute Enum.any?(json_branch, &String.contains?(&1, "metadata")),
           """
           config/runtime.exs re-declares the metadata roster. `Config`
           deep-merges keyword values, so config.exs's roster already carries
           through; a second copy only supplies something to go stale.
           """
  end

  # Every Mix application of the umbrella; the Go programs have none.
  defp applications do
    apps =
      for mix <- Path.wildcard(Path.join(root(), "apps/*/mix.exs")),
          do: mix |> Path.dirname() |> Path.basename() |> String.to_atom()

    assert :prima in apps and :cyfr in apps and :opus in apps and :locus in apps
    apps
  end

  # Every module of `app` compiled from this checkout's apps/<app>/lib,
  # with its beam. The applications share one build, read from disk, so an
  # application this one does not depend on is read too; an application
  # that yields none was built elsewhere, and the check would read nothing.
  defp lib_beams(app) do
    ebin = Path.join([Mix.Project.build_path(), "lib", Atom.to_string(app), "ebin"])
    lib = Path.join([root(), "apps", Atom.to_string(app), "lib"]) <> "/"

    beams =
      for path <- Path.wildcard(Path.join(ebin, "*.beam")),
          {:ok, {module, [compile_info: info]}} =
            :beam_lib.chunks(String.to_charlist(path), [:compile_info]),
          String.starts_with?(to_string(info[:source]), lib),
          do: {module, File.read!(path)}

    assert beams != [], "no module of #{app} under #{ebin} was compiled from #{lib}"
    beams
  end

  defp beam!(module), do: elem(:code.get_object_code(module), 1)

  defp exception_formatters(beam),
    do: for({Exception, f, _a} = call <- imports(beam), f in @formatters, do: call)

  defp imports(beam) do
    {:ok, {_module, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])
    imports
  end
end
