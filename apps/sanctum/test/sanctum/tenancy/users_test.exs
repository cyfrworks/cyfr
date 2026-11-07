# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.UsersTest do
  @moduledoc """
  How a person is named to other people (`Sanctum.Tenancy.Users.display_name/1`):
  their display name, else their email, else `@` and their recorded name,
  else "someone". Their id is never shown, not even for a row that cannot
  be read.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Tenancy.Users

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp person!(attrs) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(
        Map.merge(%{id: "github|https://github.com|named-#{n}", provider: "github"}, attrs)
      )

    user
  end

  defp named!(user, name) do
    {:ok, _user} = Users.set_namespace(user, name)
    user.id
  end

  test "a display name comes first, then an email, then the recorded name, then someone" do
    n = System.unique_integer([:positive])

    everything = person!(%{name: "Mira", email: "mira#{n}@example.com"})
    assert Users.display_name(named!(everything, "mira-#{n}")) == "Mira"

    email = person!(%{email: "only#{n}@example.com"})
    assert Users.display_name(named!(email, "only-#{n}")) == "only#{n}@example.com"

    name_only = person!(%{})
    assert Users.display_name(named!(name_only, "plain-#{n}")) == "@plain-#{n}"

    nothing = person!(%{})
    assert Users.display_name(nothing.id) == "someone"
    refute Users.display_name(nothing.id) =~ nothing.id
  end

  test "no person, or one that cannot be read, is someone and never their id" do
    assert Users.display_name(nil) == "someone"
    assert Users.display_name("usr_" <> String.duplicate("0", 26)) == "someone"
  end
end
