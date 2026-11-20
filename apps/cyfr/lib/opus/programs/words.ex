# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs.Words do
  @moduledoc """
  The words a program is started with after its pinned command: what a
  person typed after it (a password, a sign-in code, whatever the program
  takes). They are wrapped where they enter, the gate's open, and travel
  wrapped through the
  terminal, the box's open and every message between them, so
  a status, a debug log or a crash report that prints one prints how many
  words there are and none of them. They are unwrapped in one place, where
  the open is encoded for the wire (`Opus.Programs.Session.open/2`).
  Each is readable text (`readable?/1`).
  """

  @enforce_keys [:list]
  defstruct [:list]

  @type t :: %__MODULE__{list: [String.t()]}

  @doc "Wrap `words`; a value already wrapped is returned as it is."
  @spec new(t() | [String.t()]) :: t()
  def new(%__MODULE__{} = words), do: words
  def new(words) when is_list(words), do: %__MODULE__{list: words}

  @doc """
  Whether `word` is text a person can read whole: valid UTF-8 holding no
  control character (C0, DEL or C1). Every word a program is started
  with is one, so wherever a start is shown, each word reads as it will
  run.
  """
  @spec readable?(term()) :: boolean()
  def readable?(word) when is_binary(word),
    do: String.valid?(word) and not Regex.match?(~r/[\x{0}-\x{1F}\x{7F}-\x{9F}]/u, word)

  def readable?(_word), do: false

  @doc "The words, for the wire."
  @spec list(t()) :: [String.t()]
  def list(%__MODULE__{list: list}), do: list

  defimpl Inspect, for: Opus.Programs.Words do
    use Boundary, classify_to: Opus

    def inspect(%{list: list}, _opts), do: "#Opus.Programs.Words<#{length(list)} words>"
  end
end
