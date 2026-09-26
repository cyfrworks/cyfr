# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ConfirmationClass do
  @moduledoc """
  The confirmation classes: what a paired client may confirm, a closed
  enum ordered from least to most.

    * `none` — a guest body, a borrowed computer, a display on a cable.
      It confirms nothing.
    * `session` — an authenticated browser session or API key.
    * `paired` — a client that completed the pairing ceremony, from a
      device the person deliberately paired.
    * `strong` — a paired client holding a WebAuthn credential with user
      verification.

  Each class confirms everything the classes below it confirm. Which class
  a client holds is Sanctum's to assign from its standing, and which class
  an action requires is Sanctum's policy (`Sanctum.Pairing`); this module
  is only the vocabulary both sides of a wire agree on.

  On the wire a class is its lowercase name. The ordered list is pinned
  in `tests/fixtures/layout.json` under `confirmation_classes` until the
  device protocol's own vector file exists to hold it.
  """

  @classes [:none, :session, :paired, :strong]

  @typedoc "A confirmation class."
  @type t :: :none | :session | :paired | :strong

  @doc "Every class, least first."
  @spec all() :: [t()]
  def all, do: @classes

  @doc "Whether `term` is a class."
  @spec valid?(term()) :: boolean()
  def valid?(term), do: term in @classes

  @doc """
  Whether a client holding `held` confirms what `required` asks for:
  `held` is `required` or above it. Anything that is not a class holds
  nothing and requires what nothing satisfies.
  """
  @spec at_least?(t(), t()) :: boolean()
  def at_least?(held, required) when held in @classes and required in @classes,
    do: rank(held) >= rank(required)

  def at_least?(_held, _required), do: false

  @doc "A class's wire spelling."
  @spec to_string(t()) :: String.t()
  def to_string(class) when class in @classes, do: Atom.to_string(class)

  @doc "A class from its wire spelling; anything else is `{:error, :unknown_class}`."
  @spec parse(term()) :: {:ok, t()} | {:error, :unknown_class}
  def parse("none"), do: {:ok, :none}
  def parse("session"), do: {:ok, :session}
  def parse("paired"), do: {:ok, :paired}
  def parse("strong"), do: {:ok, :strong}
  def parse(_other), do: {:error, :unknown_class}

  defp rank(class), do: Enum.find_index(@classes, &(&1 == class))
end
