defmodule StreamdeckEmulator.Deck do
  @moduledoc """
  The emulated Stream Deck app. It owns the key layout and routes events between
  the plugin, its Property Inspectors (PIs) and the emulator's UI.

  WebSocket connections call `register/2` with their first message, then pass
  every later message to `incoming/2`. The Deck writes back by sending the
  connection process `{:send, map}`, or `:close` to drop it.

  A PI registers with its PI UUID, and the emulator uses the key's context as
  that UUID, so a PI's messages map straight to its key.

  Changes are broadcast on the `"deck"` PubSub topic as `{:deck, snapshot}`, and
  each log entry as `{:deck_log, entry}`.
  """

  use GenServer

  alias StreamdeckEmulator.Deck.Key
  alias StreamdeckEmulator.Manifest

  @pubsub StreamdeckEmulator.PubSub
  @topic "deck"
  @columns 5
  @rows 3
  @device_id "emulator-device"
  @log_limit 500
  @feedback_ms 1_500

  @key_events ~w(setTitle setImage showOk showAlert setState setSettings getSettings sendToPropertyInspector)

  ## Client

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @doc "The current deck state, without the log."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "Log entries, oldest first."
  def log, do: GenServer.call(__MODULE__, :log)

  def device_id, do: @device_id
  def size, do: {@columns, @rows}

  @doc "Places an action on a key (replacing what was there) and sends `willAppear`."
  def assign_action(coords, action_uuid, settings \\ %{}),
    do: GenServer.call(__MODULE__, {:assign, coords, action_uuid, settings})

  def clear_key(coords), do: GenServer.call(__MODULE__, {:clear, coords})
  def key_down(coords), do: GenServer.call(__MODULE__, {:key, coords, "keyDown"})
  def key_up(coords), do: GenServer.call(__MODULE__, {:key, coords, "keyUp"})

  @doc "Identifies a new connection from its first message."
  def register(pid, message), do: GenServer.call(__MODULE__, {:register, pid, message})

  def incoming(pid, message), do: GenServer.cast(__MODULE__, {:incoming, pid, message})

  def plugin_launched(os_pid), do: GenServer.cast(__MODULE__, {:plugin_launched, os_pid})
  def plugin_output(line), do: GenServer.cast(__MODULE__, {:plugin_output, line})
  def plugin_exited(status), do: GenServer.cast(__MODULE__, {:plugin_exited, status})
  def system_log(text), do: GenServer.cast(__MODULE__, {:system_log, text})

  @doc "The `-info` / `inApplicationInfo` JSON the app hands to plugins and PIs."
  def application_info(%Manifest{} = manifest) do
    %{
      "application" => %{
        "font" => ".AppleSystemUIFont",
        "language" => "en",
        "platform" => "mac",
        "platformVersion" => "15.0.0",
        "version" => "6.4.0"
      },
      "plugin" => %{"uuid" => manifest.uuid, "version" => manifest.version},
      "devicePixelRatio" => 2,
      "colors" => %{
        "buttonPressedBackgroundColor" => "#303030FF",
        "buttonPressedBorderColor" => "#646464FF",
        "buttonPressedTextColor" => "#969696FF",
        "disabledColor" => "#F7821B59",
        "highlightColor" => "#F7821BFF",
        "mouseDownColor" => "#CF6304FF"
      },
      "devices" => [
        %{
          "id" => @device_id,
          "name" => "Stream Deck Emulator",
          "size" => %{"columns" => @columns, "rows" => @rows},
          "type" => 0
        }
      ]
    }
  end

  ## Server

  @impl true
  def init(opts) do
    {:ok,
     %{
       manifest: Keyword.fetch!(opts, :manifest),
       plugin_uuid: Keyword.fetch!(opts, :plugin_uuid),
       keys: %{},
       global_settings: %{},
       plugin: %{status: :starting, os_pid: nil, exits: 0, exit_status: nil},
       plugin_pid: nil,
       conns: %{},
       log: [],
       log_seq: 0
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot(state), state}
  def handle_call(:log, _from, state), do: {:reply, Enum.reverse(state.log), state}

  def handle_call({:assign, coords, action_uuid, settings}, _from, state) do
    with :ok <- validate_coords(coords),
         %{} = action <- Manifest.action(state.manifest, action_uuid) || {:error, :unknown_action} do
      key = %Key{
        coords: coords,
        action: action_uuid,
        context: new_context(),
        settings: settings,
        states: max(length(action.states), 1)
      }

      state =
        state
        |> remove_key(coords)
        |> put_key(key)
        |> send_plugin(key_event(key, "willAppear"))

      {:reply, {:ok, key.context}, changed(state)}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:clear, coords}, _from, state) do
    {:reply, :ok, state |> remove_key(coords) |> changed()}
  end

  def handle_call({:key, coords, event}, _from, state) do
    case Map.fetch(state.keys, coords) do
      {:ok, key} -> {:reply, :ok, send_plugin(state, key_event(key, event))}
      :error -> {:reply, {:error, :empty_key}, state}
    end
  end

  def handle_call(
        {:register, pid, %{"event" => "registerPlugin", "uuid" => uuid} = msg},
        _from,
        state
      )
      when uuid == state.plugin_uuid do
    state =
      case state.plugin_pid do
        nil -> state
        old -> drop_conn(state, old)
      end

    Process.monitor(pid)

    state =
      %{state | plugin_pid: pid, conns: Map.put(state.conns, pid, :plugin)}
      |> put_in([:plugin, :status], :connected)
      |> log(:plugin, :in, nil, msg)
      |> send_plugin(device_did_connect())

    # A (re)started plugin gets willAppear for every key, with its stored settings.
    state =
      state.keys
      |> Map.values()
      |> Enum.sort_by(fn %Key{coords: {c, r}} -> {r, c} end)
      |> Enum.reduce(state, &send_plugin(&2, key_event(&1, "willAppear")))

    {:reply, :ok, changed(state)}
  end

  def handle_call(
        {:register, pid, %{"event" => "registerPropertyInspector", "uuid" => context} = msg},
        _from,
        state
      ) do
    case key_by_context(state, context) do
      nil ->
        {:reply, {:error, "unknown Property Inspector UUID"},
         log(
           state,
           :system,
           nil,
           nil,
           "rejected a Property Inspector for unknown context #{context}"
         )}

      key ->
        # The real app shows one PI at a time per key; a newer one replaces the old.
        state =
          case pi_pid(state, context) do
            nil -> state
            old -> drop_conn(state, old)
          end

        Process.monitor(pid)

        state =
          %{state | conns: Map.put(state.conns, pid, {:pi, context})}
          |> log(:pi, :in, context, msg)
          |> send_plugin(Map.delete(key_event(key, "propertyInspectorDidAppear"), "payload"))

        {:reply, :ok, changed(state)}
    end
  end

  def handle_call({:register, _pid, msg}, _from, state) do
    {:reply, {:error, "expected registerPlugin or registerPropertyInspector"},
     log(
       state,
       :system,
       nil,
       nil,
       "rejected a connection whose first message was #{inspect(msg)}"
     )}
  end

  @impl true
  def handle_cast({:incoming, pid, msg}, state) do
    state =
      case Map.get(state.conns, pid) do
        :plugin -> handle_plugin(msg, log(state, :plugin, :in, msg["context"], msg))
        {:pi, context} -> handle_pi(context, msg, log(state, :pi, :in, context, msg))
        nil -> state
      end

    {:noreply, state}
  end

  def handle_cast({:plugin_launched, os_pid}, state) do
    state =
      state
      |> update_in([:plugin], &%{&1 | status: :starting, os_pid: os_pid})
      |> log(:system, nil, nil, "launched plugin (pid #{os_pid})")

    {:noreply, changed(state)}
  end

  def handle_cast({:plugin_output, line}, state),
    do: {:noreply, log(state, :stdout, nil, nil, line)}

  def handle_cast({:plugin_exited, status}, state) do
    state =
      state
      |> update_in(
        [:plugin],
        &%{&1 | status: :exited, os_pid: nil, exits: &1.exits + 1, exit_status: status}
      )
      |> log(:system, nil, nil, "plugin exited (#{inspect(status)})")

    {:noreply, changed(state)}
  end

  def handle_cast({:system_log, text}, state), do: {:noreply, log(state, :system, nil, nil, text)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state =
      case Map.pop(state.conns, pid) do
        {nil, _} ->
          state

        {:plugin, conns} ->
          state = %{state | conns: conns}

          if state.plugin_pid == pid do
            %{state | plugin_pid: nil}
            |> update_in([:plugin, :status], &if(&1 == :connected, do: :disconnected, else: &1))
            |> log(:system, nil, nil, "plugin disconnected")
          else
            state
          end

        {{:pi, context}, conns} ->
          state = %{state | conns: conns}

          case key_by_context(state, context) do
            nil ->
              state

            key ->
              send_plugin(
                state,
                Map.delete(key_event(key, "propertyInspectorDidDisappear"), "payload")
              )
          end
      end

    {:noreply, changed(state)}
  end

  def handle_info({:clear_feedback, context, ref}, state) do
    state =
      update_key(state, context, fn
        %Key{feedback: {_, ^ref}} = key -> %{key | feedback: nil}
        key -> key
      end)

    {:noreply, changed(state)}
  end

  ## Plugin → app

  defp handle_plugin(%{"event" => event, "context" => context} = msg, state)
       when event in @key_events do
    case key_by_context(state, context) do
      nil -> log(state, :system, context, nil, "#{event} for unknown context #{context}")
      key -> plugin_key_event(event, key, msg["payload"] || %{}, state)
    end
  end

  defp handle_plugin(%{"event" => "setGlobalSettings", "payload" => settings}, state) do
    state = %{state | global_settings: settings}
    Enum.reduce(pi_contexts(state), state, &send_pi(&2, &1, global_settings_event(state)))
  end

  defp handle_plugin(%{"event" => "getGlobalSettings"}, state),
    do: send_plugin(state, global_settings_event(state))

  # logMessage and openUrl are only logged, which the incoming log entry already did.
  defp handle_plugin(_msg, state), do: state

  defp plugin_key_event("setTitle", key, payload, state),
    do:
      update_key(
        state,
        key.context,
        &Key.put_for_state(&1, :titles, payload["state"], payload["title"])
      )

  defp plugin_key_event("setImage", key, payload, state),
    do:
      update_key(
        state,
        key.context,
        &Key.put_for_state(&1, :images, payload["state"], payload["image"])
      )

  defp plugin_key_event(event, key, _payload, state) when event in ["showOk", "showAlert"] do
    ref = make_ref()
    Process.send_after(self(), {:clear_feedback, key.context, ref}, @feedback_ms)
    kind = if event == "showOk", do: :ok, else: :alert
    update_key(state, key.context, &%{&1 | feedback: {kind, ref}})
  end

  defp plugin_key_event("setState", key, payload, state),
    do: update_key(state, key.context, &Key.put_state(&1, payload["state"]))

  defp plugin_key_event("setSettings", key, payload, state) do
    key = %{key | settings: payload}

    state
    |> update_key(key.context, fn _ -> key end)
    |> send_pi(key.context, key_event(key, "didReceiveSettings"))
  end

  defp plugin_key_event("getSettings", key, _payload, state),
    do: send_plugin(state, key_event(key, "didReceiveSettings"))

  defp plugin_key_event("sendToPropertyInspector", key, payload, state) do
    send_pi(state, key.context, %{
      "event" => "sendToPropertyInspector",
      "action" => key.action,
      "context" => key.context,
      "payload" => payload
    })
  end

  ## Property Inspector → app

  defp handle_pi(context, msg, state) do
    case key_by_context(state, context) do
      nil -> state
      key -> pi_event(msg["event"], key, msg["payload"], state)
    end
  end

  defp pi_event("setSettings", key, settings, state) do
    key = %{key | settings: settings || %{}}

    state
    |> update_key(key.context, fn _ -> key end)
    |> send_plugin(key_event(key, "didReceiveSettings"))
  end

  defp pi_event("getSettings", key, _payload, state),
    do: send_pi(state, key.context, key_event(key, "didReceiveSettings"))

  defp pi_event("sendToPlugin", key, payload, state) do
    send_plugin(state, %{
      "event" => "sendToPlugin",
      "action" => key.action,
      "context" => key.context,
      "payload" => payload
    })
  end

  defp pi_event("setGlobalSettings", _key, settings, state) do
    state = %{state | global_settings: settings || %{}}
    send_plugin(state, global_settings_event(state))
  end

  defp pi_event("getGlobalSettings", key, _payload, state),
    do: send_pi(state, key.context, global_settings_event(state))

  defp pi_event(_event, _key, _payload, state), do: state

  ## Helpers

  defp key_event(%Key{coords: {column, row}} = key, event) do
    %{
      "event" => event,
      "action" => key.action,
      "context" => key.context,
      "device" => @device_id,
      "payload" => %{
        "settings" => key.settings,
        "coordinates" => %{"column" => column, "row" => row},
        "state" => key.state,
        "isInMultiAction" => false,
        "controller" => "Keypad"
      }
    }
  end

  defp device_did_connect do
    %{
      "event" => "deviceDidConnect",
      "device" => @device_id,
      "deviceInfo" => %{
        "name" => "Stream Deck Emulator",
        "type" => 0,
        "size" => %{"columns" => @columns, "rows" => @rows}
      }
    }
  end

  defp global_settings_event(state),
    do: %{
      "event" => "didReceiveGlobalSettings",
      "payload" => %{"settings" => state.global_settings}
    }

  defp send_plugin(%{plugin_pid: nil} = state, _msg), do: state

  defp send_plugin(state, msg) do
    send(state.plugin_pid, {:send, msg})
    log(state, :plugin, :out, msg["context"], msg)
  end

  defp send_pi(state, context, msg) do
    case pi_pid(state, context) do
      nil ->
        state

      pid ->
        send(pid, {:send, msg})
        log(state, :pi, :out, context, msg)
    end
  end

  defp pi_pid(state, context),
    do: Enum.find_value(state.conns, fn {pid, role} -> if role == {:pi, context}, do: pid end)

  defp pi_contexts(state), do: for({_pid, {:pi, context}} <- state.conns, do: context)

  defp drop_conn(state, pid) do
    send(pid, :close)
    %{state | conns: Map.delete(state.conns, pid)}
  end

  defp remove_key(state, coords) do
    case Map.pop(state.keys, coords) do
      {nil, _} ->
        state

      {key, keys} ->
        state = send_plugin(%{state | keys: keys}, key_event(key, "willDisappear"))

        case pi_pid(state, key.context) do
          nil -> state
          pid -> drop_conn(state, pid)
        end
    end
  end

  defp put_key(state, %Key{} = key), do: put_in(state, [:keys, key.coords], key)

  defp update_key(state, context, fun) do
    case key_by_context(state, context) do
      nil -> state
      key -> state |> put_key(fun.(key)) |> changed()
    end
  end

  defp key_by_context(state, context),
    do: Enum.find_value(state.keys, fn {_coords, key} -> if key.context == context, do: key end)

  defp validate_coords({column, row})
       when is_integer(column) and is_integer(row) and column >= 0 and column < @columns and
              row >= 0 and row < @rows,
       do: :ok

  defp validate_coords(_), do: {:error, :invalid_coordinates}

  defp new_context, do: Base.encode16(:crypto.strong_rand_bytes(16))

  defp snapshot(state) do
    state
    |> Map.take([:manifest, :plugin_uuid, :keys, :global_settings, :plugin])
    |> Map.put(:plugin_connected, state.plugin_pid != nil)
  end

  defp changed(state) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:deck, snapshot(state)})
    state
  end

  # source: :plugin | :pi | :stdout | :system; direction: :in (to the emulator) | :out | nil
  defp log(state, source, direction, context, data) do
    entry = %{
      id: state.log_seq + 1,
      at: DateTime.utc_now(),
      source: source,
      direction: direction,
      context: context,
      data: data
    }

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:deck_log, entry})
    %{state | log: Enum.take([entry | state.log], @log_limit), log_seq: entry.id}
  end
end
