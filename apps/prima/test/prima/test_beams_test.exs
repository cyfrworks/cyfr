# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Test.BeamsTest do
  @moduledoc """
  `Prima.Test.Beams.production?/2` classifies a beam by its source's path
  under the umbrella root, so a checkout under `/var/lib/` still tells an
  application's `lib/` module from a test-support one.
  """

  use ExUnit.Case, async: true

  alias Prima.Test.Beams

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # A checkout whose own path holds `/lib/`, as one under `/var/lib/` does.
    root = Path.join(tmp_dir, "var/lib/checkout")
    ebin = Path.join(tmp_dir, "ebin")
    File.mkdir_p!(ebin)
    {:ok, root: root, ebin: ebin}
  end

  test "a lib source under a root inside /var/lib/ is production", %{root: root, ebin: ebin} do
    beam = beam!(ebin, Path.join(root, "apps/demo/lib/demo.ex"))

    assert Beams.production?(beam, root)
  end

  test "a test-support source under a root inside /var/lib/ is not production", %{
    root: root,
    ebin: ebin
  } do
    beam = beam!(ebin, Path.join(root, "apps/demo/test/support/demo_fixtures.ex"))

    refute Beams.production?(beam, root)
  end

  test "a lib source outside the root is not production", %{root: root, ebin: ebin} do
    beam = beam!(ebin, Path.join(Path.dirname(root), "elsewhere/apps/demo/lib/demo.ex"))

    refute Beams.production?(beam, root)
  end

  test "a beam that cannot be read is not production", %{root: root, ebin: ebin} do
    refute Beams.production?(Path.join(ebin, "Elixir.Absent.beam"), root)

    unreadable = Path.join(ebin, "Elixir.Garbled.beam")
    File.write!(unreadable, "not a beam")
    refute Beams.production?(unreadable, root)
  end

  test "an application's own beam is classified against the umbrella root by default" do
    lib = :code.which(Prima.Slots) |> to_string()
    support = :code.which(Prima.Test.Wait) |> to_string()

    assert Beams.production?(lib)
    refute Beams.production?(support)
  end

  # A beam compiled from `source`, written to `ebin`. Nothing is written at
  # `source`: the compiler records the path it is given, and the module is
  # unloaded again, so only the file remains.
  defp beam!(ebin, source) do
    module = Module.concat(__MODULE__, "Planted#{System.unique_integer([:positive])}")
    [{^module, binary}] = Code.compile_string("defmodule #{inspect(module)}, do: nil", source)
    :code.purge(module)
    :code.delete(module)
    path = Path.join(ebin, "#{module}.beam")
    File.write!(path, binary)
    path
  end
end
