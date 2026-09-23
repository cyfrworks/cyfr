# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.NotesUnavailableTest do
  @moduledoc """
  A note read that crosses estates opens each one under the reader's seat
  (`Sanctum.Context.focus/2`). A seat the store cannot read is an outage,
  and says so in the notes' own vocabulary: never an estate that does not
  exist, and never an estate silently left out of an `everywhere` page.
  """

  use ExUnit.Case, async: false

  alias Aqua.Notes
  alias Sanctum.Context
  alias Sanctum.Tenancy.Athanors

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    person = "github|https://github.com|notes-#{System.unique_integer([:positive])}"
    {:ok, home} = Athanors.create_group(person, "Home")
    {:ok, other} = Athanors.create_group(person, "Other")

    ctx =
      Context.build(
        user_id: person,
        athanor_id: home.id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, ctx: ctx, other: other}
  end

  # The seat read fails while the estate listing still answers: the
  # listing selects no membership column, the seat read selects them all.
  defp seats_unreadable!,
    do: Arca.Repo.query!("ALTER TABLE memberships DROP COLUMN added_by")

  test "a locator whose seat cannot be read is unavailable, not a missing estate", %{
    ctx: ctx,
    other: other
  } do
    refute match?(
             {:error, {:unavailable, _}},
             Notes.read(ctx, "flight", "estate", athanor_id: other.id)
           )

    seats_unreadable!()

    assert {:error, {:unavailable, "Storage"}} =
             Notes.read(ctx, "flight", "estate", athanor_id: other.id)
  end

  test "an everywhere page refuses rather than leave out an estate it could not open", %{
    ctx: ctx
  } do
    assert {:ok, _page} = Notes.list(ctx, "everywhere")

    seats_unreadable!()

    assert {:error, {:unavailable, "Storage"}} = Notes.list(ctx, "everywhere")
  end
end
