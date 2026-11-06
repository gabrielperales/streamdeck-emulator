defmodule StreamdeckEmulator.Deck.Key do
  @moduledoc """
  One key on the emulated device: the action placed on it and what the plugin has
  drawn on it. Titles and images are kept per state, as the Stream Deck app does.
  """

  defstruct [
    :coords,
    :action,
    :context,
    settings: %{},
    state: 0,
    states: 1,
    titles: %{},
    images: %{},
    feedback: nil
  ]

  @type coords :: {non_neg_integer(), non_neg_integer()}
  @type t :: %__MODULE__{
          coords: coords(),
          action: String.t(),
          context: String.t(),
          settings: map(),
          state: non_neg_integer(),
          states: pos_integer(),
          titles: %{non_neg_integer() => String.t()},
          images: %{non_neg_integer() => String.t()},
          feedback: nil | {:ok | :alert, reference()}
        }

  @doc "The title the plugin set for the current state, if any."
  def title(%__MODULE__{titles: titles, state: state}), do: Map.get(titles, state)

  @doc "The image (a data URL) the plugin set for the current state, if any."
  def image(%__MODULE__{images: images, state: state}), do: Map.get(images, state)

  @doc """
  Stores `value` under `field` (`:titles` or `:images`) for one state, or for
  every state when `state` is nil. An empty or nil value clears it, which makes
  the key fall back to its manifest default.
  """
  def put_for_state(%__MODULE__{} = key, field, state, value) when field in [:titles, :images] do
    states = if is_integer(state), do: [state], else: Enum.to_list(0..(key.states - 1))

    Map.update!(key, field, fn current ->
      Enum.reduce(states, current, fn s, acc ->
        if value in [nil, ""], do: Map.delete(acc, s), else: Map.put(acc, s, value)
      end)
    end)
  end

  def put_state(%__MODULE__{} = key, state) when is_integer(state) and state >= 0,
    do: %{key | state: min(state, key.states - 1)}

  def put_state(key, _state), do: key
end
