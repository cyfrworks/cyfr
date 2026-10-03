# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.VersionTest do
  @moduledoc """
  `Prima.Version.current/0` is the one version every release view states,
  and it is this application's own. The manifests that state it are held
  to it by `Cyfr.VersionDriftTest`, which reads the whole tree; this suite
  runs on the application alone.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../lib", __DIR__)

  test "the compiled version is the Prima application's" do
    assert Prima.Version.current() == to_string(Application.spec(:prima, :vsn))
    assert Prima.Version.current() =~ ~r/\A\d+\.\d+\.\d+\z/
  end

  test "no Prima beam reads Mix or an application's spec at run time" do
    modules =
      for module <- Application.spec(:prima, :modules),
          String.starts_with?(to_string(module.module_info(:compile)[:source]), @lib <> "/"),
          do: module

    assert Prima.Version in modules and Prima.BuilderProtocol in modules

    for module <- modules do
      {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(:code.which(module), [:imports])

      for {m, f, a} <- imports do
        name = Atom.to_string(m)

        refute m == Mix or String.starts_with?(name, "Elixir.Mix."),
               "#{inspect(module)} calls #{inspect(m)}.#{f}/#{a} at run time"

        refute {m, f} in [{Application, :spec}, {:application, :get_key}],
               "#{inspect(module)} reads an application spec at run time"
      end
    end
  end
end
