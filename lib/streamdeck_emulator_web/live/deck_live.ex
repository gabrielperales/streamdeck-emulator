defmodule StreamdeckEmulatorWeb.DeckLive do
  @moduledoc """
  The emulator's UI: the virtual device, the selected key's inspector, the
  plugin's actions and the event log. With no plugin loaded it shows a form to
  load one. In the desktop app it also offers native file dialogs and loads a
  plugin dropped onto the window.
  """

  use StreamdeckEmulatorWeb, :live_view
  use ExTauri.LiveView

  alias StreamdeckEmulator.{Deck, Desktop, Manifest, Remote, Session, SocketServer}
  alias StreamdeckEmulatorWeb.DeckComponents

  @log_limit 300

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Deck.subscribe()
      Remote.subscribe()
    end

    desktop? = Desktop.shell?()

    socket =
      socket
      |> assign(
        selected: nil,
        load_errors: [],
        load_form: to_form(%{"path" => ""}),
        desktop?: desktop?,
        remote: Remote.status()
      )
      |> load_deck()
      |> subscribe_to_drops(desktop? and connected?(socket))

    {:ok, socket}
  end

  ## Events

  @impl true
  def handle_event("key_down", params, socket) do
    with {:ok, coords} <- DeckComponents.parse_coords(params) do
      if socket.assigns.deck, do: Deck.key_down(coords)
      {:noreply, assign(socket, selected: coords)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("key_up", params, socket) do
    with {:ok, coords} <- DeckComponents.parse_coords(params),
         true <- socket.assigns.deck != nil do
      Deck.key_up(coords)
    end

    {:noreply, socket}
  end

  def handle_event("assign_action", %{"action" => action}, socket) do
    case socket.assigns.selected do
      nil ->
        {:noreply, put_flash(socket, :error, "Select a key first")}

      coords ->
        case Deck.assign_action(coords, action) do
          {:ok, _context} ->
            {:noreply, socket}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Could not place the action: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("clear_key", _params, socket) do
    if coords = socket.assigns.selected, do: Deck.clear_key(coords)
    {:noreply, socket}
  end

  def handle_event("load_plugin", %{"path" => path}, socket),
    do: {:noreply, load_plugin(socket, String.trim(path))}

  # Native dialogs (desktop app only). A .sdPlugin is a folder and a
  # .streamDeckPlugin a file, and one dialog cannot pick both.
  def handle_event("pick_plugin", %{"kind" => kind}, socket) do
    opts =
      case kind do
        "folder" ->
          [title: "Open a .sdPlugin folder", directory: true]

        "package" ->
          [
            title: "Open a .streamDeckPlugin package",
            filters: [%{name: "Stream Deck plugin", extensions: ["streamDeckPlugin"]}]
          ]
      end

    {:noreply,
     ExTauri.Dialog.open(socket, opts, fn
       {:ok, %{"path" => path}}, socket when is_binary(path) ->
         load_plugin(socket, path)

       {:ok, _cancelled}, socket ->
         socket

       {:error, reason}, socket ->
         put_flash(socket, :error, "Could not open the dialog: #{inspect(reason)}")
     end)}
  end

  def handle_event("unload_plugin", _params, socket) do
    Session.stop()
    {:noreply, socket}
  end

  def handle_event("pi_log", %{"uuid" => context, "level" => level, "message" => message}, socket) do
    if socket.assigns.deck, do: Deck.pi_console(context, level, message)
    {:noreply, socket}
  end

  def handle_event("enable_remote", _params, socket) do
    case Remote.enable() do
      {:ok, status} ->
        {:noreply, assign(socket, remote: status)}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not listen on the network: #{inspect(reason)}")}
    end
  end

  def handle_event("disable_remote", _params, socket) do
    Remote.disable()
    {:noreply, assign(socket, remote: Remote.status())}
  end

  def handle_event("clear_log", _params, socket),
    do: {:noreply, stream(socket, :log, [], reset: true)}

  # ExTauri.LiveView routes replies that have a callback; the rest (such as the
  # acknowledgement of the drag-and-drop subscription) end up here.
  def handle_event("tauri_" <> _kind, _params, socket), do: {:noreply, socket}

  ## PubSub

  @impl true
  def handle_info({:deck, deck}, socket), do: {:noreply, assign(socket, deck: deck)}

  def handle_info({:deck_log, entry}, socket),
    do: {:noreply, stream_insert(socket, :log, entry, at: 0, limit: @log_limit)}

  def handle_info({:session, _event}, socket), do: {:noreply, load_deck(socket)}
  def handle_info({:remote, status}, socket), do: {:noreply, assign(socket, remote: status)}

  defp load_plugin(socket, path) do
    ws_port = Application.get_env(:streamdeck_emulator, :ws_port, 0)

    case Session.start(path, ws_port: ws_port) do
      {:ok, _} ->
        assign(socket, load_errors: [], selected: nil)

      {:error, errors} ->
        assign(socket,
          load_errors: List.wrap(errors) |> Enum.map(&error_text/1),
          load_form: to_form(%{"path" => path})
        )
    end
  end

  # Dropping a .sdPlugin folder or .streamDeckPlugin file onto the window loads it.
  defp subscribe_to_drops(socket, false), do: socket

  defp subscribe_to_drops(socket, true) do
    ExTauri.Event.subscribe(socket, "tauri://drag-drop", fn
      %{"paths" => [path | _]}, socket -> load_plugin(socket, path)
      _payload, socket -> socket
    end)
  end

  defp load_deck(socket) do
    if Deck.running?() do
      socket
      |> assign(deck: Deck.snapshot(), ws_port: SocketServer.port())
      |> stream(:log, Deck.log() |> Enum.take(-@log_limit) |> Enum.reverse(), reset: true)
    else
      socket
      |> assign(deck: nil, ws_port: nil, selected: nil)
      |> stream(:log, [], reset: true)
    end
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div :if={@desktop?} id="tauri-bridge" phx-hook="TauriHook" class="hidden"></div>

      <%= if @deck do %>
        <.plugin_header deck={@deck} ws_port={@ws_port} remote={@remote} />
        <.phone_access :if={@remote.enabled} remote={@remote} />

        <div class="mt-6 grid gap-6 lg:grid-cols-[auto_minmax(0,1fr)]">
          <.device deck={@deck} selected={@selected} />
          <.inspector deck={@deck} selected={@selected} ws_port={@ws_port} />
        </div>

        <.event_log streams={@streams} />
      <% else %>
        <.load_panel form={@load_form} errors={@load_errors} desktop?={@desktop?} />
      <% end %>
    </Layouts.app>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".PropertyInspector">
      // Plays the Stream Deck app's part once the PI page has loaded: it calls the
      // page's connectElgatoStreamDeckSocket, forwards its console to the event
      // log and sizes the frame to its content. Needs the PI on the same origin.
      const format = (value) => {
        if (typeof value === "string") return value
        try { return JSON.stringify(value) } catch (_) { return String(value) }
      }

      export default {
        mounted() {
          const frame = this.el
          const {port, uuid, appInfo, actionInfo} = frame.dataset
          const report = (level, message) => this.pushEvent("pi_log", {uuid, level, message})

          frame.addEventListener("load", () => {
            const win = frame.contentWindow

            for (const level of ["log", "info", "warn", "error"]) {
              const original = win.console[level].bind(win.console)
              win.console[level] = (...args) => {
                original(...args)
                report(level, args.map(format).join(" "))
              }
            }
            win.addEventListener("error", (e) => report("error", e.message))

            const fit = () => {
              frame.style.height = Math.max(win.document.documentElement.scrollHeight, 160) + "px"
            }
            new win.ResizeObserver(fit).observe(win.document.body)
            fit()

            if (typeof win.connectElgatoStreamDeckSocket !== "function") {
              report("error", "the page does not define connectElgatoStreamDeckSocket")
              return
            }
            win.connectElgatoStreamDeckSocket(Number(port), uuid, "registerPropertyInspector", appInfo, actionInfo)
          })
        }
      }
    </script>
    """
  end

  attr :form, :any, required: true
  attr :errors, :list, required: true
  attr :desktop?, :boolean, default: false

  defp load_panel(assigns) do
    ~H"""
    <section class="mx-auto mt-16 max-w-xl rounded-2xl border border-base-300 bg-base-100 p-8 shadow-sm">
      <h1 class="text-xl font-semibold">Stream Deck Emulator</h1>
      <p class="mt-2 text-sm text-base-content/70">
        Load a plugin to start it: an unpacked <code>.sdPlugin</code>
        folder or a <code>.streamDeckPlugin</code>
        package.
      </p>

      <div :if={@desktop?} class="mt-6 space-y-3">
        <div class="flex flex-wrap gap-2">
          <button
            id="pick-folder"
            phx-click="pick_plugin"
            phx-value-kind="folder"
            class="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-content transition hover:brightness-110"
          >
            Open .sdPlugin folder…
          </button>
          <button
            id="pick-package"
            phx-click="pick_plugin"
            phx-value-kind="package"
            class="rounded-lg border border-base-300 px-4 py-2 text-sm font-medium transition hover:bg-base-300"
          >
            Open .streamDeckPlugin…
          </button>
        </div>
        <p class="text-sm text-base-content/60">Or drop either onto this window, or type a path:</p>
      </div>

      <.form
        for={@form}
        id="load-form"
        phx-submit="load_plugin"
        class={if(@desktop?, do: "mt-3", else: "mt-6")}
      >
        <.input
          field={@form[:path]}
          type="text"
          label="Plugin path"
          placeholder="/path/to/com.example.plugin.sdPlugin"
          autocomplete="off"
        />
        <button
          type="submit"
          class="mt-2 rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-content transition hover:brightness-110"
        >
          Load plugin
        </button>
      </.form>

      <ul
        :if={@errors != []}
        id="load-errors"
        class="mt-6 space-y-1 rounded-lg bg-error/10 p-4 text-sm text-error"
      >
        <li :for={error <- @errors}>{error}</li>
      </ul>
    </section>
    """
  end

  attr :deck, :map, required: true
  attr :ws_port, :integer
  attr :remote, :map, required: true

  defp plugin_header(assigns) do
    ~H"""
    <header class="flex flex-wrap items-center gap-x-6 gap-y-3">
      <img
        :if={DeckComponents.plugin_url(@deck.manifest, @deck.manifest.icon)}
        src={DeckComponents.plugin_url(@deck.manifest, @deck.manifest.icon)}
        alt=""
        class="size-10 rounded-lg"
      />
      <div class="min-w-0">
        <h1 class="truncate text-lg font-semibold">
          {@deck.manifest.name}
          <span class="ml-1 text-sm font-normal text-base-content/60">{@deck.manifest.version}</span>
        </h1>
        <p class="truncate font-mono text-xs text-base-content/60">{@deck.manifest.uuid}</p>
      </div>

      <.status plugin={@deck.plugin} connected={@deck.plugin_connected} />

      <p class="font-mono text-xs text-base-content/60">
        ws://127.0.0.1:<span id="ws-port">{@ws_port}</span>
      </p>

      <div class="ml-auto flex gap-2">
        <button
          id="toggle-remote"
          phx-click={if @remote.enabled, do: "disable_remote", else: "enable_remote"}
          class={[
            "inline-flex items-center gap-1.5 rounded-lg border px-3 py-1.5 text-sm transition",
            if(@remote.enabled,
              do: "border-sky-400 bg-sky-400/10 text-sky-700 hover:bg-sky-400/20 dark:text-sky-300",
              else: "border-base-300 hover:bg-base-300"
            )
          ]}
        >
          <.icon name="hero-device-phone-mobile" class="size-4" />
          {if @remote.enabled, do: "Stop phone access", else: "Use from a phone"}
        </button>
        <button
          id="unload-plugin"
          phx-click="unload_plugin"
          class="rounded-lg border border-base-300 px-3 py-1.5 text-sm transition hover:bg-base-300"
        >
          Unload
        </button>
      </div>
    </header>
    """
  end

  attr :remote, :map, required: true

  # The pairing QR code. Its URL carries the pairing token, so whoever scans it
  # can press keys until phone access is turned off.
  defp phone_access(assigns) do
    assigns = assign(assigns, qr: assigns.remote.url && qr_svg(assigns.remote.url))

    ~H"""
    <section
      id="phone-access"
      class="mt-4 flex flex-wrap items-center gap-6 rounded-2xl border border-sky-400/40 bg-base-100 p-5"
    >
      <%= if @qr do %>
        <div id="pairing-qr" class="rounded-xl bg-white p-3 [&_svg]:block [&_svg]:size-44">
          {Phoenix.HTML.raw(@qr)}
        </div>
        <div class="min-w-0 max-w-md space-y-2 text-sm">
          <h2 class="font-semibold">Scan with a phone on the same network</h2>
          <p class="text-base-content/70">
            It opens the keys full screen. Add it to the home screen to keep it at hand.
          </p>
          <p class="text-base-content/70">
            Anyone who scans this code can press the keys, which run the plugin's actions.
            Stopping phone access unpairs every phone; starting it again makes a new code.
          </p>
          <p id="pairing-host" class="font-mono text-xs text-base-content/60">
            http://{@remote.host}:{@remote.port}/remote
          </p>
          <p class="text-xs text-base-content/60">
            If the phone cannot load it, allow incoming connections for the emulator in
            this computer's firewall.
          </p>
          <p :if={length(@remote.hosts) > 1} class="text-xs text-base-content/60">
            Other addresses of this computer: {Enum.join(tl(@remote.hosts), ", ")}
          </p>
        </div>
      <% else %>
        <p class="text-sm text-base-content/70">
          This computer has no address on a local network, so phones cannot reach it.
        </p>
      <% end %>
    </section>
    """
  end

  defp qr_svg(url), do: url |> EQRCode.encode() |> EQRCode.svg(width: 176)

  attr :plugin, :map, required: true
  attr :connected, :boolean, required: true

  defp status(assigns) do
    {label, class} =
      cond do
        assigns.connected ->
          {"Connected", "bg-emerald-500/15 text-emerald-600 dark:text-emerald-400"}

        assigns.plugin.status == :exited ->
          {"Exited (#{inspect(assigns.plugin.exit_status)})",
           "bg-red-500/15 text-red-600 dark:text-red-400"}

        true ->
          {"Starting", "bg-amber-500/15 text-amber-600 dark:text-amber-400"}
      end

    assigns = assign(assigns, label: label, class: class)

    ~H"""
    <span
      id="plugin-status"
      class={["inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium", @class]}
    >
      <span class="size-1.5 rounded-full bg-current"></span>
      {@label}
      <span :if={@plugin.exits > 0} class="opacity-70">· {@plugin.exits} restarts</span>
    </span>
    """
  end

  attr :deck, :map, required: true
  attr :selected, :any

  defp device(assigns) do
    {columns, rows} = Deck.size()
    assigns = assign(assigns, columns: columns, rows: rows)

    ~H"""
    <section
      aria-label="Device"
      class="w-fit self-start rounded-[2rem] bg-zinc-900 p-5 shadow-xl ring-1 ring-black/40"
    >
      <div class="grid gap-3" style={"grid-template-columns: repeat(#{@columns}, minmax(0, 1fr))"}>
        <%= for row <- 0..(@rows - 1), column <- 0..(@columns - 1) do %>
          <DeckComponents.key
            coords={{column, row}}
            key={@deck.keys[{column, row}]}
            manifest={@deck.manifest}
            selected={@selected == {column, row}}
          />
        <% end %>
      </div>
    </section>
    """
  end

  attr :deck, :map, required: true
  attr :selected, :any
  attr :ws_port, :integer

  defp inspector(assigns) do
    key = assigns.selected && assigns.deck.keys[assigns.selected]
    assigns = assign(assigns, key: key, pi: key && property_inspector(assigns.deck, key))

    ~H"""
    <section aria-label="Inspector" class="min-w-0 space-y-6">
      <div class="rounded-2xl border border-base-300 bg-base-100 p-5">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">Actions</h2>
        <ul class="mt-3 grid gap-2 sm:grid-cols-2">
          <li :for={action <- @deck.manifest.actions}>
            <button
              id={"action-#{action.uuid}"}
              phx-click="assign_action"
              phx-value-action={action.uuid}
              disabled={@selected == nil}
              title={action.tooltip}
              class="flex w-full items-center gap-3 rounded-lg border border-base-300 p-2 text-left text-sm transition enabled:hover:border-sky-400 enabled:hover:bg-base-200 disabled:cursor-not-allowed disabled:opacity-50"
            >
              <img
                :if={DeckComponents.plugin_url(@deck.manifest, action.icon)}
                src={DeckComponents.plugin_url(@deck.manifest, action.icon)}
                alt=""
                class="size-8 rounded"
              />
              <span class="min-w-0">
                <span class="block truncate font-medium">{action.name}</span>
                <span class="block truncate font-mono text-xs text-base-content/60">{action.uuid}</span>
              </span>
            </button>
          </li>
        </ul>
      </div>

      <div id="key-inspector" class="rounded-2xl border border-base-300 bg-base-100 p-5">
        <%= cond do %>
          <% @selected == nil -> %>
            <p class="text-sm text-base-content/70">
              Select a key to place an action on it or inspect it.
            </p>
          <% @key == nil -> %>
            <h2 class="font-semibold">Key {coords_label(@selected)}</h2>
            <p class="mt-1 text-sm text-base-content/70">
              Empty. Pick an action above to place it here.
            </p>
          <% true -> %>
            <div class="flex items-start justify-between gap-4">
              <div class="min-w-0">
                <h2 class="font-semibold">
                  {action_name(@deck.manifest, @key.action)}
                  <span class="ml-1 text-sm font-normal text-base-content/60">key {coords_label(
                    @selected
                  )}</span>
                </h2>
                <p class="truncate font-mono text-xs text-base-content/60">{@key.context}</p>
              </div>
              <button
                id="clear-key"
                phx-click="clear_key"
                class="rounded-lg border border-base-300 px-3 py-1.5 text-sm transition hover:bg-base-300"
              >
                Remove
              </button>
            </div>
            <dl class="mt-4 grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1 text-sm">
              <dt class="text-base-content/60">State</dt>
              <dd>{@key.state} of {@key.states}</dd>
              <dt class="text-base-content/60">Settings</dt>
              <dd>
                <pre
                  id="key-settings"
                  class="max-h-48 overflow-auto whitespace-pre-wrap break-all rounded-lg bg-base-200 p-2 font-mono text-xs"
                >{Jason.encode!(@key.settings, pretty: true)}</pre>
              </dd>
            </dl>

            <.property_inspector :if={@pi} pi={@pi} key={@key} ws_port={@ws_port} />
            <p :if={!@pi} class="mt-4 text-sm text-base-content/60">
              This action has no Property Inspector.
            </p>
        <% end %>
      </div>
    </section>
    """
  end

  attr :pi, :map, required: true
  attr :key, :any, required: true
  attr :ws_port, :integer, required: true

  # Keyed by context so selecting another key loads a fresh page, and ignored by
  # LiveView so later renders (new settings, titles) never reload the iframe.
  defp property_inspector(assigns) do
    ~H"""
    <div id={"pi-#{@key.context}"} phx-update="ignore" class="mt-4">
      <h3 class="mb-2 text-sm font-semibold uppercase tracking-wide text-base-content/60">
        Property Inspector
      </h3>
      <iframe
        id={"pi-frame-#{@key.context}"}
        phx-hook=".PropertyInspector"
        src={@pi.src}
        title="Property Inspector"
        data-port={@ws_port}
        data-uuid={@key.context}
        data-app-info={@pi.app_info}
        data-action-info={@pi.action_info}
        class="block h-40 w-full rounded-lg border border-base-300 bg-[#2d2d2d]"
      ></iframe>
    </div>
    """
  end

  attr :streams, :any, required: true

  defp event_log(assigns) do
    ~H"""
    <section aria-label="Event log" class="mt-6 rounded-2xl border border-base-300 bg-base-100">
      <div class="flex items-center justify-between border-b border-base-300 px-5 py-3">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">Event log</h2>
        <button
          phx-click="clear_log"
          class="text-xs text-base-content/60 transition hover:text-base-content"
        >
          Clear
        </button>
      </div>
      <ol id="event-log" phx-update="stream" class="h-80 overflow-y-auto font-mono text-xs">
        <li
          :for={{dom_id, entry} <- @streams.log}
          id={dom_id}
          class="border-b border-base-200 px-5 py-1.5 last:border-0"
        >
          <.log_entry entry={entry} />
        </li>
      </ol>
    </section>
    """
  end

  attr :entry, :map, required: true

  defp log_entry(%{entry: %{data: data}} = assigns) when is_map(data) do
    ~H"""
    <details class="group">
      <summary class="flex cursor-pointer list-none items-baseline gap-3">
        <.log_prefix entry={@entry} />
        <span class="font-semibold">{@entry.data["event"] || "?"}</span>
        <span :if={@entry.context} class="truncate text-base-content/50">{short(@entry.context)}</span>
      </summary>
      <pre class="mt-1 overflow-x-auto rounded bg-base-200 p-2">{Jason.encode!(@entry.data, pretty: true)}</pre>
    </details>
    """
  end

  defp log_entry(assigns) do
    ~H"""
    <div class="flex items-baseline gap-3">
      <.log_prefix entry={@entry} />
      <span class={[
        "whitespace-pre-wrap break-all",
        @entry.source == :system && "italic text-base-content/70"
      ]}>{@entry.data}</span>
    </div>
    """
  end

  attr :entry, :map, required: true

  defp log_prefix(assigns) do
    ~H"""
    <time class="shrink-0 text-base-content/40">{Calendar.strftime(@entry.at, "%H:%M:%S.%f")
    |> String.slice(0, 12)}</time>
    <span class={["w-24 shrink-0", source_class(@entry.source)]}>{source_label(@entry)}</span>
    """
  end

  ## Helpers

  # The PI is served from the plugin folder on the emulator's origin, so the
  # page's hook can call connectElgatoStreamDeckSocket inside the iframe.
  defp property_inspector(deck, key) do
    case Manifest.action(deck.manifest, key.action) do
      %{property_inspector_path: path} when is_binary(path) ->
        %{
          src: "/plugin/" <> URI.encode(path),
          app_info: Jason.encode!(Deck.application_info(deck.manifest)),
          action_info: Jason.encode!(Deck.action_info(key))
        }

      _ ->
        nil
    end
  end

  defp action_name(manifest, uuid) do
    case Manifest.action(manifest, uuid) do
      nil -> uuid
      action -> action.name
    end
  end

  defp coords_label({column, row}), do: "#{column},#{row}"

  defp short(context) when is_binary(context), do: String.slice(context, 0, 8)
  defp short(_), do: nil

  defp source_label(%{source: :plugin, direction: :in}), do: "plugin →"
  defp source_label(%{source: :plugin, direction: :out}), do: "→ plugin"
  defp source_label(%{source: :pi, direction: :in}), do: "PI →"
  defp source_label(%{source: :pi, direction: :out}), do: "→ PI"
  defp source_label(%{source: :stdout}), do: "stdout"
  defp source_label(%{source: :system}), do: "emulator"
  defp source_label(%{source: :pi_console, direction: level}), do: "PI #{level}"

  defp source_class(:plugin), do: "text-sky-600 dark:text-sky-400"
  defp source_class(:pi), do: "text-violet-600 dark:text-violet-400"
  defp source_class(:stdout), do: "text-base-content/60"
  defp source_class(:system), do: "text-amber-600 dark:text-amber-400"
  defp source_class(:pi_console), do: "text-violet-600/70 dark:text-violet-400/70"

  defp error_text(error) when is_binary(error), do: error
  defp error_text(error), do: inspect(error)
end
