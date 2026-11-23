# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.LanguageTest do
  @moduledoc """
  The person's language is stored as their own browser reports it, only
  its own key, once, and not again while it is unchanged; a report that is
  no language tag stores nothing; and a stored value out of the grammar
  reads as none.
  """
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Sanctum.Tenancy.Users

  setup do
    Cyfr.Test.Sandbox.setup!()
    n = System.unique_integer([:positive])
    local = Sanctum.TestContext.local(:prism)
    {_ctx, user} = Sanctum.TestContext.person!(%{local | user_id: "local|idp|language-#{n}"})
    {:ok, user: user}
  end

  defp row(user_id) do
    {:ok, user} = Users.get(user_id)
    user
  end

  # The moment the row was last written, set to one long past so a write
  # after it shows.
  defp written_long_ago!(user_id) do
    {1, _} =
      Arca.Repo.update_all(from(u in Arca.Schemas.User, where: u.id == ^user_id),
        set: [updated_at: ~U[2001-01-01 00:00:00.000000Z]]
      )
  end

  test "a language is stored once, only its own key, and not again while it is unchanged", %{
    user: user
  } do
    {:ok, _} = Users.put_prefs(user, %{"time_zone" => "Europe/Lisbon", "mode" => "dark"})

    assert :ok = Aqua.Language.put(user.id, "pt-PT")

    assert Users.prefs(row(user.id)) == %{
             "time_zone" => "Europe/Lisbon",
             "mode" => "dark",
             "locale" => "pt-PT"
           }

    written_long_ago!(user.id)
    assert :ok = Aqua.Language.put(user.id, "pt-PT")
    assert row(user.id).updated_at == ~U[2001-01-01 00:00:00.000000Z]

    assert :ok = Aqua.Language.put(user.id, "en-GB")
    assert Users.prefs(row(user.id))["locale"] == "en-GB"
    assert row(user.id).updated_at != ~U[2001-01-01 00:00:00.000000Z]
  end

  test "a report that is no language tag stores nothing", %{user: user} do
    assert :ok = Aqua.Language.put(user.id, "fr")

    for locale <- ["de_DE", "", "not a tag", String.duplicate("a", 65), nil, 42] do
      assert {:error, :invalid_locale} = Aqua.Language.put(user.id, locale)
      assert Users.prefs(row(user.id))["locale"] == "fr"
    end
  end

  test "a stored value out of the grammar, or none, reads as no language" do
    assert Aqua.Language.stored(%{}) == nil
    assert Aqua.Language.stored(%{"locale" => "de_DE"}) == nil
    assert Aqua.Language.stored(%{"locale" => 5}) == nil
    assert Aqua.Language.stored(%{"locale" => "zh-Hant-TW"}) == "zh-Hant-TW"
  end
end
