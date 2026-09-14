# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.FileTool do
  @moduledoc """
  The `file` tool: the athanor's files on the wire, exactly as the Files
  page shows them.

  The domain is `Cyfr.Files`; this module is its door. Paths are the
  console's — `data/…`, `components/…`, `aqua/…`, `notes/…`,
  `threads/…` — and what each folder allows is its tier, decided
  in the domain. Reads take `storage_read`, writes and deletes
  `storage_write`; a key with the permission may use them, so a
  script can fill `data/` unattended. The actions are external-plane
  only: a chain reaches files through its own consented hands.
  """

  @behaviour Cyfr.Ops.Provider

  alias Cyfr.Files
  alias Sanctum.Context

  @impl true
  def service, do: "files"

  @impl true
  def tools, do: [definition()]

  @doc false
  def definition do
    %{
      name: "file",
      title: "Files",
      description:
        "The athanor's files, as the Files page shows them. data/ is yours to fill; " <>
          "components/ and aqua/ hold shaped units you may edit in place; notes/ and " <>
          "threads/ are read here and managed on their own pages. Paths are " <>
          "folder-relative, like data/reports/q3.csv.",
      annotations: %{
        readOnlyHint: false,
        destructiveHint: true,
        actions: %{
          "list" => %{kind: :read, planes: [:external], permission: :storage_read},
          "read" => %{kind: :read, planes: [:external], permission: :storage_read},
          "write" => %{kind: :write, planes: [:external], permission: :storage_write},
          "delete" => %{kind: :destructive, planes: [:external], permission: :storage_write}
        }
      },
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ["list", "read", "write", "delete"],
            "description" =>
              "list: the entries under a folder (an empty path lists the folders); " <>
                "read: one file's content (utf8 text, or base64 for bytes); " <>
                "write: put content at a path; delete: remove a file, or a folder whole."
          },
          "path" => %{
            "type" => "string",
            "description" => "A folder-relative path, like data/reports/q3.csv"
          },
          "content" => %{
            "type" => "string",
            "description" => "write: what to put there — text, or base64 with encoding=base64"
          },
          "encoding" => %{
            "type" => "string",
            "enum" => ["utf8", "base64"],
            "description" => "write: how content is encoded (default utf8)"
          }
        },
        "required" => ["action"]
      }
    }
  end

  @impl true
  def handle("file", %Context{} = ctx, args), do: dispatch(ctx, args)
  def handle(tool, _ctx, _args), do: {:error, {:not_found, "tool", tool}}

  defp dispatch(ctx, %{"action" => "list"} = args), do: Files.list(ctx, Map.get(args, "path", ""))

  defp dispatch(ctx, %{"action" => "read", "path" => path}) when is_binary(path),
    do: Files.read(ctx, path)

  defp dispatch(ctx, %{"action" => "write", "path" => path, "content" => content} = args)
       when is_binary(path) and is_binary(content),
       do: Files.write(ctx, path, content, Map.get(args, "encoding", "utf8"))

  defp dispatch(ctx, %{"action" => "delete", "path" => path}) when is_binary(path),
    do: Files.delete(ctx, path)

  defp dispatch(_ctx, %{"action" => action}) when action in ~w(read delete),
    do: {:error, {:invalid_argument, "Missing required argument: path"}}

  defp dispatch(_ctx, %{"action" => "write"}),
    do: {:error, {:invalid_argument, "write needs path and content"}}

  defp dispatch(_ctx, %{"action" => action}), do: {:error, {:unknown_action, "file.#{action}"}}
  defp dispatch(_ctx, _args), do: {:error, :action_missing}
end
