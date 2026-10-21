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

  setup do
    # Random bytes, not `System.unique_integer/1`, which repeats across VMs:
    # another VM's cleanup must never remove this one's beams.
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    dir = Path.join(System.tmp_dir!(), "test_beams_#{suffix}")
    on_exit(fn -> File.rm_rf!(dir) end)

    # A checkout whose own path holds `/lib/`, as one under `/var/lib/` does.
    root = Path.join(dir, "var/lib/checkout")
    ebin = Path.join(dir, "ebin")
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
  # unloaded again, deleted and then purged, so only the file remains and
  # the next test compiles the same module afresh.
  defp beam!(ebin, source) do
    module = __MODULE__.Planted
    [{^module, binary}] = Code.compile_string("defmodule #{inspect(module)}, do: nil", source)
    :code.delete(module)
    :code.purge(module)
    path = Path.join(ebin, "#{module}.beam")
    File.write!(path, binary)
    path
  end
end
