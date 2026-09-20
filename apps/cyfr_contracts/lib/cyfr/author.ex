# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Author do
  @moduledoc """
  The two reserved authors a thread row may carry instead of a person's id.

  Every side of a thread agrees on them — the loop that writes a turn, the
  tape that renders it, the room excerpt that quotes it, the console that
  labels it and the row store that refuses them as a person — so the two
  names are declared once here.

  A row's author is either one of these or a person's id
  (`Cyfr.PersonId.person?/1`); nothing else is written.
  """

  @agent "aqua"
  @system "system"

  @doc """
  The author of a row the assistant wrote: its reply, and the approval
  card it proposed. It is read as the agent's own speech — what a person
  may say aloud from their own athanor, what a room excerpt renders under
  the assistant's name — so nothing a runner says in its own voice
  carries it.
  """
  @spec agent() :: String.t()
  def agent, do: @agent

  @doc """
  The author of a row written in the server's voice rather than the
  assistant's — a note about the turn (dropped, interrupted, a standing
  answer recorded or refused), an error, a line a runner posts on a
  person's behalf when no person's context applies. Never read as the
  agent's speech, never a person.
  """
  @spec system() :: String.t()
  def system, do: @system

  @doc "Both reserved authors: the names no person's id may be."
  @spec reserved() :: [String.t()]
  def reserved, do: [@agent, @system]
end
