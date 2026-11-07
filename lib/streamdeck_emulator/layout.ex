defmodule StreamdeckEmulator.Layout do
  @moduledoc """
  Keys to place when a plugin loads, so tests start from a known deck.

  The format is JSON:

      {
        "keys": [
          {"column": 0, "row": 0, "action": "com.example.action", "settings": {"a": 1}}
        ]
      }

  `settings` is optional and defaults to `{}`.
  """

  alias StreamdeckEmulator.Deck

  @type entry :: %{coords: Deck.Key.coords(), action: String.t(), settings: map()}

  @spec read(Path.t()) :: {:ok, [entry()]} | {:error, String.t()}
  def read(path) do
    with {:ok, body} <- File.read(path) |> describe_read_error(path),
         {:ok, json} <- Jason.decode(body) |> describe_json_error(path) do
      parse(json)
    end
  end

  @spec parse(term()) :: {:ok, [entry()]} | {:error, String.t()}
  def parse(%{"keys" => keys}) when is_list(keys) do
    keys
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {key, i}, {:ok, acc} ->
      case parse_key(key) do
        {:ok, entry} ->
          {:cont, {:ok, [entry | acc]}}

        :error ->
          {:halt,
           {:error, "keys[#{i}] needs integer column and row, an action and object settings"}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  def parse(_), do: {:error, ~s(a layout is an object with a "keys" list)}

  @doc "Places every key of the layout on the running Deck."
  @spec apply([entry()]) :: :ok | {:error, String.t()}
  def apply(entries) do
    Enum.reduce_while(entries, :ok, fn %{coords: coords, action: action, settings: settings},
                                       :ok ->
      case Deck.assign_action(coords, action, settings) do
        {:ok, _context} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, "cannot place #{action} on #{inspect(coords)}: #{reason}"}}
      end
    end)
  end

  defp parse_key(%{"column" => column, "row" => row, "action" => action} = key)
       when is_integer(column) and is_integer(row) and is_binary(action) do
    case Map.get(key, "settings", %{}) do
      settings when is_map(settings) ->
        {:ok, %{coords: {column, row}, action: action, settings: settings}}

      _ ->
        :error
    end
  end

  defp parse_key(_), do: :error

  defp describe_read_error({:ok, _} = ok, _path), do: ok

  defp describe_read_error({:error, reason}, path),
    do: {:error, "cannot read #{path}: #{:file.format_error(reason)}"}

  defp describe_json_error({:ok, _} = ok, _path), do: ok

  defp describe_json_error({:error, error}, path),
    do: {:error, "#{path} is not valid JSON: #{Exception.message(error)}"}
end
