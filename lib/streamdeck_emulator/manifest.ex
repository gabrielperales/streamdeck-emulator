defmodule StreamdeckEmulator.Manifest do
  @moduledoc """
  Reads and validates a plugin's `manifest.json`.

  Validation covers what the Stream Deck app rejects on install, including checks
  that `streamdeck validate` misses (a `Category` without a `CategoryIcon`).
  """

  defstruct [
    :dir,
    :uuid,
    :name,
    :version,
    :code_path,
    :property_inspector_path,
    :icon,
    actions: [],
    raw: %{}
  ]

  @type action :: %{
          uuid: String.t(),
          name: String.t(),
          icon: String.t() | nil,
          tooltip: String.t() | nil,
          states: [map()],
          property_inspector_path: String.t() | nil
        }

  @type t :: %__MODULE__{
          dir: String.t(),
          uuid: String.t(),
          name: String.t(),
          version: String.t() | nil,
          code_path: String.t(),
          property_inspector_path: String.t() | nil,
          icon: String.t() | nil,
          actions: [action()],
          raw: map()
        }

  @doc "Loads and validates `<dir>/manifest.json`. Errors are human-readable strings."
  @spec load(Path.t()) :: {:ok, t()} | {:error, [String.t()]}
  def load(dir) do
    dir = Path.expand(dir)
    path = Path.join(dir, "manifest.json")

    with {:ok, body} <- read(path),
         {:ok, raw} <- decode(body) do
      case validate(raw, dir) do
        [] -> {:ok, build(raw, dir)}
        errors -> {:error, errors}
      end
    end
  end

  @doc "Absolute path of the plugin executable."
  @spec executable(t()) :: String.t()
  def executable(%__MODULE__{dir: dir, code_path: code_path}), do: Path.join(dir, code_path)

  @spec action(t(), String.t()) :: action() | nil
  def action(%__MODULE__{actions: actions}, uuid), do: Enum.find(actions, &(&1.uuid == uuid))

  @doc """
  Resolves a manifest image reference (which has no extension) to a file in the
  plugin folder, preferring `@2x.png`, then `.png`, then `.svg`.
  """
  @spec image_file(t(), String.t() | nil) :: String.t() | nil
  def image_file(_manifest, nil), do: nil

  def image_file(%__MODULE__{dir: dir}, name) do
    base = Path.join(dir, name)

    [base <> "@2x.png", base <> ".png", base <> ".svg", base]
    |> Enum.find(&File.regular?/1)
  end

  defp read(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, ["cannot read #{path}: #{:file.format_error(reason)}"]}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = raw} ->
        {:ok, raw}

      {:ok, _} ->
        {:error, ["manifest.json is not a JSON object"]}

      {:error, error} ->
        {:error, ["manifest.json is not valid JSON: #{Exception.message(error)}"]}
    end
  end

  defp validate(raw, dir) do
    code_path = code_path(raw)

    [
      required_string(raw, "UUID"),
      required_string(raw, "Name"),
      if(is_nil(code_path), do: "CodePath is missing"),
      if(code_path && not File.regular?(Path.join(dir, code_path)),
        do: "CodePath #{code_path} does not exist in the plugin folder"
      ),
      if(raw["Category"] && is_nil(raw["CategoryIcon"]),
        do: "Category is set but CategoryIcon is not (the Stream Deck app rejects this)"
      ),
      validate_actions(raw["Actions"])
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp validate_actions(actions) when is_list(actions) and actions != [] do
    actions
    |> Enum.with_index()
    |> Enum.map(fn {action, i} ->
      if is_map(action) and is_binary(action["UUID"]) and action["UUID"] != "",
        do: nil,
        else: "Actions[#{i}] has no UUID"
    end)
  end

  defp validate_actions(_), do: "Actions must be a non-empty list"

  defp required_string(raw, field) do
    case raw[field] do
      value when is_binary(value) and value != "" -> nil
      _ -> "#{field} is missing"
    end
  end

  # SDK v2 lets a manifest give a per-platform executable.
  defp code_path(raw), do: raw["CodePathMac"] || raw["CodePath"]

  defp build(raw, dir) do
    top_level_pi = raw["PropertyInspectorPath"]

    %__MODULE__{
      dir: dir,
      uuid: raw["UUID"],
      name: raw["Name"],
      version: raw["Version"],
      code_path: code_path(raw),
      property_inspector_path: top_level_pi,
      icon: raw["Icon"],
      actions:
        Enum.map(raw["Actions"], fn action ->
          %{
            uuid: action["UUID"],
            name: action["Name"] || action["UUID"],
            icon: action["Icon"],
            tooltip: action["Tooltip"],
            states: List.wrap(action["States"]),
            property_inspector_path: action["PropertyInspectorPath"] || top_level_pi
          }
        end),
      raw: raw
    }
  end
end
