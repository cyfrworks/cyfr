# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.SeedBundleTest do
  @moduledoc """
  The seed tree is the model-catalyst roster. Tests read it; they do not
  keep a vendor list of their own.
  """

  use ExUnit.Case, async: true

  alias Cyfr.Test.SeedBundle

  test "model_chat_units lists shipped contract catalysts and omits the hands" do
    units = SeedBundle.model_chat_units()
    assert [_ | _] = units

    for unit <- units do
      assert Cyfr.Models.speaks_chat?(unit.manifest)
      assert unit.type == "catalyst"
      assert unit.ref == "catalyst:local.#{unit.name}"
      assert unit.rel == "catalysts/local/#{unit.name}/#{unit.version}"
    end

    names = Enum.map(units, & &1.name)
    refute "files" in names
    refute "http" in names
  end

  test "local_unit! takes the newest shipped version of a named hand" do
    files = SeedBundle.local_unit!("catalysts", "files")
    refute Cyfr.Models.speaks_chat?(files.manifest)
    assert files.ref == "catalyst:local.files"
    assert files.rel == "catalysts/local/files/#{files.version}"
  end

  test "local_unit! finds a shipped formula by name" do
    formula = SeedBundle.local_unit!("formulas", "list-models")
    assert formula.type == "formula"
    assert formula.ref == "formula:local.list-models"
    assert formula.rel == "formulas/local/list-models/#{formula.version}"
  end
end
