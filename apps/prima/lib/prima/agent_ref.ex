# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.AgentRef do
  @moduledoc """
  The Aqua agent as a consent source ref: `agent:local.<name>`.

  An agent is a source node like any component's — it plans, consents,
  activates and loads through the same machinery — so the identity domain
  has to recognise one, and the component domain has to mint one. The
  naming is the part both sides agree on and is spelled here: the type
  segment, the publisher, the soul's reserved name, and the predicate that
  says whether a ref is an agent's.

  What an agent row *contains* is `Compendium.AgentSource`'s and what its
  file looks like is `Compendium.AquaAgent`'s; neither is here.
  """

  @type_name "agent"
  @publisher "local"
  @soul "aqua"

  @doc """
  The source type an agent ref carries.

  ## Examples

      iex> Prima.AgentRef.type()
      "agent"

  """
  @spec type() :: String.t()
  def type, do: @type_name

  @doc """
  The name-level ref of the agent `name`.

  ## Examples

      iex> Prima.AgentRef.ref("web")
      "agent:local.web"

  """
  @spec ref(String.t()) :: String.t()
  def ref(name) when is_binary(name), do: Prima.ComponentRef.build(@type_name, @publisher, name)

  @doc """
  The soul's reserved name: the one assistant an athanor has, the file at
  the root of its tree and never a crew member.

  ## Examples

      iex> Prima.AgentRef.soul_name()
      "aqua"

  """
  @spec soul_name() :: String.t()
  def soul_name, do: @soul

  @doc """
  The sentence a person reads where an agent file that still holds the
  retired `tool_policy` is refused (`Compendium.AquaAgent`): on the Aqua
  page, as the line a thread is given, and for a post that names no one.
  It says what to change and that nothing else must.
  """
  @spec tool_policy_retired() :: String.t()
  def tool_policy_retired,
    do:
      "Aqua's file still lists its tools under `tool_policy:`, which CYFR no longer reads, " <>
        "so Aqua can't answer. In Files, open aqua/aqua.md and replace that header with " <>
        "`tools:`, writing each tool on its own line as `- name`, without its `auto` or " <>
        "`ask`. Nothing else in the file needs to change."

  @doc """
  The sentence a person reads where the soul's file still names a brain,
  a model, options or a mode of its own
  (`Compendium.AquaAgent`), which Aqua takes from the crew member it runs
  on: on the Aqua page, as the line a thread is given, and for a post
  that names no one. It says what to delete and where to choose instead.
  """
  @spec seat_has_brain() :: String.t()
  def seat_has_brain,
    do:
      "Aqua's file still names a brain of its own, and Aqua now runs on a crew member you " <>
        "choose, so Aqua can't answer. In Files, open aqua/aqua.md and delete its " <>
        "`catalyst_ref`, `program`, `model`, `options` and `mode` lines, then on " <>
        "the Aqua page choose the crew member Aqua runs on."

  @doc """
  The sentence a person reads where the soul's file is refused for an
  entry of its `tools` list that names no one action (`Compendium.AquaAgent`:
  a `tool.*`, a null, anything outside the list's grammar): on the Aqua
  page, as the line a thread is given, and for a post that names no one.
  It names the entry and says to list each action by name.
  """
  @spec tools_entry_invalid(term()) :: String.t()
  def tools_entry_invalid(entry),
    do:
      "Aqua's file lists #{entry_words(entry)} among its tools, which names no one action, " <>
        "so Aqua can't answer. In Files, open aqua/aqua.md and list each action by name on " <>
        "its own line under `tools:`, as `- files.read`: a tool's actions are listed one by " <>
        "one, never as `files.*`."

  defp entry_words(entry) when is_binary(entry), do: "`#{entry}`"
  defp entry_words(nil), do: "an empty entry"
  defp entry_words(entry), do: "`#{inspect(entry)}`"

  @doc """
  The soul's name-level ref.

  ## Examples

      iex> Prima.AgentRef.soul_ref()
      "agent:local.aqua"

  """
  @spec soul_ref() :: String.t()
  def soul_ref, do: ref(@soul)

  @doc """
  Whether `name` is the soul's — reserved, never a crew member.

  ## Examples

      iex> Prima.AgentRef.soul?("aqua")
      true

      iex> Prima.AgentRef.soul?("web")
      false

  """
  @spec soul?(term()) :: boolean()
  def soul?(name), do: name == @soul

  @doc """
  Whether `ref` names an agent source.

  ## Examples

      iex> Prima.AgentRef.agent_ref?("agent:local.web")
      true

      iex> Prima.AgentRef.agent_ref?("catalyst:local.files")
      false

  """
  @spec agent_ref?(term()) :: boolean()
  def agent_ref?(ref) when is_binary(ref) do
    match?({:ok, %Prima.ComponentRef{type: @type_name}}, Prima.ComponentRef.parse(ref))
  end

  def agent_ref?(_), do: false
end
