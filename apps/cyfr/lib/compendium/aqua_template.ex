# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaTemplate do
  @moduledoc """
  The shipped AQUA agent definitions, and how an athanor gets its own copy.

  `agent.json` plus the prompt files it names are the template — seed media
  under the reserved `seed/aqua` root (`Arca.Storage.seed_roots/0`), read in
  place from `:aqua_template_path`: the repo's `aqua/` on a checkout, the
  operator-editable `/app/aqua` mount in Docker. Every athanor owns a copy
  under its tenant storage (`data/athanors/{athanor_id}/aqua/`),
  written when the athanor is provisioned; the Agents page and the `aqua`
  tool then edit that copy, so a group's members shape their own agent
  without touching anyone else's.

  `ensure/1` is the self-healing entry the `aqua` tool uses: an athanor
  whose copy is missing gets the template on first read. Template reads run
  under a server-internal context — reading install media is the server's
  own act, whoever triggered it — while the copy is written with the
  caller's context, into the caller's athanor.
  """

  require Logger

  alias Sanctum.Context

  @manifest "agent.json"
  @seed_prefix ["seed", "aqua"]

  # The pristine stamp: the digest of the shipped file set at the moment it
  # was copied in. A dotfile, so `files/0`'s manifest/.md filter — and with
  # it the tool surface — never lists it.
  @stamp ".seeded_digest"

  @doc "The template's seed segments: `[\"seed\", \"aqua\"]`."
  @spec seed_prefix() :: [String.t()]
  def seed_prefix, do: @seed_prefix

  @doc "The template's files (`agent.json` first), relative to the seed root."
  @spec files() :: [String.t()]
  def files do
    case Arca.list_typed(Sanctum.system_context(), @seed_prefix) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn {name, kind} ->
          kind == :file and (name == @manifest or String.ends_with?(name, ".md"))
        end)
        |> Enum.map(fn {name, _kind} -> name end)
        |> Enum.sort_by(&(&1 != @manifest))

      {:error, _} ->
        []
    end
  end

  @doc """
  Copy the template into the context's athanor, overwriting whatever is
  there. Returns `{:error, :template_missing}` when the install ships no
  template.
  """
  @spec copy_into(Context.t()) :: :ok | {:error, term()}
  def copy_into(%Context{} = ctx) do
    Context.require_tenant!(ctx)

    case files() do
      [] ->
        {:error, :template_missing}

      names ->
        if @manifest in names do
          copied =
            Enum.reduce_while(names, :ok, fn name, :ok ->
              with {:ok, content} <- Arca.get(Sanctum.system_context(), @seed_prefix ++ [name]),
                   :ok <- Arca.put(ctx, ["aqua", name], content) do
                {:cont, :ok}
              else
                {:error, reason} -> {:halt, {:error, {name, reason}}}
              end
            end)

          # The stamp is what refresh/1 compares against: this copy is
          # pristine as of the template it was taken from.
          with :ok <- copied do
            Arca.put(ctx, ["aqua", @stamp], shipped_digest())
          end
        else
          {:error, :template_missing}
        end
    end
  end

  @doc """
  Give the athanor the template if it has no `agent.json` yet; a copy that
  exists is left alone. Returns `:ok` when a manifest is present afterwards.
  """
  @spec ensure(Context.t()) :: :ok | {:error, term()}
  def ensure(%Context{} = ctx) do
    if Arca.exists?(ctx, ["aqua", @manifest]) do
      :ok
    else
      case copy_into(ctx) do
        :ok ->
          Logger.info("[Compendium.AquaTemplate] seeded AQUA definitions for #{ctx.athanor_id}")
          :ok

        {:error, reason} = err ->
          Logger.warning(
            "[Compendium.AquaTemplate] could not seed #{ctx.athanor_id}: #{inspect(reason)}"
          )

          err
      end
    end
  end

  @doc """
  Upgrade the athanor's copy when a newer release shipped a new template —
  but only a copy the members never touched.

  Compares three digests: the shipped template, the stamp written when the
  copy was made, and the copy as it stands. Shipped == stamp means nothing
  new; copy == stamp means the members never edited it, so the new template
  replaces it (and restamps); anything else is the members' own work and is
  left alone — `reset/1` is their deliberate path to the new template. A
  copy from before stamping exists is treated as edited (never clobbered).

  Returns `{:ok, :current | :refreshed | :modified | :unstamped}` or
  `{:error, reason}`.
  """
  @spec refresh(Context.t()) ::
          {:ok, :current | :refreshed | :modified | :unstamped} | {:error, term()}
  def refresh(%Context{} = ctx) do
    Context.require_tenant!(ctx)
    shipped = shipped_digest()

    case Arca.get(ctx, ["aqua", @stamp]) do
      {:ok, ^shipped} ->
        {:ok, :current}

      {:ok, stamped} ->
        if copy_digest(ctx) == stamped do
          with :ok <- copy_into(ctx) do
            Logger.info("[Compendium.AquaTemplate] refreshed AQUA template for #{ctx.athanor_id}")
            {:ok, :refreshed}
          end
        else
          {:ok, :modified}
        end

      {:error, :not_found} ->
        {:ok, :unstamped}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Replace the athanor's copy with the shipped template — the explicit
  "reset to shipped" a modified copy upgrades through.
  """
  @spec reset(Context.t()) :: :ok | {:error, term()}
  def reset(%Context{} = ctx), do: copy_into(ctx)

  # The digest of the shipped file set — what a pristine copy hashes to.
  defp shipped_digest do
    digest_files(fn name -> Arca.get(Sanctum.system_context(), @seed_prefix ++ [name]) end, files())
  end

  # The digest of the athanor's copy, over the same kind of file set the
  # template ships (manifest + prompts) — an added, removed or edited file
  # all change it.
  defp copy_digest(ctx) do
    names =
      case Arca.list_typed(ctx, ["aqua"]) do
        {:ok, entries} ->
          for {name, :file} <- entries,
              name == @manifest or String.ends_with?(name, ".md"),
              do: name

        {:error, _} ->
          []
      end

    digest_files(fn name -> Arca.get(ctx, ["aqua", name]) end, names)
  end

  defp digest_files(read, names) do
    names
    |> Enum.sort()
    |> Enum.map(fn name ->
      case read.(name) do
        {:ok, content} -> [name, 0, content, 0]
        {:error, _} -> [name, 0]
      end
    end)
    |> IO.iodata_to_binary()
    |> Cyfr.Digest.sha256()
  end
end
