defmodule HierarchyPaiWeb.Router do
  use HierarchyPaiWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HierarchyPaiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :mcp do
    plug HierarchyPaiWeb.Plugs.SuppressMcpPolling
  end

  scope "/mcp" do
    pipe_through :mcp

    forward "/", HierarchyPaiWeb.MCPRouter,
      otp_app: :hierarchy_pai,
      protocol_version_statement: "2024-11-05"
  end

  scope "/api/json" do
    pipe_through [:api]

    forward "/swaggerui", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/json/open_api",
      default_model_expand_depth: 4

    forward "/", HierarchyPaiWeb.AshJsonApiRouter
  end

  scope "/", HierarchyPaiWeb do
    pipe_through :browser

    live "/", PlannerLive
    get "/info", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", HierarchyPaiWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:hierarchy_pai, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: HierarchyPaiWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  if Application.compile_env(:hierarchy_pai, :dev_routes) do
    import AshAdmin.Router

    scope "/admin" do
      pipe_through :browser

      ash_admin "/"
    end
  end
end
