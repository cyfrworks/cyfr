# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.NamespacePolicy do
  @moduledoc """
  The one statement of the `local`-namespace trust policy.

  `local` is the highest-trust namespace: the scanner indexes it, the seed
  bundle shows through the overlay there, and its components run without a
  publisher signature. So the boundary rules are absolute — **remote
  content never enters `local`** (a pull may not name it, a remote-origin
  publish may not mint into it), **only `local` registers from the
  filesystem** (a scan may not mint rows for any other namespace), and
  **a fork's source is never `local`** (forking is how a remote component
  becomes a user-owned local line; a local source has nothing to cross).

  The *predicate* stays with the path vocabulary
  (`Compendium.ComponentPath.local_publisher?/1`); this module owns the
  refusals and their one canonical message each, so the policy is written
  down once instead of restated at every ingress (OCI pull, publish,
  directory registration, fork).
  """

  alias Compendium.ComponentPath

  @doc """
  Refuse remote content aimed at the `local` namespace — the rule every
  remote ingress (OCI pull, `origin: :remote` publish) asserts before any
  bytes move. `publisher_or_namespace` is either vocabulary's spelling of
  the same value.
  """
  @spec refuse_remote_ingress(String.t() | nil) :: :ok | {:error, String.t()}
  def refuse_remote_ingress(publisher_or_namespace) do
    if ComponentPath.local_publisher?(publisher_or_namespace) do
      {:error,
       "Cannot pull local components — the local namespace is registered " <>
         "from the filesystem, never pulled. Use `cyfr register` to index " <>
         "local components."}
    else
      :ok
    end
  end

  @doc """
  Require the `local` namespace for filesystem registration — the
  scanner's rule: rows are minted from the tree only for the namespace
  the tree is trusted to speak for.
  """
  @spec require_local_register(String.t() | nil) :: :ok | {:error, String.t()}
  def require_local_register(publisher) do
    if ComponentPath.local_publisher?(publisher) do
      :ok
    else
      {:error, "only local/ namespace can be registered, got: #{publisher}"}
    end
  end

  @doc """
  Refuse a `local` fork source — `Compendium.Fork`'s first guard, stated
  here so the MCP surface and any direct caller refuse with one voice.
  """
  @spec refuse_local_fork_source(String.t() | nil) :: :ok | {:error, String.t()}
  def refuse_local_fork_source(namespace) do
    if ComponentPath.local_publisher?(namespace) do
      {:error, "Cannot fork a local component. Use 'new' to create a fresh component."}
    else
      :ok
    end
  end
end
