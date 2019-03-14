defmodule Web.Router do
  use Web, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug Web.Plugs.FetchUser
  end

  pipeline(:signed_in) do
    plug(Web.Plugs.VerifyUser)
  end

  pipeline(:not_signed_in) do
    plug(Web.Plugs.VerifyNoUser)
  end

  pipeline(:admin) do
    plug(Web.Plugs.VerifyAdmin)
    plug(:put_layout, {Web.LayoutView, "admin.html"})
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", Web do
    pipe_through([:browser])

    get "/", PageController, :index

    resources("/account", AccountController, only: [:edit, :update], singleton: true)
  end

  scope "/", Web do
    pipe_through([:browser, :not_signed_in])

    resources("/register", RegistrationController, only: [:new, :create])

    get("/register/reset", RegistrationResetController, :new)
    post("/register/reset", RegistrationResetController, :create)

    get("/register/reset/verify", RegistrationResetController, :edit)
    post("/register/reset/verify", RegistrationResetController, :update)

    get("/register/verify", RegistrationVerifyController, :show)

    resources("/sign-in", SessionController, only: [:new, :create], singleton: true)
  end

  scope "/", Web do
    pipe_through([:browser, :signed_in])

    resources("/challenges", ChallengeController, only: [:index, :new, :create])

    resources("/sign-in", SessionController, only: [:delete], singleton: true)
  end

  scope "/admin", Web.Admin, as: :admin do
    pipe_through([:browser, :admin])

    get("/", DashboardController, :index)
  end

  if Mix.env() == :dev do
    forward("/emails/sent", Bamboo.SentEmailViewerPlug)
  end
end
