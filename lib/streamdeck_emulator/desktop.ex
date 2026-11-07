defmodule StreamdeckEmulator.Desktop do
  @moduledoc """
  Whether the emulator runs inside the desktop app (the Tauri shell from
  ex_tauri), as opposed to `mix streamdeck.run`, `mix phx.server` or tests.

  The shell always passes `EX_TAURI_SHELL_PID` to the backend it starts. Only
  then does the emulator watch the shell's heartbeat, require the shell's
  launch token on HTTP requests and offer native file dialogs.
  """

  @spec shell?() :: boolean()
  def shell?, do: System.get_env("EX_TAURI_SHELL_PID") not in [nil, ""]
end
