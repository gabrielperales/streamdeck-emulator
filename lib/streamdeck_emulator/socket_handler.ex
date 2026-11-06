defmodule StreamdeckEmulator.SocketHandler do
  @moduledoc """
  One WebSocket connection from the plugin or a Property Inspector.

  It decodes JSON from text and binary frames alike (the ObjC SDK sends binary),
  registers itself with `StreamdeckEmulator.Deck` on the first message and hands
  every later message to it. The Deck decides what each connection is.
  """

  @behaviour WebSock

  alias StreamdeckEmulator.Deck

  @impl true
  def init(_opts), do: {:ok, %{registered?: false}}

  @impl true
  def handle_in({data, _opts}, state) do
    case Jason.decode(data) do
      {:ok, %{} = msg} ->
        route(msg, state)

      _ ->
        Deck.system_log("ignored a frame that is not a JSON object: #{inspect(data, limit: 200)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_info({:send, msg}, state), do: {:push, {:text, Jason.encode!(msg)}, state}
  def handle_info(:close, state), do: {:stop, :normal, 1000, state}
  def handle_info(_other, state), do: {:ok, state}

  defp route(msg, %{registered?: false} = state) do
    case Deck.register(self(), msg) do
      :ok -> {:ok, %{state | registered?: true}}
      {:error, reason} -> {:stop, :normal, {1008, reason}, state}
    end
  end

  defp route(msg, state) do
    Deck.incoming(self(), msg)
    {:ok, state}
  end
end
