# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.CascadeTest do
  @moduledoc "A cascade whose store cannot list the children answers the error and fails nothing."

  use ExUnit.Case, async: false

  alias Crucible.Cascade

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    :ok
  end

  test "children that cannot be listed are answered as the store's error, never a raise" do
    assert Cascade.fail_children_of("exec_no_such_parent") == :ok

    # Rolled back with the sandbox.
    Arca.Repo.query!("ALTER TABLE executions RENAME TO executions_unreadable")

    assert {:error, _reason} = Cascade.fail_children_of("exec_no_such_parent")
  end
end
