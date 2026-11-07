defmodule StreamdeckEmulator.Remote do
  @moduledoc """
  Lets phones on the local network use the emulator's deck (`/remote`).

  Off by default: the UI and API listen on loopback only. `enable/0` starts a
  second HTTP listener on every interface, serving the same endpoint, and makes
  a fresh random pairing token. The pairing URL (shown as a QR code) carries
  the token; a phone that opens it gets it in its session cookie, and from then
  on may only see the deck and press keys (see `StreamdeckEmulatorWeb.Access`).
  `disable/0` stops the listener and revokes the token, which also disconnects
  paired phones.

  Changes are broadcast on the `"remote"` PubSub topic as `{:remote, status}`.
  """

  use GenServer

  require Logger

  @pubsub StreamdeckEmulator.PubSub
  @topic "remote"

  @type status :: %{
          enabled: boolean(),
          port: :inet.port_number() | nil,
          host: String.t() | nil,
          hosts: [String.t()],
          url: String.t() | nil
        }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @spec status() :: status()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Starts listening on the network (if needed) with a new pairing token."
  @spec enable() :: {:ok, status()} | {:error, term()}
  def enable, do: GenServer.call(__MODULE__, :enable)

  @spec disable() :: :ok
  def disable, do: GenServer.call(__MODULE__, :disable)

  @doc "Whether phones may connect (a pairing token exists)."
  @spec enabled?() :: boolean()
  def enabled?, do: :persistent_term.get({__MODULE__, :token}, nil) != nil

  @doc "Whether `token` is the current pairing token (false while disabled)."
  @spec valid_token?(term()) :: boolean()
  def valid_token?(token) when is_binary(token) do
    case :persistent_term.get({__MODULE__, :token}, nil) do
      nil -> false
      current -> byte_size(token) == byte_size(current) and :crypto.hash_equals(token, current)
    end
  end

  def valid_token?(_token), do: false

  @doc """
  This machine's addresses on the local network (private IPv4 ranges), the
  most likely one first: wired or Wi-Fi interfaces before virtual ones.
  """
  @spec lan_addresses() :: [String.t()]
  def lan_addresses do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        for {name, opts} <- interfaces,
            {:addr, {a, b, _, _} = ip} <- opts,
            private?(a, b),
            :up in Keyword.get(opts, :flags, []) do
          {to_string(name), ip |> :inet.ntoa() |> to_string()}
        end
        |> Enum.sort_by(fn {name, _ip} -> interface_rank(name) end)
        |> Enum.map(fn {_name, ip} -> ip end)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    :persistent_term.put({__MODULE__, :token}, nil)
    {:ok, %{port_option: Keyword.get(opts, :port, 0), listener: nil, port: nil, token: nil}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, status(state), state}

  def handle_call(:enable, _from, state) do
    with {:ok, state} <- ensure_listener(state) do
      token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      :persistent_term.put({__MODULE__, :token}, token)
      state = %{state | token: token}
      broadcast(state)
      {:reply, {:ok, status(state)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:disable, _from, state) do
    if state.listener, do: Supervisor.stop(state.listener)
    :persistent_term.put({__MODULE__, :token}, nil)
    state = %{state | listener: nil, port: nil, token: nil}
    broadcast(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{listener: pid} = state) do
    Logger.warning("remote listener stopped: #{inspect(reason)}")
    :persistent_term.put({__MODULE__, :token}, nil)
    state = %{state | listener: nil, port: nil, token: nil}
    broadcast(state)
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp ensure_listener(%{listener: pid} = state) when is_pid(pid), do: {:ok, state}

  defp ensure_listener(state) do
    # The same endpoint as the loopback listener, reachable from the network.
    case Bandit.start_link(
           plug: StreamdeckEmulatorWeb.Endpoint,
           ip: {0, 0, 0, 0},
           port: state.port_option,
           startup_log: false
         ) do
      {:ok, pid} ->
        {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
        {:ok, %{state | listener: pid, port: port}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp status(%{token: nil}), do: %{enabled: false, port: nil, host: nil, hosts: [], url: nil}

  defp status(state) do
    hosts = lan_addresses()
    host = List.first(hosts)

    %{
      enabled: true,
      port: state.port,
      host: host,
      hosts: hosts,
      url: host && "http://#{host}:#{state.port}/remote?pair=#{state.token}"
    }
  end

  defp broadcast(state), do: Phoenix.PubSub.broadcast(@pubsub, @topic, {:remote, status(state)})

  defp private?(10, _), do: true
  defp private?(172, b) when b in 16..31, do: true
  defp private?(192, 168), do: true
  defp private?(_, _), do: false

  # en0/eth0/wlan0 (and Windows' "Ethernet"/"Wi-Fi") before bridges, VPNs and
  # container networks.
  defp interface_rank(name) do
    cond do
      String.match?(name, ~r/^(en|eth|wlan|wl|Ethernet|Wi-Fi)/i) -> 0
      String.match?(name, ~r/^(bridge|docker|veth|vmnet|vbox|utun|tun|tap|br-)/i) -> 2
      true -> 1
    end
  end
end
