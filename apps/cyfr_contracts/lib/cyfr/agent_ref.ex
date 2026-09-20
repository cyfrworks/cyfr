# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.AgentRef do
  @moduledoc """
  The AQUA agent as a consent source ref: `agent:local.<name>`.

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

      iex> Cyfr.AgentRef.type()
      "agent"

  """
  @spec type() :: String.t()
  def type, do: @type_name

  @doc """
  The name-level ref of the agent `name`.

  ## Examples

      iex> Cyfr.AgentRef.ref("web")
      "agent:local.web"

  """
  @spec ref(String.t()) :: String.t()
  def ref(name) when is_binary(name), do: Cyfr.ComponentRef.build(@type_name, @publisher, name)

  @doc """
  The soul's reserved name: the one assistant an estate has, the file at
  the root of its tree and never a role.

  ## Examples

      iex> Cyfr.AgentRef.soul_name()
      "aqua"

  """
  @spec soul_name() :: String.t()
  def soul_name, do: @soul

  @doc """
  The soul's name-level ref.

  ## Examples

      iex> Cyfr.AgentRef.soul_ref()
      "agent:local.aqua"

  """
  @spec soul_ref() :: String.t()
  def soul_ref, do: ref(@soul)

  @doc """
  Whether `name` is the soul's — reserved, never a role.

  ## Examples

      iex> Cyfr.AgentRef.soul?("aqua")
      true

      iex> Cyfr.AgentRef.soul?("web")
      false

  """
  @spec soul?(term()) :: boolean()
  def soul?(name), do: name == @soul

  @doc """
  Whether `ref` names an agent source.

  ## Examples

      iex> Cyfr.AgentRef.agent_ref?("agent:local.web")
      true

      iex> Cyfr.AgentRef.agent_ref?("catalyst:local.files")
      false

  """
  @spec agent_ref?(term()) :: boolean()
  def agent_ref?(ref) when is_binary(ref) do
    match?({:ok, %Cyfr.ComponentRef{type: @type_name}}, Cyfr.ComponentRef.parse(ref))
  end

  def agent_ref?(_), do: false
end
