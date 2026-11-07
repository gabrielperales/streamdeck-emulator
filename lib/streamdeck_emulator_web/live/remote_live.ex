defmodule StreamdeckEmulatorWeb.RemoteLive do
  @moduledoc """
  The phone view: only the device's keys, full screen, for pressing them from
  a phone paired with a QR code (see `StreamdeckEmulator.Remote`). It follows
  the deck live and drops the phone when its pairing is revoked.
  """

  use StreamdeckEmulatorWeb, :live_view

  alias StreamdeckEmulator.{Deck, Remote}
  alias StreamdeckEmulatorWeb.DeckComponents

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      Deck.subscribe()
      Remote.subscribe()
    end

    {:ok,
     socket
     |> assign(
       page_title: "Deck",
       pair_token: session[StreamdeckEmulatorWeb.Access.session_key()]
     )
     |> load_deck()}
  end

  @impl true
  def handle_event("key_down", params, socket), do: key(socket, params, &Deck.key_down/1)
  def handle_event("key_up", params, socket), do: key(socket, params, &Deck.key_up/1)

  @impl true
  def handle_info({:deck, deck}, socket), do: {:noreply, assign(socket, deck: deck)}
  def handle_info({:session, _event}, socket), do: {:noreply, load_deck(socket)}

  # Turning phone access off, or on again with a new code, unpairs this phone.
  def handle_info({:remote, _status}, socket) do
    if socket.assigns.paired? and not Remote.valid_token?(socket.assigns.pair_token),
      do: {:noreply, redirect(socket, to: ~p"/remote")},
      else: {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp key(socket, params, fun) do
    with %{} <- socket.assigns.deck, {:ok, coords} <- DeckComponents.parse_coords(params) do
      fun.(coords)
    end

    {:noreply, socket}
  end

  defp load_deck(socket),
    do: assign(socket, deck: if(Deck.running?(), do: Deck.snapshot()))

  @impl true
  def render(assigns) do
    {columns, rows} = Deck.size()
    assigns = assign(assigns, columns: columns, rows: rows)

    ~H"""
    <Layouts.remote flash={@flash}>
      <header class="flex items-center gap-2 px-4 py-2 text-xs text-zinc-400">
        <span class={[
          "size-2 shrink-0 rounded-full",
          if(@deck && @deck.plugin_connected, do: "bg-emerald-400", else: "bg-amber-400")
        ]}></span>
        <span id="remote-plugin" class="truncate">
          {if @deck, do: @deck.manifest.name, else: "No plugin loaded"}
        </span>
      </header>

      <main class="flex min-h-0 flex-1 items-center justify-center p-3">
        <div
          :if={@deck}
          id="remote-deck"
          class="grid w-full gap-2 sm:gap-3"
          style={"grid-template-columns: repeat(#{@columns}, minmax(0, 1fr)); max-width: min(100%, calc((100dvh - 5rem) * #{@columns} / #{@rows}))"}
        >
          <%= for row <- 0..(@rows - 1), column <- 0..(@columns - 1) do %>
            <DeckComponents.key
              coords={{column, row}}
              key={@deck.keys[{column, row}]}
              manifest={@deck.manifest}
              class="aspect-square w-full"
            />
          <% end %>
        </div>
        <p :if={!@deck} class="max-w-xs text-center text-sm text-zinc-400">
          Load a plugin in the emulator on your computer and its keys will show up here.
        </p>
      </main>
    </Layouts.remote>
    """
  end
end
