# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Files do
  @moduledoc """
  The athanor's files as a person sees them: one tree whose folders are
  the console tier of the storage layout (`Arca.Storage.console_folders/0`),
  spoken in the console's names — `data/`, `components/`, `aqua/`,
  `notes/`, `threads/`. The server's own storage has no name here
  and is never listed; another athanor's tree is unreachable because the
  athanor is the context's, never the path's.

  What a folder allows is its tier:

    * `:open` (`data/`) — list, read, write and delete anything.
    * `:shaped` (`components/`, `aqua/`) — files are read and edited in
      place, but only inside a unit the root's grammar recognises: a
      component version directory of the `local` publisher, the soul, a
      role or a scroll. Units are made and removed by their own verbs
      (scaffold, pull, fork, the AQUA page); a unit the server ships is
      restored, never deleted. A write here keeps the registry and the
      agent index in step with the tree.
    * `:read` (`notes/`, `threads/`) — listed, read and downloaded;
      written only by their own surfaces.

  Every operation answers the typed refusals `Cyfr.Refusal` names,
  so the `file` tool, the Files page and the download route speak one
  vocabulary.
  """

  require Logger

  alias Sanctum.Context

  @max_inline_read 2_000_000
  @max_write 20_000_000
  @max_entries 1_000

  @type tier :: :open | :shaped | :read
  @type entry :: %{name: String.t(), kind: :dir | :file, size: non_neg_integer() | nil}
  @type folder :: %{name: String.t(), tier: tier()}

  @doc "The bytes a `read/2` answers inline; a larger file is downloaded."
  @spec max_inline_read() :: pos_integer()
  def max_inline_read, do: @max_inline_read

  @doc "The bytes one `write/4` accepts."
  @spec max_write() :: pos_integer()
  def max_write, do: @max_write

  @doc "The folders of the tree, in tier order."
  @spec folders() :: [folder()]
  def folders do
    for %{name: name, tier: tier} <- Arca.Storage.console_folders(), do: %{name: name, tier: tier}
  end

  @doc """
  The entries under a folder path — directories first, then files, each
  by name; files carry their size. The empty path lists the folders
  themselves. `truncated` says the listing was cut at its ceiling.
  """
  @spec list(Context.t(), String.t()) ::
          {:ok, %{path: String.t(), tier: tier() | nil, entries: [entry()], truncated: boolean()}}
          | {:error, term()}
  def list(%Context{} = ctx, path) when is_binary(path) do
    case split(path) do
      [] ->
        entries = for %{name: name} <- folders(), do: %{name: name, kind: :dir, size: nil}
        {:ok, %{path: "", tier: nil, entries: entries, truncated: false}}

      segments ->
        with {:ok, physical, tier} <- resolve(segments),
             {:ok, listed} <- list_typed(ctx, physical, path) do
          {shown, truncated} = Enum.split(listed, @max_entries)

          entries =
            shown
            |> Enum.map(fn {name, kind} ->
              %{name: name, kind: kind, size: size(ctx, physical, name, kind)}
            end)
            |> Enum.sort_by(&{&1.kind != :dir, &1.name})

          {:ok, %{path: join(segments), tier: tier, entries: entries, truncated: truncated != []}}
        end
    end
  end

  @doc """
  One file's bytes: as `utf8` text when they are, else `base64`. A file
  past `max_inline_read/0` is refused in words — the download route
  serves it whole.
  """
  @spec read(Context.t(), String.t()) ::
          {:ok,
           %{path: String.t(), size: non_neg_integer(), content: String.t(), encoding: String.t()}}
          | {:error, term()}
  def read(%Context{} = ctx, path) when is_binary(path) do
    with {:ok, segments, physical, _tier} <- resolve_file(path),
         {:ok, bytes} <- get(ctx, physical, path) do
      cond do
        byte_size(bytes) > @max_inline_read ->
          {:error,
           {:invalid_argument,
            "'#{join(segments)}' is #{byte_size(bytes)} bytes — larger than a read answers " <>
              "inline (#{@max_inline_read}); download it instead"}}

        text?(bytes) ->
          {:ok, %{path: join(segments), size: byte_size(bytes), content: bytes, encoding: "utf8"}}

        true ->
          {:ok,
           %{
             path: join(segments),
             size: byte_size(bytes),
             content: Base.encode64(bytes),
             encoding: "base64"
           }}
      end
    end
  end

  @doc """
  The physical segments the download route streams for a console path,
  with the folder's tier — a file in any shown folder.
  """
  @spec locate(String.t()) :: {:ok, Arca.Storage.path(), tier()} | {:error, term()}
  def locate(path) when is_binary(path) do
    with {:ok, _segments, physical, tier} <- resolve_file(path), do: {:ok, physical, tier}
  end

  @doc """
  Put `content` at `path` — `utf8` text, or bytes as `base64`. The tier
  decides whether the write may land, the storage cap whether it fits,
  and a write inside a shaped unit keeps the unit's row or index in step.
  A component's manifest must decode and validate as one.
  """
  @spec write(Context.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{written: String.t(), size: non_neg_integer()}} | {:error, term()}
  def write(%Context{} = ctx, path, content, encoding \\ "utf8")
      when is_binary(path) and is_binary(content) do
    with {:ok, bytes} <- decode(content, encoding),
         :ok <- check_write_size(bytes),
         {:ok, segments, physical, tier} <- resolve_file(path),
         :ok <- writable(tier, physical, segments),
         :ok <- valid_content(physical, bytes),
         :ok <- put(ctx, physical, path, bytes) do
      refresh_unit(ctx, physical)
      {:ok, %{written: join(segments), size: byte_size(bytes)}}
    end
  end

  @doc """
  Rewrite a text file inside a unit as one serialized read-modify-write.
  `fun` receives the file's current text and answers `{:ok, text}` to
  write it, or `{:error, reason}` to leave the file as it is and answer
  that. The write is made only while the file still holds the bytes `fun`
  was given, so a writer that landed in between — another edit, a
  publish, a pull, a reset — is read again rather than overwritten, and
  neither edit is lost. A file still moving after the last attempt is a
  conflict the caller may retry. The tier, size and content checks and
  the unit refresh are `write/4`'s.
  """
  @spec update(Context.t(), String.t(), (String.t() -> {:ok, String.t()} | {:error, term()})) ::
          {:ok, %{written: String.t()}} | {:error, term()}
  def update(%Context{} = ctx, path, fun) when is_binary(path) and is_function(fun, 1) do
    with {:ok, segments, physical, tier} <- resolve_file(path),
         :ok <- writable(tier, physical, segments),
         :ok <- serialized_update(ctx, physical, path, fun) do
      refresh_unit(ctx, physical)
      {:ok, %{written: join(segments)}}
    end
  end

  @doc """
  Remove a file, or a folder with everything in it. A unit the server
  ships refuses; a shaped folder above its units refuses too — units go
  one at a time, by their own verbs.
  """
  @spec delete(Context.t(), String.t()) :: {:ok, %{deleted: String.t()}} | {:error, term()}
  def delete(%Context{} = ctx, path) when is_binary(path) do
    with {:ok, segments, physical, tier} <- resolve_file(path),
         :ok <- deletable(tier, physical, segments),
         :ok <- remove(ctx, physical, path) do
      refresh_unit(ctx, physical)
      {:ok, %{deleted: join(segments)}}
    end
  end

  # ---- paths -----------------------------------------------------------------

  defp split(path), do: path |> String.split("/") |> Enum.reject(&(&1 == ""))

  defp join(segments), do: Enum.join(segments, "/")

  # A console path to the physical segments and the folder's tier: the
  # first segment must name a shown folder, and every segment must be a
  # safe name.
  defp resolve([folder | rest] = segments) do
    with :ok <- safe(segments) do
      case Map.fetch(Arca.Storage.console_scopes(), folder) do
        {:ok, root} -> {:ok, [root | rest], Arca.Storage.tier(root)}
        :error -> {:error, {:not_found, "Folder", folder}}
      end
    end
  end

  defp resolve_file(path) do
    case split(path) do
      [] ->
        {:error, {:invalid_argument, "A path inside a folder is required, like data/notes.txt"}}

      [folder] ->
        with {:ok, _physical, _tier} <- resolve([folder]) do
          {:error, {:invalid_argument, "'#{folder}/' is a folder — name a file inside it"}}
        end

      segments ->
        with {:ok, physical, tier} <- resolve(segments), do: {:ok, segments, physical, tier}
    end
  end

  defp safe(segments) do
    case Cyfr.PathSafety.validate_segments(segments) do
      :ok -> :ok
      {:error, {_refusal, message}} -> {:error, {:invalid_argument, message}}
    end
  end

  # ---- tiers -----------------------------------------------------------------

  defp writable(:open, _physical, _segments), do: :ok

  defp writable(:shaped, physical, segments) do
    case Arca.Storage.locate(physical) do
      :above_unit ->
        {:error, {:invalid_argument, above_unit_message(physical, segments)}}

      {:file, unit} when unit != physical ->
        {:error, {:invalid_argument, inside_file_message(segments)}}

      {:dir, unit, _sentinel} ->
        local_unit(unit, segments)

      {:file, _unit} ->
        :ok
    end
  end

  defp writable(:read, _physical, segments),
    do: {:error, {:invalid_argument, read_only_message(segments)}}

  defp deletable(:open, _physical, _segments), do: :ok

  # Above the units the storage layer decides: an empty stray folder goes,
  # one holding units refuses.
  defp deletable(:shaped, physical, segments) do
    case Arca.Storage.locate(physical) do
      {:dir, unit, _sentinel} -> local_unit(unit, segments)
      _above_inside_or_file -> :ok
    end
  end

  defp deletable(:read, _physical, segments),
    do: {:error, {:invalid_argument, read_only_message(segments)}}

  # A pulled component is fork-to-modify, never rewritten in place — the
  # same rule the guest boundary applies.
  defp local_unit(["components", _plural, publisher | _], segments) do
    case Compendium.NamespacePolicy.require_local_guest_write(publisher) do
      :ok -> :ok
      {:error, message} -> {:error, {:invalid_argument, "'#{join(segments)}': #{message}"}}
    end
  end

  defp local_unit(_aqua_unit, _segments), do: :ok

  defp above_unit_message(["components" | _], segments) do
    "'#{join(segments)}' is outside any component: component files live inside a version " <>
      "directory (components/{type}s/local/{name}/{version}/…) — scaffold or pull one from " <>
      "the Components page"
  end

  defp above_unit_message(["aqua" | _], segments) do
    "'#{join(segments)}' is outside any AQUA unit: the soul is aqua/aqua.md, a role is " <>
      "aqua/roles/{name}.md, a scroll is aqua/skills/{name}/SKILL.md — create one from the AQUA page"
  end

  defp inside_file_message(segments),
    do: "'#{join(segments)}' is below a file — a role is one file, not a folder"

  defp read_only_message([folder | _]),
    do: "'#{folder}/' is read here and written on its own page"

  # ---- storage ---------------------------------------------------------------

  defp list_typed(ctx, physical, path) do
    case Arca.list_typed(Sanctum.Context.actor(ctx), physical) do
      {:ok, entries} -> {:ok, entries}
      {:error, :enotdir} -> {:error, {:invalid_argument, "'#{path}' is a file — read it"}}
      {:error, :not_found} -> {:ok, []}
      {:error, reason} -> storage_error("list", path, reason)
    end
  end

  defp size(_ctx, _physical, _name, :dir), do: nil

  defp size(ctx, physical, name, :file) do
    case Arca.usage(Sanctum.Context.actor(ctx), physical ++ [name]) do
      {:ok, %{bytes: bytes}} -> bytes
      {:error, _} -> nil
    end
  end

  defp get(ctx, physical, path) do
    case Arca.get(Sanctum.Context.actor(ctx), physical) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :not_found} -> {:error, {:not_found, "File", path}}
      {:error, reason} -> storage_error("read", path, reason)
    end
  end

  defp put(ctx, physical, path, bytes) do
    case Arca.put(Sanctum.Context.actor(ctx), physical, bytes) do
      :ok -> :ok
      {:error, reason} -> write_error(path, reason)
    end
  end

  defp serialized_update(ctx, physical, path, fun) do
    rewrite = fn current ->
      with :ok <- text(current, path),
           {:ok, next} <- fun.(current),
           :ok <- check_write_size(next),
           :ok <- valid_content(physical, next) do
        {:ok, next}
      end
    end

    case Arca.Overlay.update(Sanctum.Context.actor(ctx), physical, rewrite) do
      :ok ->
        :ok

      {:error, :not_found} ->
        {:error, {:not_found, "File", path}}

      {:error, :not_overlaid} ->
        {:error, {:invalid_argument, "'#{path}' is not inside a unit"}}

      # Nothing was written and asking again is safe.
      {:error, :conflict} ->
        {:error, {:conflict, "'#{path}' is being written — try the edit again"}}

      {:error, {:invalid_argument, _} = refusal} ->
        {:error, refusal}

      {:error, reason} ->
        write_error(path, reason)
    end
  end

  defp write_error(path, reason) do
    case reason do
      :invalid_path ->
        {:error, {:invalid_argument, "'#{path}' is not a place a file can go"}}

      :reserved_name ->
        {:error, {:invalid_argument, "'#{path}' uses a name the server reserves"}}

      {:limit_reached, :athanor_storage_bytes, cap} ->
        {:error, {:invalid_argument, cap_message(cap)}}

      :storage_unverifiable ->
        {:error, {:unavailable, "Storage usage"}}

      reason ->
        storage_error("write", path, reason)
    end
  end

  # A folder goes whole; a file goes alone; a missing path is not found.
  defp remove(ctx, physical, path) do
    case Arca.list_typed(Sanctum.Context.actor(ctx), physical) do
      {:ok, [_ | _]} ->
        delete_tree(ctx, physical, path)

      {:ok, []} ->
        if Arca.exists?(Sanctum.Context.actor(ctx), physical),
          do: delete_tree(ctx, physical, path),
          else: {:error, {:not_found, "File", path}}

      {:error, :enotdir} ->
        delete_file(ctx, physical, path)

      {:error, reason} ->
        storage_error("delete", path, reason)
    end
  end

  defp delete_file(ctx, physical, path) do
    case Arca.delete(Sanctum.Context.actor(ctx), physical) do
      :ok -> :ok
      {:error, :not_found} -> {:error, {:not_found, "File", path}}
      {:error, :bundled} -> {:error, {:invalid_argument, bundled_message(path)}}
      {:error, reason} -> storage_error("delete", path, reason)
    end
  end

  defp delete_tree(ctx, physical, path) do
    case Arca.delete_tree(Sanctum.Context.actor(ctx), physical) do
      :ok ->
        :ok

      {:error, :bundled} ->
        {:error, {:invalid_argument, bundled_message(path)}}

      {:error, :above_unit} ->
        {:error, {:invalid_argument, "'#{path}' holds units — remove them one at a time"}}

      {:error, reason} ->
        storage_error("delete", path, reason)
    end
  end

  defp bundled_message(path),
    do:
      "'#{path}' ships with the server and cannot be deleted — reset it from the Components or AQUA page"

  defp cap_message(cap),
    do: "The athanor's storage is at its limit (#{cap} bytes) — remove something first"

  defp storage_error(verb, path, reason) do
    Logger.error("[Cyfr.Files] #{verb} #{path} failed: #{inspect(reason)}")
    {:error, {:unavailable, "Storage"}}
  end

  # A change inside a shaped unit is reflected where the unit is
  # indexed: a component's row is re-registered from its tree, the AQUA
  # index is rewritten. Best effort — a unit mid-edit may not register
  # yet, and the write itself has already landed.
  defp refresh_unit(ctx, physical) do
    case Arca.Storage.locate(physical) do
      {:dir, ["components" | _] = unit, _sentinel} ->
        case Compendium.Registry.register_from_arca(ctx, unit) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.info(
              "[Cyfr.Files] #{Enum.join(unit, "/")} not re-registered: #{inspect(reason)}"
            )
        end

      {kind, ["aqua" | _] = _unit} when kind == :file ->
        sync_agents(ctx)

      {:dir, ["aqua" | _], _sentinel} ->
        sync_agents(ctx)

      _not_a_unit ->
        :ok
    end
  end

  defp sync_agents(ctx) do
    case Compendium.AgentIndex.sync(ctx) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Cyfr.Files] agent index not synced: #{inspect(reason)}")
    end
  end

  # ---- content ---------------------------------------------------------------

  defp decode(content, "utf8"), do: {:ok, content}
  defp decode(content, nil), do: {:ok, content}

  defp decode(content, "base64") do
    case Base.decode64(content) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {:invalid_argument, "content is not valid base64"}}
    end
  end

  defp decode(_content, other),
    do: {:error, {:invalid_argument, "encoding must be utf8 or base64, got #{inspect(other)}"}}

  defp check_write_size(bytes) when byte_size(bytes) > @max_write,
    do: {:error, {:invalid_argument, "A write is at most #{@max_write} bytes"}}

  defp check_write_size(_bytes), do: :ok

  defp text(bytes, path) do
    if text?(bytes),
      do: :ok,
      else: {:error, {:invalid_argument, "'#{path}' is not text — write it whole instead"}}
  end

  # A component's manifest is what registers it, so what lands there must
  # be one.
  defp valid_content(physical, bytes) do
    case Arca.Storage.locate(physical) do
      {:dir, ["components" | _] = unit, sentinel} ->
        if physical == unit ++ [sentinel], do: valid_manifest(bytes, sentinel), else: :ok

      _not_a_component ->
        :ok
    end
  end

  defp valid_manifest(bytes, name) do
    with {:ok, manifest} <- Cyfr.Manifest.decode_strict(bytes),
         :ok <- Compendium.Manifest.validate(manifest) do
      :ok
    else
      {:error, :malformed_manifest} ->
        {:error, {:invalid_argument, "#{name} is not a JSON object"}}

      {:error, {_block, message}} when is_binary(message) ->
        {:error, {:invalid_argument, "#{name}: #{message}"}}

      {:error, reason} ->
        {:error, {:invalid_argument, "#{name}: #{inspect(reason)}"}}
    end
  end

  defp text?(bytes), do: String.valid?(bytes) and not String.contains?(bytes, <<0>>)
end
