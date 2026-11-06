defmodule StreamdeckEmulator.Package do
  @moduledoc """
  Turns what the user points the emulator at into an unpacked `.sdPlugin` folder.

  Accepts a `.sdPlugin` folder as is, or a `.streamDeckPlugin` package (a zip),
  which is extracted to a fresh temporary directory.
  """

  @spec open(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def open(path) do
    path = Path.expand(path)

    cond do
      File.dir?(path) ->
        {:ok, path}

      File.regular?(path) and Path.extname(path) == ".streamDeckPlugin" ->
        extract(path)

      File.exists?(path) ->
        {:error, "#{path} is neither a .sdPlugin folder nor a .streamDeckPlugin file"}

      true ->
        {:error, "#{path} does not exist"}
    end
  end

  defp extract(path) do
    archive = String.to_charlist(path)

    with {:ok, entries} <- list(archive),
         :ok <- check_entries(entries) do
      dest = Path.join(System.tmp_dir!(), "streamdeck-emulator-" <> random_suffix())
      File.mkdir_p!(dest)

      case :zip.extract(archive, cwd: String.to_charlist(dest)) do
        {:ok, _files} -> find_plugin_dir(dest)
        {:error, reason} -> {:error, "cannot extract #{path}: #{inspect(reason)}"}
      end
    end
  end

  defp list(archive) do
    case :zip.list_dir(archive) do
      {:ok, entries} ->
        {:ok, for({:zip_file, name, _, _, _, _} <- entries, do: List.to_string(name))}

      {:error, reason} ->
        {:error, "not a valid zip archive: #{inspect(reason)}"}
    end
  end

  # Refuse entries that would land outside the extraction directory.
  defp check_entries(names) do
    case Enum.find(names, &unsafe?/1) do
      nil -> :ok
      name -> {:error, "package contains an unsafe path: #{name}"}
    end
  end

  defp unsafe?(name), do: Path.type(name) != :relative or ".." in Path.split(name)

  defp find_plugin_dir(dest) do
    case Path.wildcard(Path.join(dest, "*.sdPlugin")) do
      [dir] ->
        {:ok, dir}

      [] ->
        {:error, "package has no .sdPlugin folder at its top level"}

      dirs ->
        {:error,
         "package has several .sdPlugin folders: #{Enum.map_join(dirs, ", ", &Path.basename/1)}"}
    end
  end

  defp random_suffix, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
