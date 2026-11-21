# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LoginDirectoryTest do
  @moduledoc """
  The directory the public sign-in page names (`PrismWeb.LoginLive`,
  `tests/fixtures/login_directory.json`): for each directory a CYFR may
  name, the page served to a signed-out browser carries it once, whole, in
  the one attribute the CYFR app's reader reads, double-quoted as that
  reader reads it.
  """

  # Each case names a directory in the application environment, which
  # every concurrent test reads.
  use CyfrWeb.ConnCase, async: false

  @vectors Path.expand("../../../../../tests/fixtures/login_directory.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  test "the page names each directory once, whole, in the attribute the app reads", %{conn: conn} do
    attribute = @vectors["attribute"]

    for directory <- @vectors["rendered"] do
      html =
        Prima.Test.Env.with_app_env(:sanctum, :directory_url, directory, fn ->
          conn |> get(@vectors["path"]) |> html_response(200)
        end)

      assert length(String.split(html, attribute)) == 2,
             "#{directory}: the page names #{attribute} other than once"

      assert [_, named] = Regex.run(~r/\s#{attribute}="([^"]*)"/, html)
      assert Phoenix.HTML.html_escape(directory) |> Phoenix.HTML.safe_to_string() == named
    end
  end
end
