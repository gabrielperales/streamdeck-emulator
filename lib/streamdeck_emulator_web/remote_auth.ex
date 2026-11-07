defmodule StreamdeckEmulatorWeb.RemoteAuth do
  @moduledoc """
  LiveView side of `StreamdeckEmulatorWeb.Access`: the LiveView socket is not
  behind that plug, so the views check the session it wrote.

    * `:local` (the full UI) refuses sessions that came from a phone.
    * `:remote` (the phone view) refuses phones whose pairing is no longer
      valid, and assigns `:paired?` so the view can drop them if it is revoked
      later. This machine may open it without pairing.
  """

  import Phoenix.LiveView

  alias StreamdeckEmulator.Remote
  alias StreamdeckEmulatorWeb.Access

  def on_mount(:local, _params, session, socket) do
    if Map.has_key?(session, Access.session_key()),
      do: {:halt, redirect(socket, to: "/remote")},
      else: {:cont, socket}
  end

  def on_mount(:remote, _params, session, socket) do
    case Map.fetch(session, Access.session_key()) do
      :error ->
        {:cont, Phoenix.Component.assign(socket, paired?: false)}

      {:ok, token} ->
        if Remote.valid_token?(token),
          do: {:cont, Phoenix.Component.assign(socket, paired?: true)},
          else: {:halt, redirect(socket, to: "/remote")}
    end
  end
end
