# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# arca:bypass-ok=D — entire module: `:erl_tar` writes to a RAM file and the
# output stream is read from the binaries handed to it; no path on disk is
# opened.
defmodule Locus.Archive do
  @moduledoc """
  The tar streams a build's sources enter it in and its outputs leave it
  in. A source archive is built whole in memory (`pack/1`): it is bounded
  by the request that carries it. An output archive is read as it arrives
  (`reader/1`, `read/2`, `ended?/1`), and nothing of it is kept but the
  part of a header not yet whole.

  An output archive is written by the build and is untrusted: only its
  regular files are read, each name must be a safe relative path
  (`Prima.PathSafety`) of valid UTF-8, no more of them than the reader's
  bound, every header must carry its own checksum, and each file's size is
  known from its header before any of its bytes are handed on. The archive
  is ustar (names of at most 255 bytes, no extended headers), as the build
  writes it; another entry than a regular file or a directory is skipped,
  and named so.
  """

  @block 512

  @doc "A tar archive of `files` (`%{relative_path => content}`), in path order."
  @spec pack(%{String.t() => binary()}) :: {:ok, binary()} | {:error, term()}
  def pack(files) when is_map(files) do
    {:ok, fd} = :file.open(<<>>, [:ram, :read, :write, :binary])

    try do
      with {:ok, tar} <- :erl_tar.init(fd, :write, &ram_access/2),
           :ok <- add_all(tar, files),
           :ok <- :erl_tar.close(tar),
           {:ok, size} <- :file.position(fd, :eof),
           {:ok, bytes} <- :file.pread(fd, 0, size) do
        {:ok, bytes}
      end
    after
      :file.close(fd)
    end
  end

  defp add_all(tar, files) do
    files
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn {path, content}, :ok ->
      case :erl_tar.add(tar, content, String.to_charlist(path), []) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:pack_failed, path, reason}}}
      end
    end)
  end

  defp ram_access(:write, {fd, data}), do: :file.write(fd, data)
  defp ram_access(:position, {fd, position}), do: :file.position(fd, position)
  defp ram_access(:close, _fd), do: :ok

  # ————— an output archive, as it arrives —————

  @typedoc """
  What reading a piece of an output archive found, in order: a regular
  file begun (its name and size), its bytes in pieces, its end, or an entry
  that is not read.
  """
  @type event ::
          {:file, String.t(), non_neg_integer()}
          | {:data, binary()}
          | :file_end
          | {:skipped, String.t()}

  @typedoc "Why an output archive is refused."
  @type refusal ::
          {:too_many_files, pos_integer()} | {:unsafe_path, String.t()} | {:unreadable, term()}

  @typedoc "An output archive being read: the part of a header not yet whole, and where it is."
  @opaque reader :: %{
            max_files: pos_integer(),
            files: non_neg_integer(),
            header: binary(),
            at:
              :header
              | {:data, non_neg_integer(), non_neg_integer(), boolean()}
              | {:pad, non_neg_integer()}
              | :end,
            seen?: boolean()
          }

  @doc "A reader of an output archive of at most `max_files` regular files."
  @spec reader(pos_integer()) :: reader()
  def reader(max_files) when is_integer(max_files) and max_files > 0,
    do: %{max_files: max_files, files: 0, header: "", at: :header, seen?: false}

  @doc """
  The events the next `bytes` of the archive make, and the reader after
  them. A file's data events are slices of `bytes`.
  """
  @spec read(reader(), binary()) :: {:ok, [event()], reader()} | {:error, refusal()}
  def read(reader, bytes) when is_binary(bytes) do
    with {:ok, events, reader} <- step(%{reader | seen?: reader.seen? or bytes != ""}, bytes, []) do
      {:ok, Enum.reverse(events), reader}
    end
  end

  @doc """
  Whether the archive read so far is whole: it reached its end blocks, or
  no byte of it came at all, which is an archive of no file.
  """
  @spec ended?(reader()) :: boolean()
  def ended?(%{at: :end}), do: true
  def ended?(%{seen?: false}), do: true
  def ended?(_reader), do: false

  defp step(reader, "", events), do: {:ok, events, reader}

  # What follows the end blocks is the record's padding: nothing is read.
  defp step(%{at: :end} = reader, _bytes, events), do: {:ok, events, reader}

  defp step(%{at: :header} = reader, bytes, events) do
    need = @block - byte_size(reader.header)

    case bytes do
      <<part::binary-size(^need), rest::binary>> ->
        with {:ok, reader, events} <-
               header(%{reader | header: ""}, reader.header <> part, events),
             do: step(reader, rest, events)

      part ->
        {:ok, events, %{reader | header: reader.header <> part}}
    end
  end

  defp step(%{at: {:data, left, pad, regular?}} = reader, bytes, events) do
    take = min(left, byte_size(bytes))
    <<piece::binary-size(^take), rest::binary>> = bytes
    events = if regular? and take > 0, do: [{:data, piece} | events], else: events

    if take == left,
      do:
        step(
          ended(reader, pad, regular?),
          rest,
          if(regular?, do: [:file_end | events], else: events)
        ),
      else: {:ok, events, %{reader | at: {:data, left - take, pad, regular?}}}
  end

  defp step(%{at: {:pad, left}} = reader, bytes, events) do
    skip = min(left, byte_size(bytes))
    <<_padding::binary-size(^skip), rest::binary>> = bytes

    if skip == left,
      do: step(%{reader | at: :header}, rest, events),
      else: {:ok, events, %{reader | at: {:pad, left - skip}}}
  end

  # A block of zeros is the archive's end.
  defp header(reader, <<0::size(@block)-unit(8)>>, events),
    do: {:ok, %{reader | at: :end}, events}

  defp header(reader, block, events) do
    with :ok <- checksum(block),
         {:ok, size} <- octal(binary_part(block, 124, 12)) do
      name = name(block)
      pad = rem(@block - rem(size, @block), @block)

      case :binary.at(block, 156) do
        type when type in [?0, 0] -> regular(reader, name, size, pad, events)
        ?5 -> {:ok, data(reader, size, pad, false), events}
        _other -> {:ok, data(reader, size, pad, false), [{:skipped, name} | events]}
      end
    end
  end

  defp regular(reader, name, size, pad, events) do
    cond do
      reader.files + 1 > reader.max_files ->
        {:error, {:too_many_files, reader.max_files}}

      not safe?(name) ->
        {:error, {:unsafe_path, inspect(name)}}

      size == 0 ->
        {:ok, %{reader | files: reader.files + 1, at: :header},
         [:file_end, {:file, name, 0} | events]}

      true ->
        reader = data(%{reader | files: reader.files + 1}, size, pad, true)
        {:ok, reader, [{:file, name, size} | events]}
    end
  end

  # An entry of no bytes ends at its header; any other once its bytes are
  # read, then its padding is skipped.
  defp data(reader, 0, _pad, true), do: %{reader | at: :header}
  defp data(reader, 0, _pad, false), do: %{reader | at: :header}
  defp data(reader, size, pad, regular?), do: %{reader | at: {:data, size, pad, regular?}}

  defp ended(reader, pad, _regular?), do: %{reader | at: {:pad, pad}}

  defp safe?(name),
    do:
      name != "" and String.valid?(name) and Prima.PathSafety.validate_relative_path(name) == :ok

  # The header's checksum is the sum of its bytes, its own field counted as
  # spaces.
  defp checksum(block) do
    <<before::binary-size(148), field::binary-size(8), rest::binary>> = block
    sum = Enum.sum(:binary.bin_to_list(before <> "        " <> rest))

    case octal(field) do
      {:ok, ^sum} -> :ok
      _ -> {:error, {:unreadable, :checksum}}
    end
  end

  defp octal(field) do
    digits = field |> :binary.split(<<0>>) |> hd() |> String.trim()

    case Integer.parse(digits, 8) do
      {value, ""} when value >= 0 -> {:ok, value}
      _ -> {:error, {:unreadable, :field}}
    end
  end

  # ustar names a file as its prefix, a slash and its name; an archive
  # that is not ustar has no prefix.
  defp name(block) do
    name = cstring(binary_part(block, 0, 100))

    case binary_part(block, 257, 5) do
      "ustar" ->
        case cstring(binary_part(block, 345, 155)) do
          "" -> name
          prefix -> prefix <> "/" <> name
        end

      _ ->
        name
    end
  end

  defp cstring(field), do: field |> :binary.split(<<0>>) |> hd()
end
