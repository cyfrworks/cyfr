# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.UserAgent do
  @moduledoc """
  The browser and system a browser's user agent names, in the words a
  person reads beside their session: "Safari" on "macOS". A session keeps
  these two words and never the user agent itself (`Sanctum.Session`).
  Anything it does not know is nil.
  """

  # First match wins. Chrome's family carries "Chrome/" and "Safari/", so
  # each of its own names is read first and Safari last; an iPhone's says
  # "like Mac OS X", and Android and ChromeOS also say "Linux".
  @browsers [
    {"Edg/", "Edge"},
    {"EdgA/", "Edge"},
    {"EdgiOS/", "Edge"},
    {"OPR/", "Opera"},
    {"SamsungBrowser/", "Samsung Internet"},
    {"Firefox/", "Firefox"},
    {"FxiOS/", "Firefox"},
    {"CriOS/", "Chrome"},
    {"Chrome/", "Chrome"},
    {"Safari/", "Safari"}
  ]

  @systems [
    {"iPhone", "iOS"},
    {"iPad", "iPadOS"},
    {"Android", "Android"},
    {"CrOS", "ChromeOS"},
    {"Windows", "Windows"},
    {"Macintosh", "macOS"},
    {"Linux", "Linux"}
  ]

  @doc "The `{browser, system}` `user_agent` names, each nil when it names none."
  @spec words(String.t() | nil) :: {String.t() | nil, String.t() | nil}
  def words(user_agent) when is_binary(user_agent),
    do: {first(user_agent, @browsers), first(user_agent, @systems)}

  def words(_user_agent), do: {nil, nil}

  defp first(user_agent, names) do
    Enum.find_value(names, fn {mark, name} -> if String.contains?(user_agent, mark), do: name end)
  end
end
