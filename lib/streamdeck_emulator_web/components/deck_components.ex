defmodule StreamdeckEmulatorWeb.DeckComponents do
  @moduledoc """
  The device's keys, shared by the full UI (`DeckLive`) and the phone view
  (`RemoteLive`). A key sends `"key_down"` / `"key_up"` events with `col` and
  `row` to its LiveView when pressed and released.
  """

  use Phoenix.Component

  import StreamdeckEmulatorWeb.CoreComponents, only: [icon: 1]

  alias StreamdeckEmulator.Deck.Key
  alias StreamdeckEmulator.Manifest

  attr :coords, :any, required: true
  attr :key, :any, doc: "the `StreamdeckEmulator.Deck.Key` on it, or nil"
  attr :manifest, :any, required: true
  attr :selected, :boolean, default: false
  attr :class, :string, default: "size-16 sm:size-20", doc: "sizing classes"

  def key(assigns) do
    {column, row} = assigns.coords

    assigns =
      assign(assigns, column: column, row: row, view: key_view(assigns.manifest, assigns.key))

    ~H"""
    <button
      id={"key-#{@column}-#{@row}"}
      type="button"
      phx-hook=".Key"
      data-col={@column}
      data-row={@row}
      aria-label={"Key #{@column},#{@row}" <> if(@key, do: ": #{@view.name}", else: " (empty)")}
      aria-pressed={to_string(@selected)}
      class={[
        "relative touch-none select-none overflow-hidden rounded-xl bg-black shadow-inner transition [-webkit-touch-callout:none]",
        "active:scale-95 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sky-400",
        @class,
        @selected && "ring-2 ring-sky-400 ring-offset-2 ring-offset-zinc-900",
        !@key && "bg-zinc-800/60"
      ]}
    >
      <img
        :if={@view.image}
        src={@view.image}
        alt=""
        draggable="false"
        class="pointer-events-none absolute inset-0 size-full object-cover"
      />
      <span
        :if={@view.title}
        data-role="title"
        class={[
          "pointer-events-none absolute inset-x-1 whitespace-pre-line text-center text-[11px] font-semibold leading-tight [text-shadow:0_1px_2px_rgb(0_0_0/0.9)]",
          @view.align
        ]}
        style={"color: #{@view.color}"}
      >{@view.title}</span>
      <span
        :if={@view.feedback}
        data-role="feedback"
        data-feedback={@view.feedback}
        class="pointer-events-none absolute inset-0 grid place-items-center bg-black/55"
      >
        <.icon
          :if={@view.feedback == :ok}
          name="hero-check-circle-solid"
          class="size-10 text-emerald-400"
        />
        <.icon
          :if={@view.feedback == :alert}
          name="hero-exclamation-triangle-solid"
          class="size-10 text-amber-400"
        />
      </span>
    </button>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Key">
      // A key sends keyDown when pressed and keyUp when released, like hardware,
      // so long presses work. Space and Enter press it from the keyboard; on a
      // phone a press gives a short vibration where the browser allows it.
      export default {
        mounted() {
          const coords = () => ({col: this.el.dataset.col, row: this.el.dataset.row})
          let down = false
          const press = () => {
            if (down) return
            down = true
            navigator.vibrate?.(10)
            this.pushEvent("key_down", coords())
          }
          const release = () => {
            if (!down) return
            down = false
            this.pushEvent("key_up", coords())
          }
          const isKey = (e) => e.key === " " || e.key === "Enter"

          this.el.addEventListener("pointerdown", (e) => {
            if (e.button !== 0) return
            this.el.setPointerCapture(e.pointerId)
            press()
          })
          this.el.addEventListener("pointerup", release)
          this.el.addEventListener("pointercancel", release)
          this.el.addEventListener("contextmenu", (e) => e.preventDefault())
          this.el.addEventListener("keydown", (e) => {
            if (!isKey(e)) return
            e.preventDefault()
            if (!e.repeat) press()
          })
          this.el.addEventListener("keyup", (e) => {
            if (!isKey(e)) return
            e.preventDefault()
            release()
          })
          this.el.addEventListener("blur", release)
        }
      }
    </script>
    """
  end

  @doc "Parses the `col` and `row` a key event carries."
  def parse_coords(%{"col" => col, "row" => row}) do
    with {col, ""} <- Integer.parse(to_string(col)), {row, ""} <- Integer.parse(to_string(row)) do
      {:ok, {col, row}}
    else
      _ -> :error
    end
  end

  def parse_coords(_), do: :error

  @doc "URL of a manifest image (a name without extension) under `/plugin/`."
  def plugin_url(manifest, name) do
    case Manifest.image_file(manifest, name) do
      nil -> nil
      file -> "/plugin/" <> (file |> Path.relative_to(manifest.dir) |> URI.encode())
    end
  end

  defp key_view(_manifest, nil),
    do: %{image: nil, title: nil, align: nil, color: nil, feedback: nil, name: nil}

  defp key_view(manifest, %Key{} = key) do
    action = Manifest.action(manifest, key.action)
    state = Enum.at(action.states, key.state) || %{}

    %{
      name: action.name,
      image: Key.image(key) || plugin_url(manifest, state["Image"] || action.icon),
      title: Key.title(key) || if(state["ShowTitle"] != false, do: state["Title"]),
      align:
        case state["TitleAlignment"] do
          "top" -> "top-1"
          "middle" -> "top-1/2 -translate-y-1/2"
          _ -> "bottom-1"
        end,
      color: state["TitleColor"] || "#ffffff",
      feedback:
        case key.feedback do
          {kind, _ref} -> kind
          nil -> nil
        end
    }
  end
end
