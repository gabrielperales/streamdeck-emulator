defmodule StreamdeckEmulatorWeb.Router do
  use StreamdeckEmulatorWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {StreamdeckEmulatorWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug StreamdeckEmulatorWeb.RequireJSON
  end

  scope "/", StreamdeckEmulatorWeb do
    pipe_through :browser

    live_session :local, on_mount: {StreamdeckEmulatorWeb.RemoteAuth, :local} do
      live "/", DeckLive
    end

    # The phone view (see StreamdeckEmulator.Remote).
    live_session :remote, on_mount: {StreamdeckEmulatorWeb.RemoteAuth, :remote} do
      live "/remote", RemoteLive
    end
  end

  # Files from the loaded plugin, served from the emulator's origin so the
  # Property Inspector iframe is same-origin with the UI.
  scope "/plugin", StreamdeckEmulatorWeb do
    get "/*path", PluginFileController, :show
  end

  # Control API for scripts and tests.
  scope "/api", StreamdeckEmulatorWeb do
    pipe_through :api

    get "/state", ApiController, :state
    get "/events", ApiController, :events
    post "/plugin", ApiController, :load_plugin
    delete "/plugin", ApiController, :unload_plugin
    put "/keys/:column/:row", ApiController, :put_key
    delete "/keys/:column/:row", ApiController, :delete_key
    post "/keys/:column/:row/press", ApiController, :press
    post "/keys/:column/:row/down", ApiController, :key_down
    post "/keys/:column/:row/up", ApiController, :key_up
  end
end
