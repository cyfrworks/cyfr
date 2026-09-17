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
    alias Cyfr.Ops.{Arg, Operation}

    path =
      Arg.new("path", :string, description: "A folder-relative path, like data/reports/q3.csv")

    Operation.tool(
      [
        Operation.new(
          "file",
          "list",
          "List a folder; an omitted or empty path lists the root folders",
          [path],
          kind: :read,
          planes: [:external],
          permission: :storage_read
        ),
        Operation.new("file", "read", "Read a file as text or base64 bytes", [Arg.required(path)],
          kind: :read,
          planes: [:external],
          permission: :storage_read
        ),
        Operation.new(
          "file",
          "write",
          "Write file content",
          [
            Arg.required(path),
            Arg.new("content", :string,
              required: true,
              description: "Text or base64-encoded content"
            ),
            Arg.new("encoding", :string,
              enum: ["utf8", "base64"],
              description: "Content encoding; defaults to utf8"
            )
          ],
          kind: :write,
          planes: [:external],
          permission: :storage_write
        ),
        Operation.new("file", "delete", "Delete a file or folder", [Arg.required(path)],
          kind: :destructive,
          planes: [:external],
          permission: :storage_write
        )
      ],
      title: "Files",
      description:
        "The athanor's files, as the Files page shows them. data/ is yours to fill; " <>
          "components/ and aqua/ hold shaped units you may edit in place; notes/ and " <>
          "threads/ are read here and managed on their own pages. Paths are " <>
          "folder-relative, like data/reports/q3.csv."
    )
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
